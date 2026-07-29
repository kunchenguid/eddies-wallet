import Combine
import Foundation

/// Retry policy for the parent PIN gate. After `maxAttempts` consecutive
/// failures the keypad pauses for `cooldownSeconds`.
public enum WalletRootRoute: Equatable, Sendable {
    case welcome
    case setup
    case kidHome
}

public struct ParentGatePolicy: Sendable {
    public let maxAttempts: Int
    public let cooldownSeconds: TimeInterval

    public init(maxAttempts: Int, cooldownSeconds: TimeInterval) {
        self.maxAttempts = maxAttempts
        self.cooldownSeconds = cooldownSeconds
    }

    public static let standard = ParentGatePolicy(maxAttempts: 5, cooldownSeconds: 30)
}

@MainActor
public final class WalletStore: ObservableObject {
    @Published public private(set) var snapshot: WalletSnapshot
    @Published public private(set) var authorityState: WalletAuthorityState
    @Published public private(set) var purchaseAttempt: PurchaseAttemptState = .idle
    @Published public private(set) var cloudEntitlement: CloudEntitlementState = .none
    /// Transient parent elevation over the kid home. In-memory only, never
    /// persisted: a cold launch of a configured app always rests on the kid
    /// home, and backgrounding drops any parent context immediately.
    @Published public private(set) var elevation: ParentElevation = .none
    @Published public private(set) var gateRoute: ParentGateRoute = .pinEntry
    @Published public private(set) var isSignedIn: Bool
    @Published public private(set) var needsSetup = false
    @Published public private(set) var isLoading = false
    @Published public private(set) var isSigningIn = false
    /// Parent-facing error text. Rendered only on parent surfaces; the kid
    /// home derives calm kid wording from `isOffline`/`sessionExpired`.
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var gateErrorMessage: String?
    @Published public private(set) var isOffline = false
    @Published public private(set) var sessionExpired = false
    /// Set once after first-run setup so the Parent area can spotlight the
    /// first deposit/allowance jobs before handing the device to the kid.
    @Published public private(set) var showsFirstActionsHandoff = false
    @Published public private(set) var pin = ""
    @Published public private(set) var pinError = false
    @Published public private(set) var cooldownSecondsRemaining = 0

    public let repository: any WalletRepository
    public let gatePolicy: ParentGatePolicy
    private let appleSignInProvider: (any AppleSignInProviding)?
    private let pinStore: any ParentPINStore
    private let identityStore: any ParentIdentityStore
    private var failedPINAttempts = 0
    private var cooldownUntil: Date?
    private var cooldownTask: Task<Void, Never>?
    private var refreshGeneration = 0

    public init(
        repository: (any WalletRepository)? = nil,
        appleSignInProvider: (any AppleSignInProviding)? = nil,
        initiallySignedIn: Bool? = nil,
        pinStore: (any ParentPINStore)? = nil,
        identityStore: (any ParentIdentityStore)? = nil,
        gatePolicy: ParentGatePolicy = .standard
    ) {
        let resolvedRepository = repository ?? (try! LocalWalletRepository())
        self.repository = resolvedRepository
        self.snapshot = resolvedRepository.childSnapshot()
        let configured = resolvedRepository.hasConfiguredKid
        self.isSignedIn = initiallySignedIn ?? configured
        if let local = resolvedRepository as? LocalWalletRepository, let lineageID = local.lineageID {
            self.authorityState = .local(lineageID: lineageID)
        } else if configured {
            self.authorityState = .legacyService
        } else {
            self.authorityState = .unconfigured
        }
        self.sessionExpired = resolvedRepository.hasConfiguredKid && !resolvedRepository.isAuthenticated && !(resolvedRepository is LocalWalletRepository)
        self.gatePolicy = gatePolicy
        let isMockRepository = resolvedRepository is MockWalletRepository
        self.pinStore = pinStore ?? (isMockRepository ? InMemoryParentPINStore(pin: "1234") : KeychainParentPINStore())
        self.identityStore = identityStore ?? (isMockRepository ? InMemoryParentIdentityStore() : KeychainParentIdentityStore())
        if let appleSignInProvider {
            self.appleSignInProvider = appleSignInProvider
        } else if let authenticator = resolvedRepository as? any ParentAuthenticator {
            self.appleSignInProvider = AppleSignInCoordinator(authenticator: authenticator)
        } else {
            // Free local setup uses native Apple identity only. Backend sessions
            // are only exchanged by explicit Cloud flows.
            self.appleSignInProvider = AppleSignInCoordinator()
        }

        if self.isSignedIn, !isMockRepository {
            Task { [weak self] in await self?.refresh() }
        }
    }

    public static func preview() -> WalletStore {
        WalletStore(
            repository: MockWalletRepository(),
            initiallySignedIn: true,
            pinStore: InMemoryParentPINStore(pin: "1234"),
            identityStore: InMemoryParentIdentityStore(appleUserID: "preview-apple-user")
        )
    }

    // MARK: - Derived state

    public var isElevated: Bool { elevation == .active }
    /// Root navigation is authority-driven. The compatibility booleans remain
    /// for existing parent-gate tests, not as the app's source of truth.
    public var rootRoute: WalletRootRoute {
        switch authorityState {
        case .unconfigured, .authenticatingParent: return .welcome
        case .localSetup: return .setup
        default: return .kidHome
        }
    }
    public var isCoolingDown: Bool { cooldownSecondsRemaining > 0 }
    public var attemptsRemaining: Int { max(0, gatePolicy.maxAttempts - failedPINAttempts) }
    /// Whether this device holds identity evidence for the owning parent.
    /// Without it the recovery path cannot verify a fresh Apple sign-in.
    public var canVerifyOwningParent: Bool { identityStore.appleUserID != nil }
    /// The role the next snapshot refresh is requested for. Everything
    /// outside the active Parent area reads the read-only child view.
    public var viewRole: UserRole { elevation == .active ? .parent : .child }

    // MARK: - Sign in

    public func signInWithApple() async {
        guard let appleSignInProvider else {
            errorMessage = "Apple Sign In is unavailable in this build."
            return
        }
        isSigningIn = true
        errorMessage = nil
        do {
            let outcome = try await appleSignInProvider.signIn(requiredAppleUserID: nil)
            do {
                try identityStore.save(appleUserID: outcome.appleUserID)
            } catch {
                repository.clearAuthentication()
                isSignedIn = repository.hasConfiguredKid
                sessionExpired = repository.hasConfiguredKid
                errorMessage = userMessage(for: error)
                isSigningIn = false
                return
            }
            isSignedIn = true
            sessionExpired = false
            if repository.hasConfiguredKid {
                await refresh()
            } else {
                authorityState = .localSetup
                needsSetup = true
            }
        } catch {
            if case WalletAPIError.cancelled = error {
                errorMessage = nil
            } else {
                errorMessage = userMessage(for: error)
            }
        }
        isSigningIn = false
    }

    // MARK: - Parent gate

    /// Opens the Parent gate from the kid home. Never leaks parent data:
    /// it only routes to PIN entry, or to owning-parent re-authentication
    /// when the session expired or no PIN exists on this device.
    public func openParentGate() {
        guard isSignedIn, !needsSetup, elevation == .none else { return }
        refreshCooldownState()
        pin = ""
        pinError = false
        gateErrorMessage = nil
        if pinStore.pin == nil {
            gateRoute = .reauth(.missingPIN)
        } else if sessionExpired {
            gateRoute = .reauth(.sessionExpired)
        } else {
            gateRoute = .pinEntry
        }
        elevation = .gate
    }

    public func cancelParentGate() {
        guard elevation == .gate else { return }
        deElevate()
    }

    /// The gate's forgotten-PIN path: recovery is a fresh Sign in with Apple
    /// by the owning parent, then a new PIN. Family data stays intact.
    public func requestPINRecovery() {
        guard elevation == .gate else { return }
        pin = ""
        pinError = false
        gateErrorMessage = nil
        gateRoute = .reauth(.forgotPIN)
    }

    public func appendPINDigit(_ digit: String) {
        guard elevation == .gate, gateRoute == .pinEntry else { return }
        refreshCooldownState()
        guard !isCoolingDown else { return }
        guard digit.count == 1, digit.first?.isNumber == true, pin.count < 4 else { return }
        pin.append(digit)
        pinError = false
        guard pin.count == 4 else { return }
        if pin == pinStore.pin {
            clearPINFailureState()
            enterParentArea()
        } else {
            pin = ""
            pinError = true
            failedPINAttempts += 1
            if failedPINAttempts >= gatePolicy.maxAttempts {
                startCooldown()
            }
        }
    }

    public func deletePINDigit() {
        guard elevation == .gate, gateRoute == .pinEntry, !pin.isEmpty else { return }
        pin.removeLast()
        pinError = false
    }

    /// Performs the gate's fresh Sign in with Apple. The attempt must present
    /// the stored owning-parent Apple user identifier; any other Apple
    /// account is refused before a token is exchanged.
    public func reauthenticateOwningParent() async {
        guard elevation == .gate, case .reauth(let reason) = gateRoute else { return }
        guard let appleSignInProvider else {
            gateErrorMessage = "Apple Sign In is unavailable in this build."
            return
        }
        guard let owningParentID = identityStore.appleUserID else {
            gateErrorMessage = "This device cannot confirm which Apple account manages this wallet."
            return
        }
        isSigningIn = true
        gateErrorMessage = nil
        defer { isSigningIn = false }
        do {
            _ = try await appleSignInProvider.signIn(requiredAppleUserID: owningParentID)
            sessionExpired = false
            // If the app was backgrounded mid-authentication, elevation has
            // already been dropped; never resume a parent flow from here.
            guard elevation == .gate else { return }
            switch reason {
            case .forgotPIN, .missingPIN:
                gateRoute = .setPIN
            case .sessionExpired:
                gateRoute = pinStore.pin == nil ? .setPIN : .pinEntry
            }
        } catch {
            guard elevation == .gate else { return }
            if case WalletAPIError.cancelled = error {
                gateErrorMessage = nil
            } else {
                gateErrorMessage = userMessage(for: error)
            }
        }
    }

    /// Saves the new parent PIN chosen after successful owning-parent
    /// re-authentication, then opens the Parent area.
    @discardableResult
    public func completeGatePINSetup(pin newPIN: String, confirmation: String) -> Bool {
        guard elevation == .gate, gateRoute == .setPIN else { return false }
        guard newPIN.count == 4, newPIN.allSatisfy(\.isNumber), newPIN == confirmation else {
            gateErrorMessage = "Choose and confirm a four-digit parent PIN."
            return false
        }
        do {
            try pinStore.save(pin: newPIN)
        } catch {
            gateErrorMessage = userMessage(for: error)
            return false
        }
        gateErrorMessage = nil
        clearPINFailureState()
        enterParentArea()
        return true
    }

    // MARK: - Parent area

    public func exitParentArea() {
        guard elevation == .active else { return }
        deElevate()
    }

    /// Called when the scene leaves the foreground. Any parent elevation and
    /// in-progress parent flow drops immediately; kid data may stay visible.
    public func handleAppBackgrounded() {
        if elevation == .none {
            refreshGeneration += 1
            isLoading = false
            return
        }
        deElevate()
    }

    public func dismissFirstActionsHandoff() {
        showsFirstActionsHandoff = false
    }

    /// Changes the parent PIN from inside the Parent area. Requires the
    /// current PIN. Returns an error message, or nil on success.
    public func changeParentPIN(current: String, new: String, confirmation: String) -> String? {
        guard elevation == .active else {
            return "Only the Parent area can change the parent PIN."
        }
        guard current == pinStore.pin else {
            return "The current PIN is not correct."
        }
        guard new.count == 4, new.allSatisfy(\.isNumber), new == confirmation else {
            return "Choose and confirm a four-digit parent PIN."
        }
        do {
            try pinStore.save(pin: new)
        } catch {
            return userMessage(for: error)
        }
        return nil
    }

    // MARK: - Wallet data

    public func refresh() async {
        guard isSignedIn else { return }
        guard repository.hasConfiguredKid else {
            needsSetup = true
            if authorityState == .unconfigured { authorityState = .localSetup }
            return
        }
        let requestedRole = viewRole
        let generation = refreshGeneration
        isLoading = true
        do {
            let refreshed = try await repository.refresh(for: requestedRole)
            guard generation == refreshGeneration, requestedRole == viewRole else { return }
            snapshot = refreshed
            needsSetup = false
            if let local = repository as? LocalWalletRepository, let lineageID = local.lineageID {
                authorityState = .local(lineageID: lineageID)
            }
            errorMessage = nil
            isOffline = false
            sessionExpired = false
        } catch let error as WalletAPIError {
            switch error {
            case .familyNotSetup:
                guard generation == refreshGeneration, requestedRole == viewRole else { return }
                needsSetup = true
                errorMessage = nil
            case .unauthorized, .noSession:
                if repository.hasConfiguredKid {
                    sessionExpired = true
                    errorMessage = "Your parent session expired. Sign in with Apple again."
                    snapshot = repository.childSnapshot()
                    if elevation != .none { deElevate() }
                } else {
                    isSignedIn = false
                    needsSetup = false
                    sessionExpired = false
                    errorMessage = "Sign in with Apple again to continue setup."
                    snapshot = .empty()
                    if elevation != .none { deElevate() }
                }
            case .network:
                guard generation == refreshGeneration, requestedRole == viewRole else { return }
                isOffline = true
                errorMessage = userMessage(for: error)
                snapshot = requestedRole == .child ? repository.childSnapshot() : repository.snapshot()
            default:
                guard generation == refreshGeneration, requestedRole == viewRole else { return }
                errorMessage = userMessage(for: error)
                snapshot = requestedRole == .child ? repository.childSnapshot() : repository.snapshot()
            }
        } catch {
            guard generation == refreshGeneration, requestedRole == viewRole else { return }
            errorMessage = "The wallet could not be updated. Your last accepted balance is still shown."
            snapshot = requestedRole == .child ? repository.childSnapshot() : repository.snapshot()
        }
        if generation == refreshGeneration {
            isLoading = false
        }
    }

    public func setupParent(_ setup: ParentSetup, pin: String, confirmation: String) async -> Bool {
        guard pin.count == 4, pin.allSatisfy(\.isNumber), pin == confirmation else {
            errorMessage = "Choose and confirm a four-digit parent PIN."
            return false
        }
        let generation = refreshGeneration
        isLoading = true
        errorMessage = nil
        do {
            _ = try await repository.setup(setup)
        } catch {
            guard generation == refreshGeneration else { return false }
            errorMessage = userMessage(for: error)
            isLoading = false
            return false
        }
        guard generation == refreshGeneration else {
            needsSetup = false
            isSignedIn = true
            isLoading = false
            snapshot = repository.childSnapshot()
            elevation = .none
            gateRoute = .pinEntry
            Task { [weak self] in await self?.refresh() }
            return false
        }
        do {
            try pinStore.save(pin: pin)
            snapshot = repository.snapshot()
            needsSetup = false
            isSignedIn = true
            if let local = repository as? LocalWalletRepository, let lineageID = local.lineageID {
                authorityState = .local(lineageID: lineageID)
            }
            isLoading = false
            // The parent just proved themselves with Apple and set the PIN:
            // hand off through the Parent area with the first-actions
            // spotlight, then the kid home becomes every later launch.
            clearPINFailureState()
            showsFirstActionsHandoff = true
            elevation = .active
            gateRoute = .pinEntry
            return true
        } catch {
            errorMessage = userMessage(for: error)
            gateErrorMessage = errorMessage
            needsSetup = false
            isSignedIn = true
            isLoading = false
            snapshot = repository.childSnapshot()
            elevation = .gate
            gateRoute = .reauth(.missingPIN)
            Task { [weak self] in await self?.refresh() }
            return false
        }
    }

    @discardableResult
    public func setAllowance(_ command: AllowanceRuleCommand) async -> Bool {
        guard elevation == .active else {
            errorMessage = "Only the Parent area can change the allowance rule."
            return false
        }
        let generation = refreshGeneration
        isLoading = true
        errorMessage = nil
        do {
            let refreshed = try await repository.setAllowance(command)
            if generation == refreshGeneration, elevation == .active {
                snapshot = refreshed
                isLoading = false
            }
            return true
        } catch let error as WalletAPIError {
            if error == .unauthorized || error == .noSession {
                sessionExpired = repository.hasConfiguredKid
                if elevation != .none { deElevate() }
            } else if generation == refreshGeneration, elevation == .active {
                errorMessage = userMessage(for: error)
                isLoading = false
            }
            return false
        } catch {
            if generation == refreshGeneration, elevation == .active {
                errorMessage = userMessage(for: error)
                isLoading = false
            }
            return false
        }
    }

    @discardableResult
    public func updateChildProfile(nickname: String) async -> Bool {
        guard elevation == .active else {
            errorMessage = "Only the Parent area can edit the child profile."
            return false
        }
        guard ChildProfileCopy.configuredNickname(from: nickname) != nil else {
            errorMessage = "Enter a child nickname."
            return false
        }
        let generation = refreshGeneration
        isLoading = true
        errorMessage = nil
        do {
            let refreshed = try await repository.updateChildProfile(ChildProfileUpdate(nickname: nickname))
            if generation == refreshGeneration, elevation == .active {
                snapshot = refreshed
                isLoading = false
            }
            return true
        } catch let error as WalletAPIError {
            if error == .unauthorized || error == .noSession {
                sessionExpired = repository.hasConfiguredKid
                if elevation != .none { deElevate() }
            } else if generation == refreshGeneration, elevation == .active {
                errorMessage = userMessage(for: error)
                isLoading = false
            }
            return false
        } catch {
            if generation == refreshGeneration, elevation == .active {
                errorMessage = userMessage(for: error)
                isLoading = false
            }
            return false
        }
    }

    @discardableResult
    public func submit(_ command: WalletCommand) async -> CommandResult {
        guard elevation == .active else {
            let event = WalletEvent(
                type: activityType(for: command.kind),
                amountCents: max(command.amountCents, 0),
                syncState: .rejected,
                explanation: ChildProfileCopy.readOnlyMessage(nickname: snapshot.configuredChildNickname),
                rejectionReason: "Only a parent in the Parent area can record virtual money events."
            )
            return .rejected(event)
        }
        let generation = refreshGeneration
        do {
            let result = try await repository.submit(command)
            if generation == refreshGeneration, elevation == .active {
                snapshot = repository.snapshot()
            }
            return result
        } catch let error as WalletAPIError {
            if error == .unauthorized || error == .noSession {
                sessionExpired = repository.hasConfiguredKid
                if elevation != .none { deElevate() }
            }
            let event = WalletEvent(
                type: activityType(for: command.kind),
                amountCents: max(command.amountCents, 0),
                reason: command.reason,
                syncState: .rejected,
                explanation: "This action was not recorded and did not change the accepted balance.",
                rejectionReason: userMessage(for: error)
            )
            if generation == refreshGeneration, elevation == .active {
                errorMessage = userMessage(for: error)
            }
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

    /// Removes the local session, parent PIN, owner identity evidence, and
    /// cached snapshot from this device. Reachable only from the Parent area
    /// or the pre-family setup escape.
    public func signOut() {
        let isPreFamilySetup = isSignedIn && needsSetup && !repository.hasConfiguredKid
        guard elevation == .active || isPreFamilySetup else { return }
        refreshGeneration += 1
        repository.clearSession()
        authorityState = .unconfigured
        purchaseAttempt = .idle
        cloudEntitlement = .none
        isSignedIn = false
        needsSetup = false
        pinStore.clear()
        identityStore.clear()
        snapshot = .empty()
        errorMessage = nil
        sessionExpired = false
        isOffline = false
        showsFirstActionsHandoff = false
        clearPINFailureState()
        deElevate()
    }

    #if DEBUG
    /// Debug-only scenario seam. This is intentionally compiled out of
    /// Release, and is the sole place scripted authority/entitlement states
    /// may enter the app.
    func applyDebugCloudState(authority: WalletAuthorityState, purchase: PurchaseAttemptState = .idle, entitlement: CloudEntitlementState = .none) {
        authorityState = authority
        purchaseAttempt = purchase
        cloudEntitlement = entitlement
    }
    #endif

    // MARK: - Private helpers

    private func enterParentArea() {
        refreshGeneration += 1
        pin = ""
        pinError = false
        gateErrorMessage = nil
        gateRoute = .pinEntry
        elevation = .active
        Task { [weak self] in await self?.refresh() }
    }

    private func deElevate() {
        refreshGeneration += 1
        elevation = .none
        gateRoute = .pinEntry
        pin = ""
        pinError = false
        gateErrorMessage = nil
        showsFirstActionsHandoff = false
        snapshot = repository.childSnapshot()
        isLoading = false
        if repository.isAuthenticated {
            Task { [weak self] in await self?.refresh() }
        }
    }

    private func clearPINFailureState() {
        failedPINAttempts = 0
        cooldownUntil = nil
        cooldownTask?.cancel()
        cooldownTask = nil
        cooldownSecondsRemaining = 0
    }

    private func startCooldown() {
        cooldownUntil = Date().addingTimeInterval(gatePolicy.cooldownSeconds)
        updateCooldownRemaining()
        cooldownTask?.cancel()
        cooldownTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.refreshCooldownState()
                if !self.isCoolingDown { return }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
    }

    private func refreshCooldownState() {
        updateCooldownRemaining()
        if cooldownUntil != nil, cooldownSecondsRemaining == 0 {
            cooldownUntil = nil
            failedPINAttempts = 0
            pinError = false
        }
    }

    private func updateCooldownRemaining() {
        let remaining = cooldownUntil.map { max(0, Int($0.timeIntervalSinceNow.rounded(.up))) } ?? 0
        if remaining != cooldownSecondsRemaining {
            cooldownSecondsRemaining = remaining
        }
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
