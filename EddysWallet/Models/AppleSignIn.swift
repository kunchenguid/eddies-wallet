import AuthenticationServices
import UIKit

@MainActor
public final class AppleSignInCoordinator: NSObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    private let authenticator: any ParentAuthenticator
    private var continuation: CheckedContinuation<AuthSession, Error>?
    private var expectedState: String?
    private var expectedSignedNonce: String?

    public init(authenticator: any ParentAuthenticator) {
        self.authenticator = authenticator
    }

    public func signIn() async throws -> AuthSession {
        guard continuation == nil else {
            throw WalletAPIError.server(statusCode: 409, code: "AUTHENTICATION_IN_PROGRESS", message: "Sign in is already in progress.")
        }
        let rawNonce = try AppleNonce.randomString()
        let signedNonce = AppleNonce.sha256(rawNonce)
        let state = try AppleNonce.randomString()
        expectedState = state
        expectedSignedNonce = signedNonce

        let request = ASAuthorizationAppleIDProvider().createRequest()
        request.requestedScopes = [.email]
        // Apple signs the SHA-256 nonce into the identity token. The same signed
        // nonce is sent to the API, which verifies it against that claim.
        request.nonce = signedNonce
        request.state = state
        let controller = ASAuthorizationController(authorizationRequests: [request])
        controller.delegate = self
        controller.presentationContextProvider = self

        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            controller.performRequests()
        }
    }

    public func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithAuthorization authorization: ASAuthorization
    ) {
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else {
            finish(.failure(WalletAPIError.invalidResponse("Apple Sign In returned an unsupported credential.")))
            return
        }
        guard credential.state == expectedState else {
            finish(.failure(WalletAPIError.invalidResponse("Apple Sign In state verification failed.")))
            return
        }
        guard let identityToken = credential.identityToken,
              let identityTokenString = String(data: identityToken, encoding: .utf8),
              !identityTokenString.isEmpty,
              let signedNonce = expectedSignedNonce else {
            finish(.failure(WalletAPIError.invalidResponse("Apple Sign In did not return an identity token.")))
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let session = try await authenticator.authenticateApple(identityToken: identityTokenString, nonce: signedNonce)
                finish(.success(session))
            } catch {
                finish(.failure(error))
            }
        }
    }

    public func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithError error: Error
    ) {
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

    private func finish(_ result: Result<AuthSession, Error>) {
        let continuation = continuation
        self.continuation = nil
        expectedState = nil
        expectedSignedNonce = nil
        continuation?.resume(with: result)
    }
}
