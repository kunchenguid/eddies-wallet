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
            entitlement: CloudEntitlementState = .none
        ) -> WalletStore {
            let result = WalletStore(
                repository: repository,
                appleSignInProvider: provider ?? ScriptedAppleSignInProvider(appleUserID: signInUserID),
                initiallySignedIn: signedIn,
                pinStore: InMemoryParentPINStore(pin: pin),
                identityStore: InMemoryParentIdentityStore(appleUserID: knownOwner ? owningParentAppleUserID : nil),
                gatePolicy: gatePolicy
            )
            if let authority { result.applyDebugCloudState(authority: authority, purchase: purchase, entitlement: entitlement) }
            return result
        }

        switch scenario {
        case "configured":
            return store(repository: MockWalletRepository(snapshot: snapshot(.fixture(), environment: environment)))
        case "configured-empty":
            return store(repository: MockWalletRepository(snapshot: emptySnapshot(environment: environment)))
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
            let repository = ScriptedWalletRepository(
                snapshot: emptySnapshot(environment: environment),
                requiresSetup: true
            )
            return store(repository: repository, signedIn: false, pin: nil, knownOwner: false)
        case "cloud-pending":
            return store(repository: MockWalletRepository(snapshot: snapshot(.fixture(), environment: environment)), authority: .cloud(lineageID: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!, revision: 7), purchase: .pending, entitlement: .verificationPending)
        case "cloud-expired":
            return store(repository: MockWalletRepository(snapshot: snapshot(.fixture(), environment: environment)), authority: .local(lineageID: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!), entitlement: .expired)
        case "cloud-offline-grace":
            return store(repository: MockWalletRepository(snapshot: snapshot(.fixture(), environment: environment)), authority: .cloudOfflineGrace(lineageID: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!, revision: 7), entitlement: .active(accessUntil: .distantPast, autoRenewEnabled: true))
        case "device-conflict":
            return store(repository: MockWalletRepository(snapshot: snapshot(.fixture(), environment: environment)), authority: .cloud(lineageID: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!, revision: 8), purchase: .activationConflict, entitlement: .active(accessUntil: .distantFuture, autoRenewEnabled: true))
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

/// Mock repository wrapper that can fail refreshes (offline / expired
/// session) and demand family setup before returning snapshots.
@MainActor
final class ScriptedWalletRepository: WalletRepository {
    private let inner: MockWalletRepository
    var refreshError: WalletAPIError?
    var requiresSetup: Bool

    init(snapshot: WalletSnapshot, refreshError: WalletAPIError? = nil, requiresSetup: Bool = false) {
        self.inner = MockWalletRepository(snapshot: snapshot)
        self.refreshError = refreshError
        self.requiresSetup = requiresSetup
    }

    var isAuthenticated: Bool { true }
    var hasConfiguredKid: Bool { inner.hasConfiguredKid && !requiresSetup }
    func snapshot() -> WalletSnapshot { inner.snapshot() }
    func childSnapshot() -> WalletSnapshot { inner.childSnapshot() }

    func refresh(for role: UserRole) async throws -> WalletSnapshot {
        if let refreshError { throw refreshError }
        if requiresSetup { throw WalletAPIError.familyNotSetup }
        return try await inner.refresh(for: role)
    }

    func activity(limit: Int) async throws -> [WalletEvent] { try await inner.activity(limit: limit) }
    func activityDetail(remoteID: String) async throws -> WalletEvent { try await inner.activityDetail(remoteID: remoteID) }
    func loanDetail(remoteID: String) async throws -> LoanDetail { try await inner.loanDetail(remoteID: remoteID) }

    func submit(_ command: WalletCommand) async throws -> CommandResult {
        if let refreshError { throw refreshError }
        return try await inner.submit(command)
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
        return try await inner.updateChildProfile(update)
    }

    func clearAuthentication() { inner.clearAuthentication() }
    func clearSession() throws { try inner.clearSession() }
}
#endif
