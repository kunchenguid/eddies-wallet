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

    static var disablesAnimations: Bool {
        ProcessInfo.processInfo.environment["EW_UITEST_DISABLE_ANIMATIONS"] == "1"
    }

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
        case "allowance-missed":
            let calendar = Calendar.current
            let today = calendar.startOfDay(for: .now)
            let firstMissed = calendar.date(byAdding: .day, value: -21, to: today) ?? today
            var overdue = snapshot(.fixture(), environment: environment)
            overdue.allowance = AllowancePlan(
                remoteID: "debug-allowance",
                amountCents: 500,
                cadence: "every week",
                weekday: calendar.component(.weekday, from: firstMissed) - 1,
                nextDate: firstMissed,
                nextOccurrenceID: "debug-allowance-occurrence"
            )
            return store(repository: MockWalletRepository(snapshot: overdue))
        case "loan-installments-missed":
            // Three weekly payments already past due at the named US$4.00, on a
            // loan with US$15.00 left. Catching up settles US$12.00, which
            // leaves today's payment capped at the US$3.00 that actually
            // remains - so the final-payment cap is visible to a parent, not
            // only in a unit test.
            let calendar = Calendar.current
            let today = calendar.startOfDay(for: .now)
            let firstMissed = calendar.date(byAdding: .day, value: -21, to: today) ?? today
            var scheduled = snapshot(.fixture(), environment: environment)
            scheduled.loan = Loan(
                remoteID: "debug-loan",
                originalCents: 2_000,
                remainingCents: 1_500,
                purpose: "Bike helmet",
                schedule: LoanSchedule(
                    cadence: .weekly,
                    amountCents: 400,
                    firstDueDate: firstMissed,
                    occurrences: [
                        LoanSchedule.Occurrence(id: "debug-loan-occurrence", dueDate: firstMissed, status: .scheduled)
                    ]
                )
            )
            return store(repository: MockWalletRepository(snapshot: scheduled))
        case "delete-account":
            return store(
                repository: MockWalletRepository(snapshot: snapshot(.fixture(), environment: environment)),
                accountDeletionService: ScriptedAccountDeletionService()
            )
        case "delete-account-subscribed":
            return store(
                repository: MockWalletRepository(snapshot: snapshot(.fixture(), environment: environment)),
                authority: .cloud(lineageID: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!, revision: 7),
                entitlement: .active(accessUntil: syntheticCloudAccessUntil, autoRenewEnabled: true),
                hasValidCloudReplica: true,
                accountDeletionService: ScriptedAccountDeletionService()
            )
        case "offline":
            let repository = ScriptedWalletRepository(
                snapshot: snapshot(legacyCachedSnapshot(), environment: environment),
                refreshError: scriptedTransportFailure(URLError(.notConnectedToInternet))
            )
            return store(repository: repository)
        case "cannot-reach":
            // The other half of the honest split: a device that is online and
            // still cannot get an answer. It must never read as offline.
            let repository = ScriptedWalletRepository(
                snapshot: snapshot(legacyCachedSnapshot(), environment: environment),
                refreshError: scriptedTransportFailure(URLError(.timedOut))
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
        case "cloud-plans-not-offered":
            return store(repository: MockWalletRepository(snapshot: snapshot(.fixture(), environment: environment)), authority: .local(lineageID: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!), purchase: .productsUnavailable(.notOffered))
        case "cloud-plans-check-failed":
            return store(repository: MockWalletRepository(snapshot: snapshot(.fixture(), environment: environment)), authority: .local(lineageID: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!), purchase: .productsUnavailable(.couldNotCheck))
        case "cloud-plans-available":
            // Injects the same shape StoreKit resolves in production
            // (`CloudSubscriptionStore.storekit` product ids, display names,
            // and prices) without a live StoreKit/backend round trip, so the
            // plans card - and its Guideline 3.1.2 legal links - render
            // deterministically for UI tests.
            let result = store(repository: MockWalletRepository(snapshot: snapshot(.fixture(), environment: environment)), authority: .local(lineageID: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!))
            result.applyDebugCloudPlans(debugCloudPlans(includePrices: true))
            return result
        case "cloud-plans-no-price":
            // Same populated plans surface as `cloud-plans-available`, but
            // with StoreKit prices left blank so an App Store screenshot can
            // be captured without a live price fetch and without baking a
            // territory-specific price into the image.
            let result = store(repository: MockWalletRepository(snapshot: snapshot(.fixture(), environment: environment)), authority: .local(lineageID: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!))
            result.applyDebugCloudPlans(debugCloudPlans(includePrices: false))
            return result
        case "cloud-offline-grace":
            return store(repository: MockWalletRepository(snapshot: snapshot(.fixture(), environment: environment)), authority: .cloudOfflineGrace(lineageID: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!, revision: 7), entitlement: .active(accessUntil: .distantPast, autoRenewEnabled: true))
        case "device-conflict":
            return store(repository: MockWalletRepository(snapshot: snapshot(.fixture(), environment: environment)), authority: .cloud(lineageID: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!, revision: 8), purchase: .activationConflict, entitlement: .active(accessUntil: syntheticCloudAccessUntil, autoRenewEnabled: true))
        case "cloud-write-recorded":
            return store(
                repository: ScriptedWalletRepository(snapshot: snapshot(.fixture(), environment: environment)),
                authority: .cloud(lineageID: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!, revision: 7),
                entitlement: .active(accessUntil: syntheticCloudAccessUntil, autoRenewEnabled: true),
                hasValidCloudReplica: true
            )
        case "cloud-write-waiting":
            return store(
                repository: ScriptedWalletRepository(snapshot: snapshot(.fixture(), environment: environment), mutationMode: .waiting),
                authority: .cloud(lineageID: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!, revision: 7),
                entitlement: .active(accessUntil: syntheticCloudAccessUntil, autoRenewEnabled: true),
                hasValidCloudReplica: true
            )
        case "cloud-write-accepted-waiting":
            return store(
                repository: ScriptedWalletRepository(snapshot: snapshot(.fixture(), environment: environment), mutationMode: .acceptedWaiting),
                authority: .cloud(lineageID: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!, revision: 7),
                entitlement: .active(accessUntil: syntheticCloudAccessUntil, autoRenewEnabled: true),
                hasValidCloudReplica: true
            )
        case "cloud-write-rejected":
            return store(
                repository: ScriptedWalletRepository(snapshot: snapshot(.fixture(), environment: environment), mutationMode: .rejected),
                authority: .cloud(lineageID: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!, revision: 7),
                entitlement: .active(accessUntil: syntheticCloudAccessUntil, autoRenewEnabled: true),
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
                entitlement: .active(accessUntil: syntheticCloudAccessUntil, autoRenewEnabled: true),
                hasValidCloudReplica: true
            )
        case "cloud-profile-accepted-waiting":
            return store(
                repository: ScriptedWalletRepository(snapshot: snapshot(.fixture(), environment: environment), mutationMode: .profileAcceptedWaiting),
                authority: .cloud(lineageID: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!, revision: 7),
                entitlement: .active(accessUntil: syntheticCloudAccessUntil, autoRenewEnabled: true),
                hasValidCloudReplica: true
            )
        case "cloud-reconnect":
            return store(
                repository: MockWalletRepository(snapshot: snapshot(.fixture(), environment: environment)),
                authority: .cloudOffline(lineageID: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!, revision: 7),
                entitlement: .active(accessUntil: syntheticCloudAccessUntil, autoRenewEnabled: true),
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
        case "cloud-live-parent":
            // The only scenario that composes the real `CloudWalletRepository`
            // over a synthetic in-process transport, so a UI test can drive the
            // production Cloud read path - bootstrap, `/v1/cloud/changes`,
            // replica application, and write readiness - instead of a scripted
            // repository that can only pose as one. It is what makes the
            // current-replica-but-blocked states reachable end to end.
            // `EW_UITEST_CLOUD_READ_DELAY_SECONDS` holds each `changes` read
            // open for a realistic round trip so a read can still be in flight
            // when the surface that started it goes away, and
            // `EW_UITEST_CLOUD_FAILED_READS` fails exactly that many changes
            // reads after bootstrap, so a parent area with a valid replica can
            // be driven into a genuine block and back out of it without making
            // the scenario depend on simulator launch or automation timing.
            guard let replica = try? LocalWalletRepository(inMemory: true) else { return nil }
            let lineage = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
            let transport = SyntheticCloudTransport(
                lineageID: lineage,
                readDelay: seconds(environment["EW_UITEST_CLOUD_READ_DELAY_SECONDS"], default: 0.6),
                failedReads: count(environment["EW_UITEST_CLOUD_FAILED_READS"])
            )
            let cloud = CloudWalletRepository(
                client: CloudAPIClient(
                    baseURL: SyntheticCloudTransport.baseURL,
                    sessionStore: InMemorySessionStore(
                        session: AuthSession(token: "uitest-session", expiresAt: .distantFuture)
                    ),
                    transport: transport
                ),
                replica: replica,
                lineageID: lineage,
                revision: 0,
                requiresBootstrap: true
            )
            return store(
                repository: cloud,
                authority: .cloud(lineageID: lineage, revision: 2),
                entitlement: .active(accessUntil: syntheticCloudAccessUntil, autoRenewEnabled: true)
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

    /// A plausible renewal date for synthetic Cloud states. `.distantFuture`
    /// renders as "Cloud is on through Dec 31, 4000", which reads as a defect
    /// in every review screenshot the scenarios produce.
    private static let syntheticCloudAccessUntil = Date(timeIntervalSinceNow: 60 * 60 * 24 * 365)

    private static func debugCloudPlans(includePrices: Bool) -> [CloudPlan] {
        [
            CloudPlan(
                id: "com.kunchenguid.eddieswallet.cloud.monthly",
                displayName: "Cloud monthly",
                displayPrice: includePrices ? "$2.99" : "",
                periodDescription: "every month"
            ),
            CloudPlan(
                id: "com.kunchenguid.eddieswallet.cloud.annual",
                displayName: "Cloud annual",
                displayPrice: includePrices ? "$24.99" : "",
                periodDescription: "every year"
            )
        ]
    }

    private static func count(_ raw: String?) -> Int {
        guard let raw, let value = Int(raw), value > 0 else { return 0 }
        return value
    }

    private static func seconds(_ raw: String?) -> TimeInterval {
        guard let raw, let value = TimeInterval(raw), value > 0 else { return 0 }
        return value
    }

    private static func seconds(_ raw: String?, default fallback: TimeInterval) -> TimeInterval {
        guard let raw else { return fallback }
        guard let value = TimeInterval(raw), value >= 0 else { return fallback }
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
        scriptedTransportFailure(URLError(.notConnectedToInternet))
    }
}

/// The Cloud read contract, answered in process from synthetic fixture data.
///
/// It exists so a UI test can run the real `CloudWalletRepository` and
/// `CloudAPIClient` - the production read, apply, and write-readiness path -
/// with no network, account, or service. Only the wire is synthetic.
///
/// `readDelay` holds every `/v1/cloud/changes` answer open for a realistic
/// round trip, and the wait is cancellation-aware in exactly the way
/// `URLSession.data(for:)` is: a cancelled surrounding task ends the request
/// with `URLError.cancelled` rather than an answer. That is what lets a test
/// reproduce a read that was still in flight when the screen that started it
/// went away.
///
/// `data(for:)` is nonisolated and the store starts unstructured reads, so
/// every stored property is guarded by one lock.
final class SyntheticCloudTransport: HTTPTransport, @unchecked Sendable {
    static let baseURL = URL(string: "https://synthetic-cloud.invalid")!

    private let lineageID: UUID
    private let readDelay: TimeInterval
    private let lock = NSLock()
    private var readCount = 0
    private var failedReadsRemaining: Int

    init(lineageID: UUID, readDelay: TimeInterval, failedReads: Int = 0) {
        self.lineageID = lineageID
        self.readDelay = readDelay
        self.failedReadsRemaining = failedReads
    }

    /// How many `/v1/cloud/changes` reads this transport has been asked for.
    var reads: Int {
        lock.lock()
        defer { lock.unlock() }
        return readCount
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let path = request.url?.path ?? ""
        switch path {
        case "/v1/cloud/bootstrap":
            return try respond(Self.replica(lineageID: lineageID), to: request)
        case "/v1/cloud/changes":
            lock.lock()
            readCount += 1
            let shouldFail = failedReadsRemaining > 0
            if shouldFail { failedReadsRemaining -= 1 }
            lock.unlock()
            // The bootstrap at launch always lands, so the device keeps a valid
            // replica; only the requested number of later reads go unreachable.
            // Counting requests rather than wall-clock time keeps this state
            // deterministic even when simulator automation attaches slowly.
            if shouldFail { throw URLError(.notConnectedToInternet) }
            if readDelay > 0 {
                do {
                    try await Task.sleep(nanoseconds: UInt64(readDelay * 1_000_000_000))
                } catch {
                    // Exactly what URLSession reports for a request whose task
                    // was cancelled before an answer arrived.
                    throw URLError(.cancelled)
                }
            }
            return try respond(Self.replica(lineageID: lineageID), to: request)
        default:
            return try respond(Data("{}".utf8), to: request, status: 501)
        }
    }

    private func respond(_ body: Data, to request: URLRequest, status: Int = 200) throws -> (Data, URLResponse) {
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil) else {
            throw URLError(.badServerResponse)
        }
        return (body, response)
    }

    /// One settled household at revision 2: two accepted entries, balance
    /// US$7.50, no loans and no allowance rule. A `changes` read answers the
    /// same accepted revision, which is what a healthy wallet with nothing new
    /// actually returns.
    private static func replica(lineageID: UUID) -> Data {
        Data("""
        {"household":{"lineageId":"\(lineageID.uuidString.lowercased())","authority":"cloud","revision":2},
         "family":{"id":"f-1","name":"Eddie's family"},
         "child":{"id":"c-1","nickname":"Eddie","avatarUrl":null},
         "wallet":{"id":"w-1","balanceCents":750},
         "entries":[
           {"id":"c1111111-1111-4111-8111-111111111111","type":"deposit","direction":"credit","amountCents":1000,"balanceBeforeCents":0,"balanceAfterCents":1000,"reason":"chores","loanId":null,"recordedAt":"2026-07-24T10:00:00.000Z","acceptedRevision":1},
           {"id":"c2222222-2222-4222-8222-222222222222","type":"withdrawal","direction":"debit","amountCents":250,"balanceBeforeCents":1000,"balanceAfterCents":750,"reason":"sticker book","loanId":null,"recordedAt":"2026-07-25T10:00:00.000Z","acceptedRevision":2}],
         "loans":[],"allowanceRule":null,"nextCursor":null}
        """.utf8)
    }
}

/// Builds a scripted failure through the same preservation path a real request
/// uses, so a scenario reproduces exactly the state a real failure produces -
/// including what the Parent area's connection readout would show.
private func scriptedTransportFailure(_ error: URLError, path: String = "/v1/child-view") -> WalletAPIError {
    .transportFailure(
        TransportDiagnostic.transportFailure(error, path: path, elapsedMilliseconds: 12)
    )
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
        case .repayment, .loanInstallment: .repayment
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
