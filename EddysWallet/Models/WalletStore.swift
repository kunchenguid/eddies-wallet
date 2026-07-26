import Combine
import Foundation

@MainActor
public final class WalletStore: ObservableObject {
    @Published public private(set) var snapshot: WalletSnapshot
    @Published public private(set) var role: UserRole = .parent
    @Published public private(set) var isSignedIn: Bool
    @Published public private(set) var needsSetup = false
    @Published public private(set) var needsPINSetup = false
    @Published public private(set) var isLoading = false
    @Published public private(set) var isSigningIn = false
    @Published public private(set) var errorMessage: String?
    @Published public var isShowingPinGate = false
    @Published public private(set) var pin = ""
    @Published public private(set) var pinError = false

    public let repository: any WalletRepository
    private let appleSignInCoordinator: AppleSignInCoordinator?
    private let pinStore: any ParentPINStore

    public init(
        repository: (any WalletRepository)? = nil,
        appleSignInCoordinator: AppleSignInCoordinator? = nil,
        initiallySignedIn: Bool? = nil,
        pinStore: (any ParentPINStore)? = nil
    ) {
        let resolvedRepository = repository ?? APIWalletRepository()
        self.repository = resolvedRepository
        self.snapshot = resolvedRepository.snapshot()
        self.isSignedIn = initiallySignedIn ?? resolvedRepository.isAuthenticated
        self.pinStore = pinStore ?? ((resolvedRepository is MockWalletRepository) ? InMemoryParentPINStore(pin: "1234") : KeychainParentPINStore())
        if let appleSignInCoordinator {
            self.appleSignInCoordinator = appleSignInCoordinator
        } else if let authenticator = resolvedRepository as? any ParentAuthenticator {
            self.appleSignInCoordinator = AppleSignInCoordinator(authenticator: authenticator)
        } else {
            self.appleSignInCoordinator = nil
        }
        self.needsPINSetup = self.isSignedIn && self.pinStore.pin == nil

        if self.isSignedIn, !(resolvedRepository is MockWalletRepository) {
            Task { [weak self] in await self?.refresh() }
        }
    }

    public static func preview() -> WalletStore {
        WalletStore(repository: MockWalletRepository(), initiallySignedIn: true, pinStore: InMemoryParentPINStore(pin: "1234"))
    }

    public func signInWithApple() async {
        guard let appleSignInCoordinator else {
            errorMessage = "Apple Sign In is unavailable in this build."
            return
        }
        isSigningIn = true
        errorMessage = nil
        do {
            _ = try await appleSignInCoordinator.signIn()
            isSignedIn = true
            await refresh()
        } catch {
            if case WalletAPIError.cancelled = error {
                errorMessage = nil
            } else {
                errorMessage = userMessage(for: error)
            }
        }
        isSigningIn = false
    }

    public func switchRole(to nextRole: UserRole) {
        guard nextRole != role else { return }
        if nextRole == .parent {
            guard pinStore.pin != nil else {
                needsPINSetup = true
                return
            }
            pin = ""
            pinError = false
            isShowingPinGate = true
        } else {
            role = .child
            Task { [weak self] in await self?.refresh() }
        }
    }

    public func appendPINDigit(_ digit: String) {
        guard digit.count == 1, digit.first?.isNumber == true, pin.count < 4 else { return }
        pin.append(digit)
        pinError = false
        if pin.count == 4 {
            if pin == pinStore.pin {
                role = .parent
                isShowingPinGate = false
                pin = ""
                Task { [weak self] in await self?.refresh() }
            } else {
                pinError = true
                pin = ""
            }
        }
    }

    public func deletePINDigit() {
        guard !pin.isEmpty else { return }
        pin.removeLast()
        pinError = false
    }

    public func dismissPinGate() {
        isShowingPinGate = false
        pin = ""
        pinError = false
    }

    public func refresh() async {
        guard isSignedIn else { return }
        isLoading = true
        do {
            snapshot = try await repository.refresh(for: role)
            needsSetup = false
            errorMessage = nil
        } catch let error as WalletAPIError {
            switch error {
            case .familyNotSetup:
                needsSetup = true
                errorMessage = nil
            case .unauthorized, .noSession:
                signOut()
                errorMessage = "Your parent session expired. Sign in with Apple again."
            default:
                errorMessage = userMessage(for: error)
                snapshot = repository.snapshot()
            }
        } catch {
            errorMessage = "The wallet could not be updated. Your last accepted balance is still shown."
            snapshot = repository.snapshot()
        }
        isLoading = false
    }

    public func setupParent(_ setup: ParentSetup, pin: String, confirmation: String) async -> Bool {
        guard pin.count == 4, pin.allSatisfy(\.isNumber), pin == confirmation else {
            errorMessage = "Choose and confirm a four-digit parent PIN."
            return false
        }
        isLoading = true
        errorMessage = nil
        do {
            snapshot = try await repository.setup(setup)
            try pinStore.save(pin: pin)
            needsSetup = false
            needsPINSetup = false
            isSignedIn = true
            isLoading = false
            return true
        } catch {
            errorMessage = userMessage(for: error)
            isLoading = false
            return false
        }
    }

    public func setParentPIN(_ pin: String, confirmation: String) -> Bool {
        guard pin.count == 4, pin.allSatisfy(\.isNumber), pin == confirmation else {
            errorMessage = "Choose and confirm a four-digit parent PIN."
            return false
        }
        do {
            try pinStore.save(pin: pin)
            needsPINSetup = false
            errorMessage = nil
            return true
        } catch {
            errorMessage = userMessage(for: error)
            return false
        }
    }

    @discardableResult
    public func setAllowance(_ command: AllowanceRuleCommand) async -> Bool {
        isLoading = true
        errorMessage = nil
        do {
            snapshot = try await repository.setAllowance(command)
            isLoading = false
            return true
        } catch {
            errorMessage = userMessage(for: error)
            isLoading = false
            return false
        }
    }

    @discardableResult
    public func submit(_ command: WalletCommand) async -> CommandResult {
        guard role == .parent else {
            let event = WalletEvent(
                type: .deposit,
                amountCents: command.amountCents,
                syncState: .rejected,
                explanation: "Eddie's view is read-only. This action was not recorded.",
                rejectionReason: "Only parent mode can record virtual money events."
            )
            return .rejected(event)
        }
        do {
            let result = try await repository.submit(command)
            snapshot = repository.snapshot()
            return result
        } catch let error as WalletAPIError {
            if case .unauthorized = error { signOut() }
            let event = WalletEvent(
                type: activityType(for: command.kind),
                amountCents: max(command.amountCents, 0),
                reason: command.reason,
                syncState: .rejected,
                explanation: "This action was not recorded and did not change the accepted balance.",
                rejectionReason: userMessage(for: error)
            )
            errorMessage = userMessage(for: error)
            return .rejected(event)
        } catch {
            let event = WalletEvent(
                type: activityType(for: command.kind),
                amountCents: max(command.amountCents, 0),
                reason: command.reason,
                syncState: .rejected,
                explanation: "This action was not recorded and did not change the accepted balance.",
                rejectionReason: "The action could not be confirmed."
            )
            return .rejected(event)
        }
    }

    public func signOut() {
        repository.clearSession()
        isSignedIn = false
        needsSetup = false
        needsPINSetup = false
        pinStore.clear()
        role = .parent
        snapshot = .empty()
        errorMessage = nil
        dismissPinGate()
    }

    private func userMessage(for error: Error) -> String {
        if let apiError = error as? WalletAPIError { return apiError.localizedDescription }
        return "The wallet could not complete that action. The accepted balance was not changed."
    }

    private func activityType(for kind: WalletCommandKind) -> ActivityType {
        switch kind {
        case .allowance: .allowance
        case .deposit: .deposit
        case .withdrawal: .withdrawal
        case .loan: .loan
        case .repayment: .repayment
        }
    }
}
