#if DEBUG
import Foundation

/// Launch-environment scenario seam for native UI tests and local simulator
/// review of signed-in states, which otherwise require live Apple Sign In and
/// the production service. Compiled only into Debug builds; Release binaries
/// contain none of this. Every scenario uses the repository's synthetic
/// fixture data and in-memory stores - never real accounts or families.
@MainActor
enum DebugLaunchScenario {
    static let owningParentAppleUserID = "uitest-owning-parent"

    /// Opt-in entry points to the internal diagnostics surfaces (StoreKit
    /// resolution, Cloud recovery evidence). Absent - the default, and the only
    /// possibility in Release - the app offers no path into them at all, so a
    /// Debug run reproduces exactly what a person on TestFlight can reach.
    static func showsDiagnosticsEntryPoints(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        environment["EW_UITEST_DIAGNOSTICS"] == "1"
    }

    static func makeStore(environment: [String: String] = ProcessInfo.processInfo.environment) -> WalletStore? {
        guard let scenario = environment["EW_UITEST_SCENARIO"] else { return nil }

        let gatePolicy: ParentGatePolicy = environment["EW_UITEST_FAST_COOLDOWN"] == "1"
            ? ParentGatePolicy(maxAttempts: 5, cooldownSeconds: 3)
            : .standard
        let signInUserID = environment["EW_UITEST_APPLE_USER"] ?? owningParentAppleUserID

        func store(
            repository: any WalletRepository,
            signedIn: Bool = true,
            pin: String? = "1234",
            knownOwner: Bool = true,
            provider: ScriptedAppleSignInProvider? = nil,
            authority: WalletAuthorityState? = nil,
            purchase: PurchaseAttemptState = .idle,
            entitlement: CloudEntitlementState = .none,
            hasValidCloudReplica: Bool? = nil,
            accountDeletionService: (any AccountDeletionPerforming)? = nil
        ) -> WalletStore {
            let result = WalletStore(
                repository: repository,
                appleSignInProvider: provider ?? ScriptedAppleSignInProvider(appleUserID: signInUserID),
                initiallySignedIn: signedIn,
                pinStore: InMemoryParentPINStore(pin: pin),
                identityStore: InMemoryParentIdentityStore(appleUserID: knownOwner ? owningParentAppleUserID : nil),
                gatePolicy: gatePolicy,
                accountDeletionService: accountDeletionService
            )
            if let authority {
                result.applyDebugCloudState(
                    authority: authority,
                    purchase: purchase,
                    entitlement: entitlement,
                    hasValidReplica: hasValidCloudReplica
                )
            }
            return result
        }

        switch scenario {
        case "configured":
            return store(repository: MockWalletRepository(snapshot: snapshot(.fixture(), environment: environment)))
        case "configured-empty":
            return store(repository: MockWalletRepository(snapshot: emptySnapshot(environment: environment)))
        case "delete-account":
            return store(
                repository: MockWalletRepository(snapshot: snapshot(.fixture(), environment: environment)),
                accountDeletionService: ScriptedAccountDeletionService()
            )
        case "delete-account-subscribed":
            return store(
                repository: MockWalletRepository(snapshot: snapshot(.fixture(), environment: environment)),
                authority: .cloud(lineageID: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!, revision: 7),
                entitlement: .active(accessUntil: .distantFuture, autoRenewEnabled: true),
                hasValidCloudReplica: true,
                accountDeletionService: ScriptedAccountDeletionService()
            )
        case "offline":
            let repository = ScriptedWalletRepository(
                snapshot: snapshot(legacyCachedSnapshot(), environment: environment),
                refreshError: .network("The network is unavailable. The accepted balance was not changed.")
            )
            return store(repository: repository)
        case "expired":
            let repository = ScriptedWalletRepository(
                snapshot: snapshot(legacyCachedSnapshot(), environment: environment),
                refreshError: .unauthorized
            )
            let provider = ScriptedAppleSignInProvider(appleUserID: signInUserID) {
                // A successful owning-parent re-authentication renews the
                // scripted session, so later refreshes succeed again.
                repository.refreshError = nil
            }
            return store(repository: repository, provider: provider)
        case "no-pin":
            return store(
                repository: MockWalletRepository(snapshot: snapshot(.fixture(), environment: environment)),
                pin: nil
            )
        case "unverifiable":
            return store(
                repository: MockWalletRepository(snapshot: snapshot(.fixture(), environment: environment)),
                pin: nil,
                knownOwner: false
            )
        case "first-run":
            guard let repository = try? LocalWalletRepository(inMemory: true) else { return nil }
            return store(repository: repository, signedIn: false, pin: nil, knownOwner: false)
        case "first-run-existing-wallet",
             "first-run-existing-wallet-refused",
             "first-run-check-unavailable",
             "first-run-cloud-inactive":
            guard let repository = try? LocalWalletRepository(inMemory: true) else { return nil }
            let result = store(
                repository: repository,
                signedIn: true,
                pin: nil,
                knownOwner: true,
                authority: .localSetup
            )
            let offer = CloudExistingWalletOffer(
                lineageID: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!,
                revision: 0,
                entitlementActive: true
            )
            switch scenario {
            case "first-run-existing-wallet":
                result.applyDebugExistingWalletRecovery(.offered(offer))
            case "first-run-existing-wallet-refused":
                result.applyDebugExistingWalletRecovery(.refused(offer, .serviceReadOnly))
            case "first-run-check-unavailable":
                result.applyDebugExistingWalletNotice(.checkUnavailable)
            default:
                result.applyDebugExistingWalletNotice(.foundButCloudInactive)
            }
            return result
        case "cloud-pending":
            return store(repository: MockWalletRepository(snapshot: snapshot(.fixture(), environment: environment)), authority: .cloud(lineageID: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!, revision: 7), purchase: .pending, entitlement: .verificationPending)
        case "cloud-expired":
            return store(repository: MockWalletRepository(snapshot: snapshot(.fixture(), environment: environment)), authority: .local(lineageID: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!), entitlement: .expired)
        case "cloud-purchase-store-error":
            return store(repository: MockWalletRepository(snapshot: snapshot(.fixture(), environment: environment)), authority: .local(lineageID: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!), purchase: .storeClientError)
        case "cloud-purchase-server-rejected":
            return store(repository: MockWalletRepository(snapshot: snapshot(.fixture(), environment: environment)), authority: .local(lineageID: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!), purchase: .serverRejected(correlationID: nil))
        case "cloud-offline-grace":
            return store(repository: MockWalletRepository(snapshot: snapshot(.fixture(), environment: environment)), authority: .cloudOfflineGrace(lineageID: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!, revision: 7), entitlement: .active(accessUntil: .distantPast, autoRenewEnabled: true))
        case "device-conflict":
            return store(repository: MockWalletRepository(snapshot: snapshot(.fixture(), environment: environment)), authority: .cloud(lineageID: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!, revision: 8), purchase: .activationConflict, entitlement: .active(accessUntil: .distantFuture, autoRenewEnabled: true))
        case "cloud-write-recorded":
            return store(
                repository: ScriptedWalletRepository(snapshot: snapshot(.fixture(), environment: environment)),
                authority: .cloud(lineageID: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!, revision: 7),
                entitlement: .active(accessUntil: .distantFuture, autoRenewEnabled: true),
                hasValidCloudReplica: true
            )
        case "cloud-write-waiting":
            return store(
                repository: ScriptedWalletRepository(snapshot: snapshot(.fixture(), environment: environment), mutationMode: .waiting),
                authority: .cloud(lineageID: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!, revision: 7),
                entitlement: .active(accessUntil: .distantFuture, autoRenewEnabled: true),
                hasValidCloudReplica: true
            )
        case "cloud-write-accepted-waiting":
            return store(
                repository: ScriptedWalletRepository(snapshot: snapshot(.fixture(), environment: environment), mutationMode: .acceptedWaiting),
                authority: .cloud(lineageID: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!, revision: 7),
                entitlement: .active(accessUntil: .distantFuture, autoRenewEnabled: true),
                hasValidCloudReplica: true
            )
        case "cloud-write-rejected":
            return store(
                repository: ScriptedWalletRepository(snapshot: snapshot(.fixture(), environment: environment), mutationMode: .rejected),
                authority: .cloud(lineageID: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!, revision: 7),
                entitlement: .active(accessUntil: .distantFuture, autoRenewEnabled: true),
                hasValidCloudReplica: true
            )
        case "cloud-rejected-cleanup":
            var cleanupSnapshot = snapshot(.fixture(), environment: environment)
            cleanupSnapshot.pendingEvents = []
            return store(
                repository: ScriptedWalletRepository(
                    snapshot: cleanupSnapshot,
                    mutationMode: .rejectedCleanup,
                    rejectedCleanupFailures: 4
                ),
                authority: .cloud(lineageID: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!, revision: 7),
                entitlement: .active(accessUntil: .distantFuture, autoRenewEnabled: true),
                hasValidCloudReplica: true
            )
        case "cloud-profile-accepted-waiting":
            return store(
                repository: ScriptedWalletRepository(snapshot: snapshot(.fixture(), environment: environment), mutationMode: .profileAcceptedWaiting),
                authority: .cloud(lineageID: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!, revision: 7),
                entitlement: .active(accessUntil: .distantFuture, autoRenewEnabled: true),
                hasValidCloudReplica: true
            )
        case "cloud-reconnect":
            return store(
                repository: MockWalletRepository(snapshot: snapshot(.fixture(), environment: environment)),
                authority: .cloudOffline(lineageID: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!, revision: 7),
                entitlement: .active(accessUntil: .distantFuture, autoRenewEnabled: true),
                hasValidCloudReplica: false
            )
        case "reconnecting":
            // Reproduces the reported field defect's timing with synthetic
            // fixture data. `EW_UITEST_STALLED_FIRST_READ_SECONDS` holds the
            // launch read open so its failure lands after a later read already
            // succeeded; `EW_UITEST_OFFLINE_WINDOW_SECONDS` fails every read
            // started inside that window so the kid home starts genuinely
            // offline and only pull-to-refresh can recover it.
            let cached = snapshot(.fixture(), environment: environment)
            var reconnected = cached
            reconnected.acceptedBalanceCents = 3_675
            reconnected.pendingEvents = []
            reconnected.lastUpdated = .now
            reconnected.isStale = false
            return store(
                repository: ReconnectingWalletRepository(
                    cached: cached,
                    reconnected: reconnected,
                    stalledFirstReadSeconds: seconds(environment["EW_UITEST_STALLED_FIRST_READ_SECONDS"]),
                    offlineWindowSeconds: seconds(environment["EW_UITEST_OFFLINE_WINDOW_SECONDS"])
                )
            )
        case "legacy":
            return store(repository: MockWalletRepository(snapshot: snapshot(.fixture(), environment: environment)), authority: .legacyService)
        default:
            return nil
        }
    }

    /// Optional `EW_UITEST_NICKNAME` override for brand-placement and copy
    /// proofs. Absent => keep the synthetic fixture nickname ("Eddie").
    /// Present but blank => nil nickname so neutral fallbacks can be reviewed.
    private static func snapshot(_ base: WalletSnapshot, environment: [String: String]) -> WalletSnapshot {
        guard let raw = environment["EW_UITEST_NICKNAME"] else { return base }
        var copy = base
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.childNickname = trimmed.isEmpty ? nil : trimmed
        return copy
    }

    private static func seconds(_ raw: String?) -> TimeInterval {
        guard let raw, let value = TimeInterval(raw), value > 0 else { return 0 }
        return value
    }

    private static func emptySnapshot(environment: [String: String] = [:]) -> WalletSnapshot {
        var snapshot = WalletSnapshot.empty()
        snapshot.childNickname = "Eddie" // Synthetic fixture nickname only.
        snapshot.isStale = false
        return self.snapshot(snapshot, environment: environment)
    }

    private static func legacyCachedSnapshot() -> WalletSnapshot {
        var snapshot = WalletSnapshot.fixture()
        snapshot.activities = snapshot.activities.map { event in
            WalletEvent(
                id: event.id,
                remoteID: event.remoteID,
                type: event.type,
                amountCents: event.amountCents,
                balanceBeforeCents: event.balanceBeforeCents,
                balanceAfterCents: event.balanceAfterCents,
                reason: event.reason,
                date: event.date,
                syncState: event.syncState,
                explanation: "Legacy cached explanation with virtual dollars.",
                rejectionReason: event.rejectionReason
            )
        }
        return snapshot
    }
}

/// Scripted Sign in with Apple used by scenarios: succeeds after a short
/// pause with a fixed synthetic Apple user identifier, honoring the same
/// owning-parent check as the real coordinator.
@MainActor
final class ScriptedAppleSignInProvider: AppleSignInProviding {
    private let appleUserID: String
    private let onSuccess: (() -> Void)?

    init(appleUserID: String, onSuccess: (() -> Void)? = nil) {
        self.appleUserID = appleUserID
        self.onSuccess = onSuccess
    }

    func signIn(requiredAppleUserID: String?) async throws -> AppleSignInOutcome {
        try? await Task.sleep(nanoseconds: 300_000_000)
        if let requiredAppleUserID, requiredAppleUserID != appleUserID {
            throw WalletAPIError.identityMismatch
        }
        onSuccess?()
        return AppleSignInOutcome(
            session: AuthSession(token: "uitest-session", expiresAt: .distantFuture),
            appleUserID: appleUserID
        )
    }
}

/// A wallet whose authority is briefly unreachable, used to review and test the
/// child home's refresh honestly. Every read is the ordinary read - only their
/// timing differs, which is exactly what the reported defect turned on: the
/// read issued at launch can be held open so that its failure arrives after a
/// read issued later has already succeeded.
@MainActor
final class ReconnectingWalletRepository: WalletRepository {
    private let inner: MockWalletRepository
    private let reconnected: WalletSnapshot
    private let stalledFirstReadSeconds: TimeInterval
    private let offlineWindowSeconds: TimeInterval
    private let launchedAt = Date()
    private var reads = 0
    private var published: WalletSnapshot

    init(
        cached: WalletSnapshot,
        reconnected: WalletSnapshot,
        stalledFirstReadSeconds: TimeInterval,
        offlineWindowSeconds: TimeInterval
    ) {
        self.inner = MockWalletRepository(snapshot: reconnected)
        self.published = cached
        self.reconnected = reconnected
        self.stalledFirstReadSeconds = stalledFirstReadSeconds
        self.offlineWindowSeconds = offlineWindowSeconds
    }

    var isAuthenticated: Bool { true }
    var hasConfiguredKid: Bool { true }
    func snapshot() -> WalletSnapshot { published }
    func childSnapshot() -> WalletSnapshot { published }

    func refresh(for _: UserRole) async throws -> WalletSnapshot {
        reads += 1
        let isFirstRead = reads == 1
        let startedWithinOfflineWindow = Date().timeIntervalSince(launchedAt) < offlineWindowSeconds
        if isFirstRead, stalledFirstReadSeconds > 0 {
            try? await Task.sleep(nanoseconds: UInt64(stalledFirstReadSeconds * 1_000_000_000))
            throw unreachable()
        }
        if startedWithinOfflineWindow {
            throw unreachable()
        }
        published = reconnected
        return reconnected
    }

    func activity(limit: Int) async throws -> [WalletEvent] { try await inner.activity(limit: limit) }
    func activityDetail(remoteID: String) async throws -> WalletEvent { try await inner.activityDetail(remoteID: remoteID) }
    func loanDetail(remoteID: String) async throws -> LoanDetail { try await inner.loanDetail(remoteID: remoteID) }
    func submit(_ command: WalletCommand) async throws -> CommandResult { try await inner.submit(command) }
    func setAllowance(_ command: AllowanceRuleCommand) async throws -> WalletSnapshot { try await inner.setAllowance(command) }
    func setup(_ setup: ParentSetup) async throws -> WalletSnapshot { try await inner.setup(setup) }
    func updateChildProfile(_ update: ChildProfileUpdate) async throws -> WalletSnapshot { try await inner.updateChildProfile(update) }
    func clearAuthentication() { inner.clearAuthentication() }
    func clearSession() throws { try inner.clearSession() }

    private func unreachable() -> WalletAPIError {
        .network("The network is unavailable. The accepted balance was not changed.")
    }
}

@MainActor
private final class ScriptedAccountDeletionService: AccountDeletionPerforming {
    func preflightAccountDeletion() async throws {}

    func deleteAccount(idempotencyKey: String) async throws -> AccountDeletionResult {
        guard UUID(uuidString: idempotencyKey) != nil else {
            throw WalletAPIError.invalidResponse("The account deletion request needs a valid confirmation key.")
        }
        return .deleted
    }
}

enum ScriptedMutationMode: Equatable {
    case normal
    case waiting
    case acceptedWaiting
    case rejected
    case rejectedCleanup
    case profileAcceptedWaiting
}

/// Mock repository wrapper that can fail refreshes (offline / expired
/// session) and demand family setup before returning snapshots.
@MainActor
final class ScriptedWalletRepository: WalletRepository, CloudMutationStatusProviding {
    private let inner: MockWalletRepository
    var refreshError: WalletAPIError?
    var requiresSetup: Bool
    let mutationMode: ScriptedMutationMode
    private var rejectedCleanupFailures: Int
    private var rejectedCleanupActive: Bool

    init(
        snapshot: WalletSnapshot,
        refreshError: WalletAPIError? = nil,
        requiresSetup: Bool = false,
        mutationMode: ScriptedMutationMode = .normal,
        rejectedCleanupFailures: Int = 0
    ) {
        self.inner = MockWalletRepository(snapshot: snapshot)
        self.refreshError = refreshError
        self.requiresSetup = requiresSetup
        self.mutationMode = mutationMode
        self.rejectedCleanupFailures = rejectedCleanupFailures
        self.rejectedCleanupActive = mutationMode == .rejectedCleanup
    }

    var isAuthenticated: Bool { true }
    var hasConfiguredKid: Bool { inner.hasConfiguredKid && !requiresSetup }
    func snapshot() -> WalletSnapshot { inner.snapshot() }
    func childSnapshot() -> WalletSnapshot { inner.childSnapshot() }

    func refresh(for role: UserRole) async throws -> WalletSnapshot {
        if let refreshError { throw refreshError }
        if requiresSetup { throw WalletAPIError.familyNotSetup }
        if rejectedCleanupActive {
            if rejectedCleanupFailures > 0 {
                rejectedCleanupFailures -= 1
                throw WalletAPIError.cloudMutationAwaitingReconciliation
            }
            rejectedCleanupActive = false
        }
        return try await inner.refresh(for: role)
    }

    func activity(limit: Int) async throws -> [WalletEvent] { try await inner.activity(limit: limit) }
    func activityDetail(remoteID: String) async throws -> WalletEvent { try await inner.activityDetail(remoteID: remoteID) }
    func loanDetail(remoteID: String) async throws -> LoanDetail { try await inner.loanDetail(remoteID: remoteID) }

    func submit(_ command: WalletCommand) async throws -> CommandResult {
        if let refreshError { throw refreshError }
        switch mutationMode {
        case .normal, .profileAcceptedWaiting, .rejectedCleanup:
            return try await inner.submit(command)
        case .waiting:
            return .pending(scriptedEvent(
                command,
                state: .pending,
                message: "Cloud has not confirmed this change yet. This device will retry the same protected request. Do not record it again."
            ))
        case .acceptedWaiting:
            return .acceptedAwaitingReplica(scriptedEvent(
                command,
                state: .pending,
                message: "Cloud accepted this change. This device is waiting to see it in the wallet. Do not record it again."
            ))
        case .rejected:
            return .rejected(scriptedEvent(
                command,
                state: .rejected,
                message: "This action was not recorded and did not change the accepted balance.",
                rejectionReason: "This wallet changed on another device. Review the latest balance before recording it again."
            ))
        }
    }

    var hasUnsettledMutation: Bool { rejectedCleanupActive }
    var unsettledMutationPhase: CloudMutationPhase? { rejectedCleanupActive ? .rejected : nil }
    var unsettledMutationMessage: String? {
        rejectedCleanupActive ? "This change was not recorded. Finish local cleanup before recording another action." : nil
    }

    func setAllowance(_ command: AllowanceRuleCommand) async throws -> WalletSnapshot {
        if let refreshError { throw refreshError }
        return try await inner.setAllowance(command)
    }

    func setup(_ setup: ParentSetup) async throws -> WalletSnapshot {
        requiresSetup = false
        return try await inner.setup(setup)
    }

    func updateChildProfile(_ update: ChildProfileUpdate) async throws -> WalletSnapshot {
        if let refreshError { throw refreshError }
        if mutationMode == .profileAcceptedWaiting {
            throw WalletAPIError.cloudAcceptedAwaitingReplica
        }
        return try await inner.updateChildProfile(update)
    }

    private func scriptedEvent(
        _ command: WalletCommand,
        state: SyncState,
        message: String,
        rejectionReason: String? = nil
    ) -> WalletEvent {
        let type: ActivityType = switch command.kind {
        case .allowance: .allowance
        case .deposit: .deposit
        case .withdrawal: .withdrawal
        case .loan: .loan
        case .repayment: .repayment
        }
        return WalletEvent(
            type: type,
            amountCents: command.amountCents,
            reason: command.reason,
            syncState: state,
            explanation: message,
            rejectionReason: rejectionReason
        )
    }

    func clearAuthentication() { inner.clearAuthentication() }
    func clearSession() throws { try inner.clearSession() }
}
#endif
