import AuthenticationServices
import UIKit

@MainActor
protocol AppleAuthorizationController: AnyObject {
    var identifier: ObjectIdentifier { get }
    func configure(
        delegate: ASAuthorizationControllerDelegate,
        presentationContextProvider: ASAuthorizationControllerPresentationContextProviding
    )
    func performRequests()
    func cancel()
}

typealias AppleAuthorizationControllerFactory = @MainActor (ASAuthorizationRequest) -> any AppleAuthorizationController

@MainActor
private final class SystemAppleAuthorizationController: AppleAuthorizationController {
    private let controller: ASAuthorizationController

    init(request: ASAuthorizationRequest) {
        controller = ASAuthorizationController(authorizationRequests: [request])
    }

    var identifier: ObjectIdentifier { ObjectIdentifier(controller) }

    func configure(
        delegate: ASAuthorizationControllerDelegate,
        presentationContextProvider: ASAuthorizationControllerPresentationContextProviding
    ) {
        controller.delegate = delegate
        controller.presentationContextProvider = presentationContextProvider
    }

    func performRequests() {
        controller.performRequests()
    }

    func cancel() {
        controller.cancel()
    }
}

/// The result of a completed Sign in with Apple: the exchanged parent session
/// plus the stable Apple user identifier presented by the credential. The
/// identifier is opaque identity evidence used to recognize the owning parent
/// on this device; it is never sent anywhere by the client.
public struct AppleSignInOutcome: Sendable {
    public let session: AuthSession
    public let appleUserID: String

    public init(session: AuthSession, appleUserID: String) {
        self.session = session
        self.appleUserID = appleUserID
    }
}

/// Seam for everything that performs a native Sign in with Apple. When
/// `requiredAppleUserID` is provided, the sign-in must present exactly that
/// Apple user identifier; any other account fails with
/// `WalletAPIError.identityMismatch` before a token is exchanged or stored.
@MainActor
public protocol AppleSignInProviding: AnyObject {
    func signIn(requiredAppleUserID: String?) async throws -> AppleSignInOutcome
}

@MainActor
public final class AppleSignInCoordinator: NSObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding, AppleSignInProviding {
    private static let defaultTimeoutNanoseconds: UInt64 = 30_000_000_000

    private let authenticator: any ParentAuthenticator
    private let controllerFactory: AppleAuthorizationControllerFactory
    private let timeoutNanoseconds: UInt64
    private var continuation: CheckedContinuation<AppleSignInOutcome, Error>?
    private var expectedState: String?
    private var expectedSignedNonce: String?
    private var requiredAppleUserID: String?
    private var activeAttemptID: UUID?
    private var cancellationRequestedFor: UUID?
    private var authorizationControllerAdapter: (any AppleAuthorizationController)?
    private var activeAuthorizationControllerID: ObjectIdentifier?
    private var timeoutTask: Task<Void, Never>?
    private var exchangeTask: Task<Void, Never>?

    public convenience init(authenticator: any ParentAuthenticator) {
        self.init(
            authenticator: authenticator,
            timeoutNanoseconds: Self.defaultTimeoutNanoseconds,
            controllerFactory: { request in SystemAppleAuthorizationController(request: request) }
        )
    }

    init(
        authenticator: any ParentAuthenticator,
        timeoutNanoseconds: UInt64,
        controllerFactory: @escaping AppleAuthorizationControllerFactory
    ) {
        self.authenticator = authenticator
        self.timeoutNanoseconds = timeoutNanoseconds
        self.controllerFactory = controllerFactory
    }

    public func signIn(requiredAppleUserID: String? = nil) async throws -> AppleSignInOutcome {
        guard continuation == nil, activeAttemptID == nil else {
            throw WalletAPIError.server(statusCode: 409, code: "AUTHENTICATION_IN_PROGRESS", message: "Sign in is already in progress.")
        }

        let rawNonce = try AppleNonce.randomString()
        let signedNonce = AppleNonce.sha256(rawNonce)
        let state = try AppleNonce.randomString()
        let attemptID = UUID()
        expectedState = state
        expectedSignedNonce = signedNonce
        self.requiredAppleUserID = requiredAppleUserID
        activeAttemptID = attemptID
        cancellationRequestedFor = nil

        let request = ASAuthorizationAppleIDProvider().createRequest()
        request.requestedScopes = [.email]
        // Apple signs the SHA-256 nonce into the identity token. The same signed
        // nonce is sent to the API, which verifies it against that claim.
        request.nonce = signedNonce
        request.state = state
        let adapter = controllerFactory(request)
        authorizationControllerAdapter = adapter
        activeAuthorizationControllerID = adapter.identifier
        adapter.configure(delegate: self, presentationContextProvider: self)

        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                guard self.activeAttemptID == attemptID else {
                    self.finish(.failure(CancellationError()), attemptID: attemptID, cancelController: true)
                    return
                }
                if self.cancellationRequestedFor == attemptID || Task.isCancelled {
                    self.finish(.failure(CancellationError()), attemptID: attemptID, cancelController: true)
                    return
                }

                let timeoutNanoseconds = self.timeoutNanoseconds
                self.timeoutTask = Task { [weak self] in
                    do {
                        try await Task.sleep(nanoseconds: timeoutNanoseconds)
                    } catch {
                        return
                    }
                    guard !Task.isCancelled else { return }
                    self?.timedOut(attemptID: attemptID)
                }
                adapter.performRequests()
            }
        }, onCancel: {
            Task { @MainActor [weak self] in
                self?.cancel(attemptID: attemptID)
            }
        })
    }

    public func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithAuthorization authorization: ASAuthorization
    ) {
        guard isActive(ObjectIdentifier(controller)) else { return }
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else {
            finish(.failure(WalletAPIError.invalidResponse("Apple Sign In returned an unsupported credential.")))
            return
        }
        guard credential.state == expectedState else {
            finish(.failure(WalletAPIError.invalidResponse("Apple Sign In state verification failed.")))
            return
        }
        let appleUserID = credential.user
        guard !appleUserID.isEmpty else {
            finish(.failure(WalletAPIError.invalidResponse("Apple Sign In did not return a user identifier.")))
            return
        }
        // Owning-parent check for recovery and renewal: refuse any other Apple
        // account before a token is exchanged or a session is stored.
        if let requiredAppleUserID, appleUserID != requiredAppleUserID {
            finish(.failure(WalletAPIError.identityMismatch))
            return
        }
        guard let identityToken = credential.identityToken,
              let identityTokenString = String(data: identityToken, encoding: .utf8),
              !identityTokenString.isEmpty,
              let signedNonce = expectedSignedNonce else {
            finish(.failure(WalletAPIError.invalidResponse("Apple Sign In did not return an identity token.")))
            return
        }

        let attemptID = activeAttemptID
        exchangeTask = Task { @MainActor [weak self] in
            guard let self, let attemptID else { return }
            do {
                let session = try await self.authenticator.authenticateApple(identityToken: identityTokenString, nonce: signedNonce)
                self.finish(.success(AppleSignInOutcome(session: session, appleUserID: appleUserID)), attemptID: attemptID)
            } catch {
                self.finish(.failure(error), attemptID: attemptID)
            }
        }
    }

    public func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithError error: Error
    ) {
        authorizationControllerDidCompleteWithError(error, controllerID: ObjectIdentifier(controller))
    }

    func authorizationControllerDidCompleteWithError(_ error: Error, controllerID: ObjectIdentifier) {
        guard isActive(controllerID) else { return }
        if let authorizationError = error as? ASAuthorizationError,
           authorizationError.code == .canceled {
            finish(.failure(WalletAPIError.cancelled))
        } else {
            finish(.failure(WalletAPIError.network("Apple Sign In could not be completed. Please try again.")))
        }
    }

    public func presentationAnchor(for _: ASAuthorizationController) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
            ?? ASPresentationAnchor()
    }

    private func isActive(_ controllerID: ObjectIdentifier) -> Bool {
        guard continuation != nil,
              let activeControllerID = activeAuthorizationControllerID else {
            return false
        }
        return activeControllerID == controllerID
    }

    private func cancel(attemptID: UUID) {
        guard activeAttemptID == attemptID else { return }
        guard continuation != nil else {
            cancellationRequestedFor = attemptID
            return
        }
        finish(.failure(CancellationError()), attemptID: attemptID, cancelController: true)
    }

    private func timedOut(attemptID: UUID) {
        finish(.failure(WalletAPIError.timedOut), attemptID: attemptID, cancelController: true)
    }

    private func finish(
        _ result: Result<AppleSignInOutcome, Error>,
        attemptID: UUID? = nil,
        cancelController: Bool = false
    ) {
        guard let activeAttemptID,
              attemptID == nil || attemptID == activeAttemptID else {
            return
        }

        let continuation = continuation
        let adapter = authorizationControllerAdapter
        self.continuation = nil
        self.activeAttemptID = nil
        self.cancellationRequestedFor = nil
        self.expectedState = nil
        self.expectedSignedNonce = nil
        self.requiredAppleUserID = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        exchangeTask?.cancel()
        exchangeTask = nil
        activeAuthorizationControllerID = nil
        if cancelController {
            adapter?.cancel()
        }
        authorizationControllerAdapter = nil
        continuation?.resume(with: result)
    }
}
