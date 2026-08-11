import Combine
import Foundation

/// Retry policy for the parent PIN gate. After `maxAttempts` consecutive
/// failures the keypad pauses for `cooldownSeconds`.
public enum WalletRootRoute: Equatable, Sendable {
    case welcome
    case setup
    case existingWallet
    case kidHome
    case recovery
}

/// Presentation outcome for the irreversible account-delete command. A lost
/// or unreadable server answer after local erasure remains intentionally
/// distinct from confirmed deletion.
public enum AccountDeletionAttemptOutcome: Equatable, Sendable {
    case deleted
    case refused(String)
    case incomplete(String)
}

/// The deliberate first-run choice shown when the signed-in parent's account
/// already holds a wallet. Nothing here has changed anything on the service:
/// only an explicit acceptance sends the transition.
public enum ExistingWalletRecoveryState: Equatable, Sendable {
    case offered(CloudExistingWalletOffer)
    case recovering(CloudExistingWalletOffer)
    /// The accepted transition was refused. The wallet is untouched and the
    /// local-first path is still open.
    case refused(CloudExistingWalletOffer, CloudLegacyActivationRefusal)

    public var offer: CloudExistingWalletOffer {
        switch self {
        case .offered(let offer), .recovering(let offer), .refused(let offer, _): offer
        }
    }

    public var isWorking: Bool {
        if case .recovering = self { return true }
        return false
    }

    public var refusalMessage: String? {
        guard case .refused(_, let refusal) = self else { return nil }
        return refusal.parentMessage
    }

    /// Whether the parent may ask for this wallet again. A refusal that will
    /// not clear offers no retry, so nothing loops.
    public var canRetry: Bool {
        guard case .refused(_, let refusal) = self else { return false }
        return refusal.permitsSameActionRetry || refusal.requiresFreshDiscovery
    }
}

/// Why the local-first setup screen is also telling the parent something about
/// a wallet that may exist on their account.
public enum ExistingWalletNotice: Equatable, Sendable {
    /// The check could not be completed - offline, timed out, or the service
    /// was unavailable. Nothing is claimed either way.
    case checkUnavailable
    /// A wallet exists on the account, but moving it needs Cloud and the
    /// subscription is not active.
    case foundButCloudInactive

    @MainActor
    public var message: String {
        switch self {
        case .checkUnavailable:
            "This \(DeviceCopy.deviceNoun) could not check whether your Apple account already has a wallet. You can set one up here and check again later."
        case .foundButCloudInactive:
            "Your Apple account already has a wallet. Moving it to this \(DeviceCopy.deviceNoun) needs Cloud, which is not active right now."
        }
    }
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
enum WalletRepositoryFactory {
    static func makeDefault() -> any WalletRepository {
        return makeDefault(cloudClient: CloudAPIClient())
    }

    static func makeDefault(cloudClient: CloudAPIClient) -> any WalletRepository {
        return makeDefault(
            localProvider: { try LocalWalletRepository() },
            legacyProvider: { APIWalletRepository() },
            cloudClient: cloudClient
        )
    }

    static func makeDefault(
        localProvider: () throws -> LocalWalletRepository,
        legacyProvider: () -> any WalletRepository,
        cloudClient: CloudAPIClient? = nil
    ) -> any WalletRepository {
        do {
            let local = try localProvider()
            return select(local: local, legacy: legacyProvider(), cloudClient: cloudClient)
        } catch {
            return LocalWalletRecoveryRepository(state: .storageUnavailable)
        }
    }

    static func select(
        local: LocalWalletRepository,
        legacy: @autoclosure () -> any WalletRepository,
        cloudClient: CloudAPIClient? = nil
    ) -> any WalletRepository {
        if let lineageID = local.cloudAuthorityLineageID, let revision = local.cloudRevision {
            return CloudWalletRepository(client: cloudClient ?? CloudAPIClient(), replica: local, lineageID: lineageID, revision: revision)
        }
        return local.hasLegacyInputs ? legacy() : local
    }
}

@MainActor
protocol WalletRecoveryProviding: AnyObject {
    var recoveryState: WalletRecoveryState? { get }
}

@MainActor
final class LocalWalletRecoveryRepository: WalletRepository, WalletRecoveryProviding {
    let recoveryState: WalletRecoveryState?

    init(state: WalletRecoveryState) {
        recoveryState = state
    }

    var isAuthenticated: Bool { true }
    var hasConfiguredKid: Bool { true }
    func snapshot() -> WalletSnapshot { .empty() }
    func childSnapshot() -> WalletSnapshot { .empty() }
    func refresh(for _: UserRole) async throws -> WalletSnapshot { throw unavailable() }
    func activity(limit _: Int) async throws -> [WalletEvent] { throw unavailable() }
    func activityDetail(remoteID _: String) async throws -> WalletEvent { throw unavailable() }
    func loanDetail(remoteID _: String) async throws -> LoanDetail { throw unavailable() }
    func submit(_: WalletCommand) async throws -> CommandResult { throw unavailable() }
    func setAllowance(_: AllowanceRuleCommand) async throws -> WalletSnapshot { throw unavailable() }
    func setup(_: ParentSetup) async throws -> WalletSnapshot { throw unavailable() }
    func updateChildProfile(_: ChildProfileUpdate) async throws -> WalletSnapshot { throw unavailable() }
    func clearAuthentication() {}
    func clearSession() throws { throw unavailable() }

    private func unavailable() -> WalletAPIError {
        .invalidResponse("This wallet needs recovery before it can be used.")
    }
}

@MainActor
public final class WalletStore: ObservableObject {
    @Published public private(set) var snapshot: WalletSnapshot
    @Published public private(set) var authorityState: WalletAuthorityState
    @Published public private(set) var purchaseAttempt: PurchaseAttemptState = .idle
    @Published public private(set) var cloudEntitlement: CloudEntitlementState = .none
    @Published public private(set) var accountDeletionEntitlement: CloudEntitlementState?
    /// Transient parent elevation over the kid home. In-memory only, never
    /// persisted: a cold launch of a configured app always rests on the kid
    /// home, and backgrounding drops any parent context immediately.
    @Published public private(set) var elevation: ParentElevation = .none
    @Published public private(set) var gateRoute: ParentGateRoute = .pinEntry
    @Published public private(set) var isSignedIn: Bool
    @Published public private(set) var needsSetup = false
    @Published public private(set) var isLoading = false
    @Published public private(set) var isSigningIn = false
    /// True only while a DELETE request is in flight. Parent-area exit is
    /// disabled then because the server command cannot be cancelled safely.
    @Published public private(set) var isDeletingAccount = false
    @Published public private(set) var accountDeletionPresentation: AccountDeletionPresentation? = nil
    /// A definite server success has erased this device. The terminal screen
    /// stays up until its Done action deliberately returns to Welcome.
    @Published public private(set) var hasDeletedAccount = false
    /// Parent-facing error text. Rendered only on parent surfaces; the kid
    /// home derives calm kid wording from `connection`/`sessionExpired`.
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var gateErrorMessage: String?
    /// What the newest read could reach. Only a device that genuinely reported
    /// no usable network reads as offline: a timeout, TLS, DNS, refused, or
    /// dropped connection is a service this app could not reach, and calling
    /// that "offline" would be false and would hide the real failure.
    @Published public private(set) var connection: WalletConnection = .reached
    /// The privacy-safe shape of the most recent failed request, for the
    /// parent-only connection readout. It never carries account, session,
    /// wallet, or raw error content, never persists, and leaves this device
    /// only when a parent deliberately copies it.
    @Published public private(set) var latestTransportDiagnostic: TransportDiagnostic?
    @Published public private(set) var sessionExpired = false
    /// Set once after first-run setup so the Parent area can spotlight the
    /// first deposit/allowance jobs before handing the device to the kid.
    @Published public private(set) var showsFirstActionsHandoff = false
    @Published public private(set) var pin = ""
    @Published public private(set) var pinError = false
    @Published public private(set) var cooldownSecondsRemaining = 0
    /// Cloud plans are published only when the backend capability and exactly
    /// the two StoreKit products are both ready.
    @Published public private(set) var cloudPlans: [CloudPlan] = []
    @Published public private(set) var cloudMessage: String?
    /// Set when another device moved the Cloud household first, so the parent
    /// reviews the latest accepted balance before retrying.
    @Published public private(set) var needsCloudReview = false
    /// Last result for profile and allowance mutations, which do not create a
    /// ledger event but still need truthful accepted/waiting/rejected copy.
    @Published public private(set) var latestParentMutationOutcome: ParentMutationOutcome?
    /// The first-run existing-wallet choice, when this parent's account already
    /// holds a wallet this device can recover. Non-nil only before setup.
    @Published public private(set) var existingWalletRecovery: ExistingWalletRecoveryState?
    /// What the local-first setup screen has to say about a wallet that may
    /// exist on the account but is not being offered.
    @Published public private(set) var existingWalletNotice: ExistingWalletNotice?

    public private(set) var repository: any WalletRepository
    public let gatePolicy: ParentGatePolicy
    private let appleSignInProvider: (any AppleSignInProviding)?
    private let cloudCoordinator: CloudCoordinator?
    private var cloudObservation: Task<Void, Never>?
    private var cloudActivationTask: Task<Void, Never>?
    private var cloudActivationGeneration = 0
    private let pinStore: any ParentPINStore
    private let identityStore: any ParentIdentityStore
    private let accountDeletionService: (any AccountDeletionPerforming)?
    private let accountDeletionPendingStore: any PendingCommandStore
    private let accountDeletionSnapshotCache: any WalletSnapshotCache
    private let accountDeletionConfiguredKidStore: any ConfiguredKidStore
    private let accountDeletionFlush: () -> Bool
    private var serverConfirmedAccountDeletionID: String?
    /// Opens the protected local store that a service-held wallet is mirrored
    /// into. Used only when a legacy device converges onto Cloud authority.
    private let localReplicaProvider: () throws -> LocalWalletRepository
    /// The idempotency key of the one accepted recovery in flight. Minted once
    /// per acceptance and reused only for retries of that same action.
    private var acceptedRecoveryKey: String?
    private var failedPINAttempts = 0
    private var cooldownUntil: Date?
    private var cooldownTask: Task<Void, Never>?
    private var refreshGeneration = 0
    /// Refreshes overlap by design: this store's own launch read, the kid
    /// home's `.task`, returning from the Parent area, coming back to the
    /// foreground, and every pull-to-refresh can all be in flight together.
    /// Each read is stamped in the order it started so a slow one can never
    /// land last and overwrite what a newer read already published.
    private var refreshAttempts = 0
    /// Set while the scene is out of the foreground, so the return can re-read
    /// the wallet that `handleAppBackgrounded()` retired.
    private var didLeaveForeground = false
    private var firstRunDecisionGeneration = 0
    private var isCommittingFirstRunCloudAdoption = false
    #if DEBUG
    private var debugHasValidCloudReplica: Bool?
    private var debugCloudPlansOverride: [CloudPlan]?
    #endif

    public init(
        repository: (any WalletRepository)? = nil,
        appleSignInProvider: (any AppleSignInProviding)? = nil,
        initiallySignedIn: Bool? = nil,
        pinStore: (any ParentPINStore)? = nil,
        identityStore: (any ParentIdentityStore)? = nil,
        gatePolicy: ParentGatePolicy = .standard,
        cloudCoordinator: CloudCoordinator? = nil,
        localReplicaProvider: (() throws -> LocalWalletRepository)? = nil,
        accountDeletionService: (any AccountDeletionPerforming)? = nil,
        accountDeletionPendingStore: (any PendingCommandStore)? = nil,
        accountDeletionSnapshotCache: (any WalletSnapshotCache)? = nil,
        accountDeletionConfiguredKidStore: (any ConfiguredKidStore)? = nil,
        accountDeletionFlush: @escaping () -> Bool = { UserDefaults.standard.synchronize() }
    ) {
        let resolvedRepository = repository ?? WalletRepositoryFactory.makeDefault()
        self.repository = resolvedRepository
        self.cloudCoordinator = cloudCoordinator
        self.accountDeletionService = accountDeletionService ?? cloudCoordinator
        self.accountDeletionPendingStore = accountDeletionPendingStore ?? UserDefaultsPendingCommandStore()
        self.accountDeletionSnapshotCache = accountDeletionSnapshotCache ?? UserDefaultsWalletSnapshotCache()
        self.accountDeletionConfiguredKidStore = accountDeletionConfiguredKidStore ?? UserDefaultsConfiguredKidStore()
        self.accountDeletionFlush = accountDeletionFlush
        self.localReplicaProvider = localReplicaProvider ?? { try LocalWalletRepository() }
        self.snapshot = resolvedRepository.childSnapshot()
        let configured = resolvedRepository.hasConfiguredKid
        self.isSignedIn = initiallySignedIn ?? configured
        if let recovery = resolvedRepository as? any WalletRecoveryProviding, let recoveryState = recovery.recoveryState {
            self.authorityState = .localRecovery(recoveryState)
        } else if let cloud = resolvedRepository as? CloudWalletRepository {
            self.authorityState = .cloud(lineageID: cloud.lineageID, revision: cloud.revision)
        } else if let local = resolvedRepository as? LocalWalletRepository,
                  let cloudLineageID = local.cloudAuthorityLineageID,
                  let revision = local.cloudRevision {
            self.authorityState = .cloud(lineageID: cloudLineageID, revision: revision)
        } else if let local = resolvedRepository as? LocalWalletRepository, let lineageID = local.lineageID {
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
            // Local setup starts with native Apple identity. First-run routing
            // may exchange its transient proof for account-bound discovery.
            self.appleSignInProvider = AppleSignInCoordinator()
        }

        cloudCoordinator?.onTransactionUpdate = { [weak self] in
            await self?.adoptCoordinatorState()
        }

        if self.isSignedIn, !isMockRepository, self.recoveryState == nil {
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
        // The first-run existing-wallet choice sits between sign-in and setup:
        // no authority has changed yet, so it cannot be an authority state.
        if existingWalletRecovery != nil { return .existingWallet }
        switch authorityState {
        case .unconfigured, .authenticatingParent: return .welcome
        case .localSetup: return .setup
        case .localRecovery: return .recovery
        default: return .kidHome
        }
    }
    public var recoveryState: WalletRecoveryState? {
        if case let .localRecovery(state) = authorityState { return state }
        return nil
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
        hasDeletedAccount = false
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
                await routeFirstRun(identity: outcome.identity)
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

    // MARK: - First-run existing-wallet discovery

    /// Decides, once per first-run sign-in, between recovering the wallet this
    /// parent's account already holds and ordinary local-first setup. Every
    /// path here is a read: nothing transitions before an explicit acceptance,
    /// and any failure still lands on the free local wallet.
    private func routeFirstRun(identity: AppleIdentity?) async {
        let generation = firstRunDecisionGeneration
        guard let cloudCoordinator,
              let local = repository as? LocalWalletRepository,
              let identity else {
            if generation == firstRunDecisionGeneration { beginLocalSetup() }
            return
        }
        do {
            try await cloudCoordinator.authenticateCloud(identity: identity)
        } catch {
            if generation == firstRunDecisionGeneration { beginLocalSetup(notice: .checkUnavailable) }
            return
        }
        // A deleted parent can sign in again with an Apple subscription that
        // still renews. Reconcile its existing StoreKit entitlement before
        // asking whether the fresh account owns a household, so the backend
        // can re-bind the signed transaction instead of offering a re-purchase.
        await cloudCoordinator.reconcileExistingEntitlementsForFreshSignIn()
        guard generation == firstRunDecisionGeneration, !repository.hasConfiguredKid else { return }
        await applyExistingWalletDiscovery(coordinator: cloudCoordinator, local: local, generation: generation)
    }

    /// Re-runs the account check: the retry affordance on the setup screen, and
    /// the re-confirmation a stale-revision refusal needs before the parent may
    /// accept the wallet again.
    public func checkForExistingWallet() async {
        guard isSignedIn, !isSigningIn, !repository.hasConfiguredKid, existingWalletRecovery?.isWorking != true else { return }
        guard let cloudCoordinator, let local = repository as? LocalWalletRepository else { return }
        let generation = firstRunDecisionGeneration
        isSigningIn = true
        defer { isSigningIn = false }
        guard await ensureCloudSession() else {
            if generation == firstRunDecisionGeneration { beginLocalSetup(notice: .checkUnavailable) }
            return
        }
        guard generation == firstRunDecisionGeneration, !repository.hasConfiguredKid else { return }
        await applyExistingWalletDiscovery(coordinator: cloudCoordinator, local: local, generation: generation)
    }

    private func applyExistingWalletDiscovery(
        coordinator: CloudCoordinator,
        local: LocalWalletRepository,
        generation: Int
    ) async {
        let discovery: CloudExistingWalletDiscovery
        do {
            discovery = try await coordinator.discoverExistingWallet()
        } catch {
            if generation == firstRunDecisionGeneration { beginLocalSetup(notice: .checkUnavailable) }
            return
        }
        guard generation == firstRunDecisionGeneration, !repository.hasConfiguredKid else { return }
        switch discovery {
        case .noHousehold, .detachedHousehold, .unusable:
            // No server wallet, a wallet deliberately detached to another
            // device, or an answer this client cannot read: all keep the
            // ordinary local-first path and offer no server recovery.
            beginLocalSetup()
        case .cloudHousehold:
            isCommittingFirstRunCloudAdoption = true
            defer { isCommittingFirstRunCloudAdoption = false }
            await adoptDiscoveredCloudHousehold(coordinator: coordinator, local: local, generation: generation)
        case .legacyHousehold:
            guard let offer = discovery.offer else {
                beginLocalSetup()
                return
            }
            guard offer.entitlementActive else {
                beginLocalSetup(notice: .foundButCloudInactive)
                return
            }
            existingWalletNotice = nil
            needsSetup = false
            authorityState = .unconfigured
            existingWalletRecovery = .offered(offer)
        }
    }

    /// An already-Cloud household needs no transition and no consent to move
    /// anything: this device simply joins the wallet the service already owns.
    private func adoptDiscoveredCloudHousehold(
        coordinator: CloudCoordinator,
        local: LocalWalletRepository,
        generation: Int
    ) async {
        do {
            guard let cloud = try await coordinator.adoptExistingCloudHousehold(into: local) else {
                if generation == firstRunDecisionGeneration { beginLocalSetup(notice: .checkUnavailable) }
                return
            }
            guard generation == firstRunDecisionGeneration else { return }
            enterRecoveredWallet(cloud)
        } catch {
            if generation == firstRunDecisionGeneration { beginLocalSetup(notice: .checkUnavailable) }
        }
    }

    /// The parent explicitly accepted the offered wallet. This is the only call
    /// site of the transition, it sends exactly one request per attempt, and it
    /// reuses this acceptance's idempotency key for every retry of it.
    public func acceptExistingWallet() async {
        guard let state = existingWalletRecovery, !state.isWorking else { return }
        guard let cloudCoordinator, let local = repository as? LocalWalletRepository else { return }
        let offer = state.offer
        let idempotencyKey = acceptedRecoveryKey ?? UUID().uuidString
        acceptedRecoveryKey = idempotencyKey
        existingWalletRecovery = .recovering(offer)
        do {
            let cloud = try await cloudCoordinator.recoverLegacyHousehold(
                offer,
                idempotencyKey: idempotencyKey,
                into: local
            )
            acceptedRecoveryKey = nil
            enterRecoveredWallet(cloud)
        } catch let refusal as CloudLegacyActivationError {
            applyRecoveryRefusal(refusal.refusal, to: offer)
        } catch {
            applyRecoveryRefusal(.unreachable, to: offer)
        }
    }

    /// Retries the one accepted recovery. A blocker that may clear replays the
    /// exact same protected action; a stale or unusable acceptance goes back
    /// through discovery so the parent chooses again with a fresh key.
    public func retryExistingWalletRecovery() async {
        guard let state = existingWalletRecovery, state.canRetry,
              case .refused(_, let refusal) = state else { return }
        if refusal.requiresFreshDiscovery {
            await checkForExistingWallet()
        } else {
            await acceptExistingWallet()
        }
    }

    /// The parent chose the free local wallet instead. Nothing is sent: the
    /// server-held wallet stays exactly as it is.
    public func declineExistingWallet() {
        guard existingWalletRecovery?.isWorking != true else { return }
        acceptedRecoveryKey = nil
        beginLocalSetup()
    }

    private func applyRecoveryRefusal(_ refusal: CloudLegacyActivationRefusal, to offer: CloudExistingWalletOffer) {
        if refusal.requiresFreshDiscovery {
            // A new acceptance must never reuse this key.
            acceptedRecoveryKey = nil
        }
        // The service has just answered about the entitlement, so the offer
        // stops claiming an active subscription it does not have.
        let current = refusal == .entitlementRequired
            ? CloudExistingWalletOffer(lineageID: offer.lineageID, revision: offer.revision, entitlementActive: false)
            : offer
        existingWalletRecovery = .refused(current, refusal)
    }

    private func beginLocalSetup(notice: ExistingWalletNotice? = nil) {
        acceptedRecoveryKey = nil
        existingWalletRecovery = nil
        existingWalletNotice = notice
        authorityState = .localSetup
        needsSetup = true
    }

    /// Enters the recovered wallet directly. There is no re-setup: the child,
    /// ledger, loans, repayments, and allowance come from the Cloud replica the
    /// bootstrap just mirrored. The parent PIN is chosen at the Parent door.
    private func enterRecoveredWallet(_ cloud: CloudWalletRepository) {
        repository = cloud
        acceptedRecoveryKey = nil
        existingWalletRecovery = nil
        existingWalletNotice = nil
        needsSetup = false
        isSignedIn = true
        connection = .reached
        sessionExpired = false
        errorMessage = nil
        authorityState = .cloud(lineageID: cloud.lineageID, revision: cloud.revision)
        snapshot = cloud.childSnapshot()
        if let cloudCoordinator {
            cloudEntitlement = cloudCoordinator.entitlement
            cloudMessage = cloudCoordinator.message
        }
    }

    /// A device still reading the legacy service switches to Cloud as soon as
    /// its own wallet snapshot reports that Cloud took over the household. It
    /// converges through the same context and bootstrap path a second device
    /// uses - no dual write, no second state owner - and never while a legacy
    /// write of its own is still unresolved.
    private func convergeLegacyDeviceOntoCloud(generation: Int) async {
        guard let cloudCoordinator,
              let legacy = repository as? APIWalletRepository,
              legacy.reportsCloudAuthority,
              !legacy.hasUnsettledParentActions,
              let local = try? localReplicaProvider() else { return }
        let adopted: CloudWalletRepository?
        do {
            adopted = try await cloudCoordinator.adoptExistingCloudHousehold(into: local)
        } catch {
            return
        }
        guard let cloud = adopted, generation == refreshGeneration, repository === legacy else { return }
        // A legacy write the service just refused is still news for the parent,
        // so it is carried across the switch instead of disappearing with the
        // repository that reported it. Nothing was recorded by either side.
        let refusedLegacyActions = snapshot.pendingEvents.filter { $0.syncState == .rejected }
        repository = cloud
        authorityState = .cloud(lineageID: cloud.lineageID, revision: cloud.revision)
        var converged = viewRole == .child ? cloud.childSnapshot() : cloud.snapshot()
        converged.pendingEvents += refusedLegacyActions
        snapshot = converged
        connection = .reached
        needsCloudReview = false
        cloudEntitlement = cloudCoordinator.entitlement
        cloudMessage = cloudCoordinator.message
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
        guard elevation == .active, !isDeletingAccount, !hasDeletedAccount else { return }
        deElevate()
    }

    /// Called when the scene leaves the foreground. Any parent elevation and
    /// in-progress parent flow drops immediately; kid data may stay visible.
    public func handleAppBackgrounded() {
        didLeaveForeground = true
        if elevation == .none {
            refreshGeneration += 1
            isLoading = false
            return
        }
        deElevate()
    }

    /// Called when the scene comes back to the foreground. Backgrounding
    /// retires every read that was in flight, so without this the kid home
    /// would keep showing - and keep labelling as offline - whatever the last
    /// retired attempt left behind until somebody pulled to refresh.
    public func handleAppForegrounded() {
        guard didLeaveForeground else { return }
        didLeaveForeground = false
        guard isSignedIn, !needsSetup, recoveryState == nil, existingWalletRecovery == nil else { return }
        Task { [weak self] in await self?.refresh() }
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
        refreshAttempts += 1
        let attempt = refreshAttempts
        isLoading = true
        defer {
            // Only the newest attempt owns the spinner: an older read finishing
            // underneath it must not report the wallet as settled.
            if generation == refreshGeneration, attempt == refreshAttempts { isLoading = false }
        }
        do {
            let refreshed = try await repository.refresh(for: requestedRole)
            guard canPublish(attempt, generation: generation, role: requestedRole) else { return }
            snapshot = refreshed
            needsSetup = false
            if let cloud = repository as? CloudWalletRepository {
                authorityState = .cloud(lineageID: cloud.lineageID, revision: cloud.revision)
            } else if let local = repository as? LocalWalletRepository, let lineageID = local.lineageID {
                authorityState = .local(lineageID: lineageID)
            }
            errorMessage = nil
            connection = .reached
            sessionExpired = false
            await convergeLegacyDeviceOntoCloud(generation: generation)
        } catch let error as WalletAPIError {
            // The newest read's own failure is the one worth reporting, so the
            // readout is only updated by a read that may still publish. What it
            // shows then survives a later successful read: a parent reporting
            // an intermittent failure needs it after the wallet recovers.
            if canPublish(attempt, generation: generation, role: requestedRole) {
                publishOperationDiagnostic(for: error)
            }
            switch error {
            case .familyNotSetup:
                guard canPublish(attempt, generation: generation, role: requestedRole) else { return }
                needsSetup = true
                errorMessage = nil
            case .unauthorized, .noSession:
                guard canPublish(attempt, generation: generation, role: requestedRole) else { return }
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
                // A failure with no preserved transport shape proves only that
                // the authority was not reached, never that the device is
                // offline, so it is reported as exactly that much.
                guard canPublish(attempt, generation: generation, role: requestedRole) else { return }
                publishUnreachedAuthority(.serviceUnreachable, error: error, role: requestedRole)
            case let .transportFailure(diagnostic):
                guard canPublish(attempt, generation: generation, role: requestedRole) else { return }
                switch diagnostic.connection {
                case .deviceOffline:
                    publishUnreachedAuthority(.deviceOffline, error: error, role: requestedRole)
                case .serviceUnreachable, .reached:
                    // Nothing was thrown after a response arrived, so the most
                    // any such failure proves is an authority not reached.
                    publishUnreachedAuthority(.serviceUnreachable, error: error, role: requestedRole)
                case nil:
                    // A cancelled attempt observed no answer at all. It says
                    // nothing about this family's connection and must never
                    // reach them as an offline claim.
                    break
                }
            case .revisionConflict, .revisionRequired:
                guard canPublish(attempt, generation: generation, role: requestedRole) else { return }
                needsCloudReview = true
                errorMessage = userMessage(for: error)
                snapshot = requestedRole == .child ? repository.childSnapshot() : repository.snapshot()
            case .cloudAcceptedAwaitingReplica:
                guard canPublish(attempt, generation: generation, role: requestedRole) else { return }
                connection = .reached
                if let cloud = repository as? CloudWalletRepository {
                    authorityState = .cloud(lineageID: cloud.lineageID, revision: cloud.revision)
                }
                errorMessage = nil
                snapshot = requestedRole == .child ? repository.childSnapshot() : repository.snapshot()
            case .cloudMutationAwaitingReconciliation:
                guard canPublish(attempt, generation: generation, role: requestedRole) else { return }
                connection = .reached
                if let cloud = repository as? CloudWalletRepository {
                    authorityState = .cloud(lineageID: cloud.lineageID, revision: cloud.revision)
                }
                errorMessage = nil
                snapshot = requestedRole == .child ? repository.childSnapshot() : repository.snapshot()
            case .cancelled:
                // A Cloud read still in flight when the parent signed this
                // device out of Cloud, or kept it going locally, comes back
                // refused by the replica's hand-off lease. The hand-off has
                // already published the local wallet, and this retired Cloud
                // repository no longer has a snapshot to offer, so a
                // superseded read must change nothing: no error - the two
                // Apple sign-in paths drop `.cancelled` the same way - and
                // above all no emptied balance over the parent's wallet.
                break
            default:
                guard canPublish(attempt, generation: generation, role: requestedRole) else { return }
                errorMessage = userMessage(for: error)
                snapshot = requestedRole == .child ? repository.childSnapshot() : repository.snapshot()
            }
        } catch {
            guard canPublish(attempt, generation: generation, role: requestedRole) else { return }
            errorMessage = "The wallet could not be updated. Your last accepted balance is still shown."
            snapshot = requestedRole == .child ? repository.childSnapshot() : repository.snapshot()
        }
    }

    /// The failed attempt's own shape. A preserved transport failure carries
    /// it, so it is bound to exactly this attempt; a failing HTTP status is
    /// answered with its own typed error, so only the repository that made the
    /// request still holds the shape of it.
    private func publishOperationDiagnostic(for error: WalletAPIError? = nil) {
        let diagnostic: TransportDiagnostic?
        if case let .transportFailure(carried)? = error {
            diagnostic = carried
        } else {
            diagnostic = repository.latestTransportDiagnostic
        }
        guard let diagnostic, let observedConnection = diagnostic.connection else { return }
        latestTransportDiagnostic = diagnostic
        if observedConnection == .reached {
            connection = .reached
            if let cloud = repository as? CloudWalletRepository {
                authorityState = .cloud(lineageID: cloud.lineageID, revision: cloud.revision)
            }
        }
    }

    /// Publishes a read that could not reach its authority, saying only what
    /// the transport actually proved. The last accepted wallet stays on screen.
    private func publishUnreachedAuthority(
        _ connection: WalletConnection,
        error: WalletAPIError,
        role: UserRole
    ) {
        self.connection = connection
        if let cloud = repository as? CloudWalletRepository {
            authorityState = .cloudOffline(lineageID: cloud.lineageID, revision: cloud.revision)
        }
        errorMessage = userMessage(for: error)
        snapshot = role == .child ? repository.childSnapshot() : repository.snapshot()
    }

    /// Whether this read may still write what it saw into published state.
    /// A read is superseded when parent elevation moved underneath it, or when
    /// another read started later: the wallet on screen must always be the
    /// newest observation, never whichever request happened to finish last.
    private func canPublish(_ attempt: Int, generation: Int, role: UserRole) -> Bool {
        guard generation == refreshGeneration, role == viewRole else { return false }
        return attempt == refreshAttempts
    }

    public func setupParent(_ setup: ParentSetup, pin: String, confirmation: String) async -> Bool {
        guard pin.count == 4, pin.allSatisfy(\.isNumber), pin == confirmation else {
            errorMessage = "Choose and confirm a four-digit parent PIN."
            return false
        }
        guard !isCommittingFirstRunCloudAdoption else { return false }
        firstRunDecisionGeneration += 1
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
        latestParentMutationOutcome = nil
        do {
            let refreshed = try await repository.setAllowance(command)
            if generation == refreshGeneration, elevation == .active {
                snapshot = refreshed
                latestParentMutationOutcome = .recorded
                isLoading = false
            }
            return true
        } catch let error as WalletAPIError {
            if generation == refreshGeneration {
                publishOperationDiagnostic(for: error)
            }
            if error == .unauthorized || error == .noSession {
                sessionExpired = repository.hasConfiguredKid
                if elevation != .none { deElevate() }
            } else if generation == refreshGeneration, elevation == .active {
                switch error {
                case .cloudAcceptedAwaitingReplica:
                    latestParentMutationOutcome = .acceptedAwaitingReplica
                    snapshot = repository.snapshot()
                    errorMessage = nil
                case .cloudMutationAwaitingReconciliation:
                    latestParentMutationOutcome = .waitingForCloud
                    snapshot = repository.snapshot()
                    errorMessage = nil
                default:
                    latestParentMutationOutcome = .notRecorded
                    errorMessage = userMessage(for: error)
                }
                isLoading = false
            }
            return false
        } catch {
            if generation == refreshGeneration, elevation == .active {
                latestParentMutationOutcome = .notRecorded
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
        latestParentMutationOutcome = nil
        do {
            let refreshed = try await repository.updateChildProfile(ChildProfileUpdate(nickname: nickname))
            if generation == refreshGeneration, elevation == .active {
                snapshot = refreshed
                latestParentMutationOutcome = .recorded
                isLoading = false
            }
            return true
        } catch let error as WalletAPIError {
            if generation == refreshGeneration {
                publishOperationDiagnostic(for: error)
            }
            if error == .unauthorized || error == .noSession {
                sessionExpired = repository.hasConfiguredKid
                if elevation != .none { deElevate() }
            } else if generation == refreshGeneration, elevation == .active {
                switch error {
                case .cloudAcceptedAwaitingReplica:
                    latestParentMutationOutcome = .acceptedAwaitingReplica
                    snapshot = repository.snapshot()
                    errorMessage = nil
                case .cloudMutationAwaitingReconciliation:
                    latestParentMutationOutcome = .waitingForCloud
                    snapshot = repository.snapshot()
                    errorMessage = nil
                default:
                    latestParentMutationOutcome = .notRecorded
                    errorMessage = userMessage(for: error)
                }
                isLoading = false
            }
            return false
        } catch {
            if generation == refreshGeneration, elevation == .active {
                latestParentMutationOutcome = .notRecorded
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
        if repository is CloudWalletRepository, !connection.reachedAuthority || needsCloudReview {
            return .rejected(WalletEvent(
                type: activityType(for: command.kind),
                amountCents: max(command.amountCents, 0),
                reason: command.reason,
                syncState: .rejected,
                explanation: "This new action was not sent.",
                rejectionReason: !connection.reachedAuthority
                    ? "Reconnect and refresh the Cloud wallet before recording a new action."
                    : "Review the latest Cloud balance before recording a new action."
            ))
        }
        let generation = refreshGeneration
        do {
            let result = try await repository.submit(command)
            if generation == refreshGeneration, elevation == .active {
                publishOperationDiagnostic()
                snapshot = repository.snapshot()
                errorMessage = nil
            }
            return result
        } catch let error as WalletAPIError {
            if generation == refreshGeneration {
                publishOperationDiagnostic(for: error)
            }
            if error == .unauthorized || error == .noSession {
                sessionExpired = repository.hasConfiguredKid
                if elevation != .none { deElevate() }
            }
            if case .revisionConflict = error,
               generation == refreshGeneration,
               elevation == .active {
                // Another device moved first: nothing was recorded here, and the
                // parent reviews the refreshed balance before retrying.
                needsCloudReview = true
                Task { [weak self] in await self?.refresh() }
            }
            if case .revisionRequired = error,
               generation == refreshGeneration,
               elevation == .active {
                needsCloudReview = true
                Task { [weak self] in await self?.refresh() }
            }
            if case .cloudEntitlementRequired = error,
               generation == refreshGeneration,
               elevation == .active {
                cloudEntitlement = cloudCoordinator?.entitlement ?? .expired
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
        let isPreFamilySetup = isSignedIn && needsSetup
        guard elevation == .active || isPreFamilySetup else { return }
        refreshGeneration += 1
        firstRunDecisionGeneration += 1
        var cleanupUnconfirmed = false
        do {
            try eraseLocalWalletSurfaces()
        } catch SharedLocalEraseError.finalErase {
            errorMessage = "Sign out could not finish. The wallet is still available on this device."
            return
        } catch {
            cleanupUnconfirmed = true
        }
        invalidateCloudActivation()
        cloudCoordinator?.clearLocalSession()
        authorityState = .unconfigured
        purchaseAttempt = .idle
        cloudEntitlement = .none
        acceptedRecoveryKey = nil
        existingWalletRecovery = nil
        existingWalletNotice = nil
        isSignedIn = false
        needsSetup = false
        identityStore.clear()
        try? pinStore.clear()
        snapshot = .empty()
        errorMessage = cleanupUnconfirmed
            ? "Signed out. This \(DeviceCopy.deviceNoun)'s wallet is erased, but cleanup could not be fully confirmed."
            : nil
        sessionExpired = false
        connection = .reached
        latestTransportDiagnostic = nil
        showsFirstActionsHandoff = false
        clearPINFailureState()
        deElevate()
    }

    // MARK: - Account deletion

    /// A failed Core Data erase refuses before DELETE and leaves the
    /// authoritative wallet available. Incomplete begins after local erase.
    public func deleteAccount(
        idempotencyKey: String,
        acknowledgedBillingRisk: Bool = false
    ) async -> AccountDeletionAttemptOutcome {
        guard elevation == .active, !isDeletingAccount, !hasDeletedAccount else {
            return .refused("Only the Parent area can delete your account.")
        }
        guard UUID(uuidString: idempotencyKey) != nil,
              let accountDeletionService,
              let owner = identityStore.appleUserID, !owner.isEmpty else {
            return .refused("Sign in with Apple again before deleting this account.")
        }
        isDeletingAccount = true
        serverConfirmedAccountDeletionID = nil
        accountDeletionPresentation = .deleting(idempotencyKey: idempotencyKey)
        errorMessage = nil
        defer { isDeletingAccount = false }
        if cloudCoordinator != nil {
            guard await ensureCloudSession() else {
                accountDeletionPresentation = nil
                return .refused("Deleting your account needs an internet connection. Nothing was deleted.")
            }
        }
        do {
            try await accountDeletionService.preflightAccountDeletion()
        } catch {
            accountDeletionPresentation = nil
            return .refused("Deleting your account needs an internet connection. Nothing was deleted.")
        }
        if let cloudCoordinator {
            accountDeletionEntitlement = cloudCoordinator.entitlement
            guard !cloudCoordinator.entitlement.requiresAccountDeletionBillingAcknowledgement || acknowledgedBillingRisk else {
                accountDeletionPresentation = nil
                return .refused("Review and acknowledge the updated Apple subscription warning before deleting your account.")
            }
        }
        do {
            try eraseLocalWalletSurfaces()
        } catch SharedLocalEraseError.finalErase(_) {
            accountDeletionPresentation = nil
            return .refused("This \(DeviceCopy.deviceNoun)'s wallet could not be erased, so the account was not deleted.")
        } catch SharedLocalEraseError.unconfirmedFlush {
            publishLocalAccountDeletion()
            accountDeletionPresentation = .incomplete(idempotencyKey: idempotencyKey)
            return .incomplete("This \(DeviceCopy.deviceNoun)'s copy of the wallet is removed. We could not confirm your account was removed from the service.")
        } catch {
            accountDeletionPresentation = nil
            return .refused("The wallet remains on this \(DeviceCopy.deviceNoun), so the account was not deleted.")
        }
        publishLocalAccountDeletion()
        do {
            _ = try await accountDeletionService.deleteAccount(idempotencyKey: idempotencyKey)
        } catch {
            accountDeletionPresentation = .incomplete(idempotencyKey: idempotencyKey)
            return .incomplete("This \(DeviceCopy.deviceNoun)'s copy of the wallet is removed. We could not confirm your account was removed from the service.")
        }
        serverConfirmedAccountDeletionID = idempotencyKey
        do {
            try clearAccountDeletionCredentials()
        } catch {
            cloudCoordinator?.resetAfterAccountDeletion()
            accountDeletionPresentation = .incomplete(idempotencyKey: idempotencyKey)
            return .incomplete("The account was removed from the service, but this \(DeviceCopy.deviceNoun) could not confirm credential cleanup.")
        }
        cloudCoordinator?.resetAfterAccountDeletion()
        serverConfirmedAccountDeletionID = nil
        hasDeletedAccount = true
        accountDeletionPresentation = .deleted
        return .deleted
    }

    /// Completes the terminal success screen's explicit handoff to the normal
    /// signed-out Welcome route. It is deliberately separate from the server
    /// success so the parent can still read the Apple billing reminder.
    public func finishAccountDeletion() {
        guard hasDeletedAccount else { return }
        hasDeletedAccount = false
        serverConfirmedAccountDeletionID = nil
        accountDeletionPresentation = nil
        deElevate()
    }

    public func finishAccountDeletionLater() {
        guard case .incomplete = accountDeletionPresentation, !isDeletingAccount else { return }
        serverConfirmedAccountDeletionID = nil
        accountDeletionPresentation = nil
        if elevation != .none {
            deElevate()
        }
    }

    /// Phase 1 has one abort boundary: the transactional repository erase.
    /// A refusal means that commit threw before changing any device surface.
    /// After it succeeds, later failures are incomplete by definition.
    private func eraseLocalWalletSurfaces() throws {
        do {
            try performFinalWalletErase()
        } catch {
            throw SharedLocalEraseError.finalErase(error)
        }
        accountDeletionPendingStore.clear()
        accountDeletionSnapshotCache.clear()
        accountDeletionConfiguredKidStore.clear()
        guard accountDeletionFlush() else { throw SharedLocalEraseError.unconfirmedFlush }
    }

    private func performFinalWalletErase() throws {
        if let cloud = repository as? CloudWalletRepository {
            try cloud.retireReplicaForAccountDeletion()
        } else if let retiringRepository = repository as? any AccountDeletionLocalRetiring {
            try retiringRepository.retireLocalWalletForAccountDeletion()
        } else {
            throw WalletAPIError.invalidResponse("This device could not erase its wallet safely.")
        }
    }

    private enum SharedLocalEraseError: Error {
        case finalErase(Error)
        case unconfirmedFlush
    }

    private func clearAccountDeletionCredentials() throws {
        try repository.clearAuthenticationForAccountDeletion()
        try cloudCoordinator?.clearAuthenticationForAccountDeletion()
        try identityStore.clearForAccountDeletion()
        try pinStore.clear()
    }

    private func publishLocalAccountDeletion() {
        refreshGeneration += 1
        firstRunDecisionGeneration += 1
        invalidateCloudActivation()
        authorityState = .unconfigured
        purchaseAttempt = .idle
        cloudEntitlement = .none
        cloudPlans = []
        cloudMessage = nil
        acceptedRecoveryKey = nil
        existingWalletRecovery = nil
        existingWalletNotice = nil
        isSignedIn = false
        needsSetup = false
        snapshot = .empty()
        errorMessage = nil
        sessionExpired = false
        connection = .reached
        latestTransportDiagnostic = nil
        needsCloudReview = false
        latestParentMutationOutcome = nil
        showsFirstActionsHandoff = false
        clearPINFailureState()
        hasDeletedAccount = false
    }

    public func retryAccountDeletion(idempotencyKey: String) async -> AccountDeletionAttemptOutcome {
        guard !isDeletingAccount, UUID(uuidString: idempotencyKey) != nil else {
            return .refused("Account deletion is unavailable in this build.")
        }
        isDeletingAccount = true
        accountDeletionPresentation = .deleting(idempotencyKey: idempotencyKey)
        defer { isDeletingAccount = false }
        if serverConfirmedAccountDeletionID == idempotencyKey {
            do {
                try clearAccountDeletionCredentials()
            } catch {
                cloudCoordinator?.resetAfterAccountDeletion()
                accountDeletionPresentation = .incomplete(idempotencyKey: idempotencyKey)
                return .incomplete("The account was removed from the service, but this \(DeviceCopy.deviceNoun) could not confirm credential cleanup.")
            }
            cloudCoordinator?.resetAfterAccountDeletion()
            serverConfirmedAccountDeletionID = nil
            hasDeletedAccount = true
            accountDeletionPresentation = .deleted
            return .deleted
        }
        guard let accountDeletionService else {
            accountDeletionPresentation = .incomplete(idempotencyKey: idempotencyKey)
            return .refused("Account deletion is unavailable in this build.")
        }
        do {
            try eraseLocalWalletSurfaces()
        } catch SharedLocalEraseError.unconfirmedFlush {
            accountDeletionPresentation = .incomplete(idempotencyKey: idempotencyKey)
            return .incomplete("This \(DeviceCopy.deviceNoun)'s copy of the wallet is removed. We could not confirm your account was removed from the service.")
        } catch {
            accountDeletionPresentation = .incomplete(idempotencyKey: idempotencyKey)
            return .incomplete("This \(DeviceCopy.deviceNoun)'s copy of the wallet is removed. We could not confirm your account was removed from the service.")
        }
        if cloudCoordinator != nil {
            guard await ensureCloudSession() else {
                accountDeletionPresentation = .incomplete(idempotencyKey: idempotencyKey)
                return .incomplete("This \(DeviceCopy.deviceNoun)'s copy of the wallet is removed. We could not confirm your account was removed from the service.")
            }
        }
        do {
            _ = try await accountDeletionService.deleteAccount(idempotencyKey: idempotencyKey)
        } catch {
            accountDeletionPresentation = .incomplete(idempotencyKey: idempotencyKey)
            return .incomplete("This \(DeviceCopy.deviceNoun)'s copy of the wallet is removed. We could not confirm your account was removed from the service.")
        }
        serverConfirmedAccountDeletionID = idempotencyKey
        do {
            try clearAccountDeletionCredentials()
        } catch {
            cloudCoordinator?.resetAfterAccountDeletion()
            accountDeletionPresentation = .incomplete(idempotencyKey: idempotencyKey)
            return .incomplete("The account was removed from the service, but this \(DeviceCopy.deviceNoun) could not confirm credential cleanup.")
        }
        cloudCoordinator?.resetAfterAccountDeletion()
        serverConfirmedAccountDeletionID = nil
        hasDeletedAccount = true
        accountDeletionPresentation = .deleted
        return .deleted
    }

    public func refreshAccountDeletionContext() async {
        guard elevation == .active, let cloudCoordinator else {
            accountDeletionEntitlement = cloudCoordinator == nil ? cloudEntitlement : nil
            return
        }
        guard await ensureCloudSession(), await cloudCoordinator.refreshContext() != nil else {
            accountDeletionEntitlement = nil
            return
        }
        cloudEntitlement = cloudCoordinator.entitlement
        accountDeletionEntitlement = cloudCoordinator.entitlement
    }

    // MARK: - Cloud (optional, guarded)

    /// Whether a parent surface may show Cloud purchase/restore controls at all.
    public var canOfferCloudPlans: Bool { !cloudPlans.isEmpty }
    public var needsCloudSignIn: Bool { cloudCoordinator?.hasSession == false }
    /// The StoreKit coordinator backing the local Cloud recovery evidence
    /// readout. Nil where Cloud was never composed (scripted UI-test states).
    public var cloudSubscriptionStore: CloudSubscriptionStore? { cloudCoordinator?.subscriptionStore }
    public var canModifyWallet: Bool { repository.supportsRuntimeMutations }
    public var hasUnsettledCloudMutation: Bool {
        (repository as? any CloudMutationStatusProviding)?.hasUnsettledMutation == true
    }
    public var unsettledCloudMutationWasAccepted: Bool {
        (repository as? any CloudMutationStatusProviding)?.unsettledMutationPhase == .acceptedAwaitingReplica
    }
    public var hasRejectedCloudMutationCleanup: Bool {
        (repository as? any CloudMutationStatusProviding)?.unsettledMutationPhase == .rejected
    }
    public var unsettledCloudMutationMessage: String? {
        (repository as? any CloudMutationStatusProviding)?.unsettledMutationMessage
    }
    /// Free local authority is always usable. Cloud starts a new mutation only
    /// from a connected, reviewed replica with no unresolved request.
    public var canStartParentMutation: Bool {
        guard canModifyWallet else { return false }
        guard authorityState.isCloudAuthority else { return true }
        let hasCurrentRevision = (repository as? CloudWalletRepository)?.isReadyForRuntimeMutations ?? true
        return hasValidCloudReplica
            && hasCurrentRevision
            && !hasUnsettledCloudMutation
            && connection.reachedAuthority
            && !needsCloudReview
            && !cloudEntitlement.permitsLocalContinuation
    }
    public var hasValidCloudReplica: Bool {
        #if DEBUG
        if let debugHasValidCloudReplica { return debugHasValidCloudReplica }
        #endif
        return (repository as? CloudWalletRepository)?.hasValidReplica == true
    }
    public var canShowWalletData: Bool {
        !authorityState.isCloudAuthority || hasValidCloudReplica
    }
    public var canContinueLocallyAfterCloud: Bool {
        repository is CloudWalletRepository && cloudEntitlement.permitsLocalContinuation
    }
    public var cloudSignOutMode: CloudSignOutMode {
        if repository is CloudWalletRepository { return .cloudDevice }
        return repository is LocalWalletRepository ? .localErase : .serviceDevice
    }
    /// Only a Cloud device can sign out without erasing local data.
    public var canSignOutOfCloudOnThisDevice: Bool { repository is CloudWalletRepository }

    /// Reads backend capability and StoreKit products together. Plans stay empty
    /// unless both are ready, so the parent never sees an unusable price.
    public func loadCloudPlans() async {
        #if DEBUG
        if let debugCloudPlansOverride {
            cloudPlans = debugCloudPlansOverride
            return
        }
        #endif
        guard let cloudCoordinator else { cloudPlans = []; return }
        guard cloudCoordinator.hasSession else {
            cloudPlans = []
            purchaseAttempt = .idle
            return
        }
        await cloudCoordinator.refreshAvailability()
        cloudPlans = cloudCoordinator.canOfferPlans ? cloudCoordinator.plans.map(CloudPlan.init) : []
        purchaseAttempt = cloudCoordinator.purchaseAttempt
        cloudEntitlement = cloudCoordinator.entitlement
        cloudMessage = cloudCoordinator.message
    }

    public func signInToCloud() async {
        guard elevation == .active else { return }
        guard await ensureCloudSession() else {
            cloudPlans = []
            return
        }
        await loadCloudPlans()
    }

    public func purchaseCloud(planID: String) async {
        guard elevation == .active, let cloudCoordinator,
              let product = cloudCoordinator.plans.first(where: { $0.id == planID }) else { return }
        guard await ensureCloudSession() else { return }
        _ = await cloudCoordinator.purchase(product)
        await adoptCoordinatorState()
    }

    public func restoreCloudPurchases() async {
        guard elevation == .active, let cloudCoordinator else { return }
        guard await ensureCloudSession() else { return }
        await cloudCoordinator.restorePurchases()
        await adoptCoordinatorState()
    }

    /// Launch-time recovery for a replacement device: never prompts, never
    /// grants locally, and only mirrors what the backend already projects.
    public func recoverCloudEntitlements() async {
        guard let cloudCoordinator, cloudCoordinator.hasSession else { return }
        await cloudCoordinator.recoverEntitlements()
        await adoptCoordinatorState()
    }

    /// Cloud ended and the parent chose to keep using this device. The mirrored
    /// history stays and becomes local authority again.
    @discardableResult
    public func continueLocallyAfterCloud() async -> Bool {
        guard elevation == .active, let cloudCoordinator,
              let cloud = repository as? CloudWalletRepository else { return false }
        guard canContinueLocallyAfterCloud else { return false }
        guard await refreshCloudBeforeHandoff(cloud) else { return false }
        do {
            try cloudCoordinator.continueLocally(with: cloud.localReplica)
        } catch {
            errorMessage = userMessage(for: error)
            return false
        }
        repository = cloud.localReplica
        authorityState = cloud.localReplica.lineageID.map { .local(lineageID: $0) } ?? .localSetup
        snapshot = repository.snapshot()
        needsCloudReview = false
        cloudMessage = nil
        return true
    }

    /// Signs this device out of Cloud without deleting anything: the server
    /// session is revoked and the mirrored wallet keeps working locally.
    @discardableResult
    public func signOutOfCloudOnThisDevice() async -> Bool {
        guard elevation == .active, let cloudCoordinator, let cloud = repository as? CloudWalletRepository else { return false }
        guard await refreshCloudBeforeHandoff(cloud) else { return false }
        do {
            try cloud.localReplica.continueLocallyAfterCloud()
        } catch {
            errorMessage = userMessage(for: error)
            return false
        }
        await cloudCoordinator.signOutOfCloud()
        repository = cloud.localReplica
        authorityState = cloud.localReplica.lineageID.map { .local(lineageID: $0) } ?? .localSetup
        snapshot = repository.snapshot()
        cloudEntitlement = .none
        purchaseAttempt = .idle
        needsCloudReview = false
        cloudMessage = "This device signed out of Cloud. The wallet still works here and nothing was deleted."
        return true
    }

    private func refreshCloudBeforeHandoff(_ cloud: CloudWalletRepository) async -> Bool {
        do {
            snapshot = try await cloud.refresh(for: .parent)
            authorityState = .cloud(lineageID: cloud.lineageID, revision: cloud.revision)
            connection = .reached
            cloudMessage = nil
            return true
        } catch {
            cloudMessage = "This device needs to catch up with Cloud before it can keep or sign out of this wallet."
            return false
        }
    }

    public func acknowledgeCloudReview() {
        needsCloudReview = false
    }

    private func adoptCoordinatorState() async {
        guard let cloudCoordinator else { return }
        guard permitsCloudActivation else { return }
        purchaseAttempt = cloudCoordinator.purchaseAttempt
        cloudEntitlement = cloudCoordinator.entitlement
        cloudMessage = cloudCoordinator.message
        await activateCloudIfPaid()
    }

    private func ensureCloudSession() async -> Bool {
        guard let cloudCoordinator else { return false }
        if cloudCoordinator.hasSession { return true }
        guard let appleIdentityAuthorizer = appleSignInProvider as? any AppleIdentityAuthorizing else {
            cloudMessage = "Sign in with Apple is unavailable, so Cloud stays off."
            return false
        }
        do {
            let identity = try await appleIdentityAuthorizer.authorizeAppleIdentity(
                requiredAppleUserID: identityStore.appleUserID
            )
            try await cloudCoordinator.authenticateCloud(identity: identity)
            if identityStore.appleUserID == nil {
                try identityStore.save(appleUserID: identity.appleUserID)
            }
            cloudMessage = nil
            return true
        } catch {
            cloudMessage = userMessage(for: error)
            return false
        }
    }

    /// Moves this device to Cloud authority from verified backend state: either
    /// a projected entitlement for local activation or an existing Cloud
    /// household for adoption. Any failure leaves the free local wallet intact.
    private func activateCloudIfPaid() async {
        guard permitsCloudActivation else { return }
        guard let cloudCoordinator else { return }
        guard let local = repository as? LocalWalletRepository else { return }
        guard cloudCoordinator.isCloudActive || cloudCoordinator.household != nil else { return }
        if let cloudActivationTask {
            await cloudActivationTask.value
            return
        }
        let generation = cloudActivationGeneration
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performCloudActivation(
                using: local,
                coordinator: cloudCoordinator,
                generation: generation
            )
        }
        cloudActivationTask = task
        await task.value
        if generation == cloudActivationGeneration {
            cloudActivationTask = nil
        }
    }

    private func performCloudActivation(
        using local: LocalWalletRepository,
        coordinator cloudCoordinator: CloudCoordinator,
        generation: Int
    ) async {
        guard permitsCloudActivation(generation: generation) else { return }
        let previousAuthority = authorityState
        authorityState = .transitioningToCloud
        do {
            let cloud: CloudWalletRepository
            if let adopted = try await cloudCoordinator.adoptExistingCloudHousehold(into: local) {
                cloud = adopted
            } else {
                cloud = try await cloudCoordinator.activateCloud(from: local, familyName: cloudFamilyName)
            }
            guard permitsCloudActivation(generation: generation) else { return }
            repository = cloud
            authorityState = .cloud(lineageID: cloud.lineageID, revision: cloud.revision)
            snapshot = cloud.snapshot()
            if cloudCoordinator.isCloudActive {
                purchaseAttempt = .verifiedPaid
            }
            cloudMessage = cloudCoordinator.message
        } catch {
            guard permitsCloudActivation(generation: generation) else { return }
            authorityState = previousAuthority
            if cloudCoordinator.activationConflict {
                purchaseAttempt = .activationConflict
                cloudMessage = "This wallet could not be moved to Cloud. Nothing was changed on this device."
            } else {
                cloudMessage = "Cloud is on for your account. This wallet is still on this device and will try again."
            }
        }
    }

    private var permitsCloudActivation: Bool {
        guard !isDeletingAccount, accountDeletionPresentation == nil else { return false }
        if case .unconfigured = authorityState { return false }
        return true
    }

    private func permitsCloudActivation(generation: Int) -> Bool {
        generation == cloudActivationGeneration && !Task.isCancelled && permitsCloudActivation
    }

    private func invalidateCloudActivation() {
        cloudActivationGeneration += 1
        cloudActivationTask?.cancel()
        cloudActivationTask = nil
    }

    private var cloudFamilyName: String {
        guard let nickname = snapshot.configuredChildNickname else { return "Family wallet" }
        return "\(nickname)'s family"
    }

    #if DEBUG
    /// Debug-only scenario seam. This is intentionally compiled out of
    /// Release, and is the sole place scripted authority/entitlement states
    /// may enter the app.
    func applyDebugCloudState(
        authority: WalletAuthorityState,
        purchase: PurchaseAttemptState = .idle,
        entitlement: CloudEntitlementState = .none,
        hasValidReplica: Bool? = nil
    ) {
        authorityState = authority
        purchaseAttempt = purchase
        cloudEntitlement = entitlement
        debugHasValidCloudReplica = hasValidReplica
    }

    /// Debug-only seam for reviewing the populated Cloud plans surface
    /// without a live StoreKit/backend round trip, so its legal links and
    /// auto-renew disclosure stay UI-testable. The override sticks so the
    /// view's own `.task { await store.loadCloudPlans() }` does not wipe it
    /// out on appear.
    func applyDebugCloudPlans(_ plans: [CloudPlan]) {
        debugCloudPlansOverride = plans
        cloudPlans = plans
    }

    /// Debug-only seam for reviewing the first-run existing-wallet screen
    /// without a service. It only sets presentation state; no discovery,
    /// transition, or authority change happens here.
    func applyDebugExistingWalletRecovery(_ state: ExistingWalletRecoveryState?) {
        existingWalletRecovery = state
    }

    func applyDebugExistingWalletNotice(_ notice: ExistingWalletNotice?) {
        existingWalletNotice = notice
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
        snapshot = authorityState == .unconfigured ? .empty() : repository.childSnapshot()
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
