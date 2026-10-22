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

    static func allowanceStartDate(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Date? {
        guard environment["EW_UITEST_SCENARIO"] == "cloud-allowance-advanced" else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar.date(from: DateComponents(
            year: 2099,
            month: 1,
            day: 7,
            hour: 12
        ))
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
        case "local-loan":
            // A real free wallet - `LocalWalletRepository`, not a mock - with
            // history, so the kid's Pay back runs on the genuine free
            // authority: US$26.00 in the wallet and a US$10.00 bike-helmet
            // loan paid US$2.00 every week, first payment three days out.
            // `EW_UITEST_LOCAL_LOAN_PLAN=0` leaves the loan without a plan.
            let snapshot = localLoanSnapshot(withPlan: environment["EW_UITEST_LOCAL_LOAN_PLAN"] != "0")
            guard let repository = try? LocalWalletRepository.debugSeeded(snapshot) else { return nil }
            return store(repository: repository)
        case "configured-empty":
            return store(repository: MockWalletRepository(snapshot: emptySnapshot(environment: environment)))
        case "allowance-missed":
            let calendar = Calendar.current
            let today = calendar.startOfDay(for: .now)
            let firstMissed = calendar.date(byAdding: .day, value: -21, to: today) ?? today
            var overdue = snapshot(.fixture(), environment: environment)
            overdue.allowance = try! AllowancePlan(
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
        case "cloud-allowance-advanced":
            return store(
                repository: ScriptedWalletRepository(snapshot: emptySnapshot(environment: environment), mutationMode: .allowanceAdvanced),
                authority: .cloud(lineageID: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!, revision: 7),
                entitlement: .active(accessUntil: syntheticCloudAccessUntil, autoRenewEnabled: true),
                hasValidCloudReplica: true
            )
        case "cloud-allowance-refresh-confirmed":
            return store(
                repository: ScriptedWalletRepository(snapshot: emptySnapshot(environment: environment), mutationMode: .allowanceAcceptedScheduleUnavailable),
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
            // `EW_UITEST_CLOUD_ALLOWANCE=1` gives the household a live weekly
            // allowance rule and serves `/v1/allowance-rule` the way the
            // service does - a fixed start date, an editable amount and day -
            // so the allowance editor can be driven against the real rule.
            // `EW_UITEST_CLOUD_LOAN=1` gives it an open US$5.00 loan and serves
            // `POST /v1/loans/:id/repayments` the way the service does, kid
            // label included, so the kid's Pay back runs the real Cloud write.
            // `EW_UITEST_CLOUD_REPAYMENT_CONFLICTS` refuses that many
            // repayments with the service's revision conflict, each after
            // another device deposited US$1.00 first.
            guard let replica = try? LocalWalletRepository(inMemory: true) else { return nil }
            let lineage = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
            let transport = SyntheticCloudTransport(
                lineageID: lineage,
                readDelay: seconds(environment["EW_UITEST_CLOUD_READ_DELAY_SECONDS"], default: 0.6),
                failedReads: count(environment["EW_UITEST_CLOUD_FAILED_READS"]),
                allowance: environment["EW_UITEST_CLOUD_ALLOWANCE"] == "1" ? .sample() : nil,
                loan: environment["EW_UITEST_CLOUD_LOAN"] == "1" ? .sample : nil,
                repaymentConflicts: count(environment["EW_UITEST_CLOUD_REPAYMENT_CONFLICTS"])
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
        case "cloud-live-expired":
            // The production composition from `EddysWalletApp.init`: one
            // `CloudAPIClient`, `CloudWalletRepository`, and `CloudCoordinator`
            // share a session store, and Sign in with Apple verifies the
            // owning parent without exchanging a session. The stored bearer
            // is one the synthetic service no longer accepts, the same way a
            // session past `SESSION_TTL_DAYS` is refused. Bootstrap still
            // lands so the kid home can show the last wallet; every later
            // read with that bearer is 401 until `POST /v1/auth/apple`.
            guard let replica = try? LocalWalletRepository(inMemory: true) else { return nil }
            let lineage = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
            let transport = SyntheticCloudTransport(
                lineageID: lineage,
                readDelay: seconds(environment["EW_UITEST_CLOUD_READ_DELAY_SECONDS"], default: 0),
                staleToken: "stale-session"
            )
            let client = CloudAPIClient(
                baseURL: SyntheticCloudTransport.baseURL,
                sessionStore: InMemorySessionStore(
                    session: AuthSession(token: "stale-session", expiresAt: .distantFuture)
                ),
                transport: transport
            )
            return WalletStore(
                repository: CloudWalletRepository(
                    client: client,
                    replica: replica,
                    lineageID: lineage,
                    revision: 0,
                    requiresBootstrap: true
                ),
                appleSignInProvider: IdentityOnlyAppleSignInProvider(appleUserID: signInUserID),
                pinStore: InMemoryParentPINStore(pin: "1234"),
                identityStore: InMemoryParentIdentityStore(appleUserID: owningParentAppleUserID),
                gatePolicy: gatePolicy,
                cloudCoordinator: CloudCoordinator(
                    client: client,
                    subscriptions: CloudSubscriptionStore(client: client, observeTransactions: false)
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
    /// Optional `EW_UITEST_ACTIVITY_ROWS=N` appends N older synthetic activity
    /// rows after the fixture's own, one per day, so a long history can be
    /// reviewed and tested without a long-lived wallet.
    private static func snapshot(_ base: WalletSnapshot, environment: [String: String]) -> WalletSnapshot {
        var copy = base
        if let raw = environment["EW_UITEST_NICKNAME"] {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            copy.childNickname = trimmed.isEmpty ? nil : trimmed
        }
        copy.activities += paddedActivities(
            count: count(environment["EW_UITEST_ACTIVITY_ROWS"]),
            after: copy.activities.last?.date ?? .now
        )
        return copy
    }

    private static func paddedActivities(count: Int, after date: Date) -> [WalletEvent] {
        guard count > 0 else { return [] }
        let calendar = Calendar.current
        let reasons = ["Chores", "Snack", "Weekly", "Birthday card", "Book fair", "Lemonade stand", "Movie night", "Saved up"]
        return (0..<count).map { index in
            let type: ActivityType = [.withdrawal, .deposit, .allowance][index % 3]
            let amountCents = switch type {
            case .withdrawal: 300 + (index % 4) * 125
            case .deposit: 500
            default: 1_000
            }
            return WalletEvent(
                type: type,
                amountCents: amountCents,
                reason: reasons[index % reasons.count],
                date: calendar.date(byAdding: .day, value: -(index + 1), to: date) ?? date,
                explanation: "Synthetic history row for review and tests."
            )
        }
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

    /// The `local-loan` free wallet's history, oldest first: a US$20.00
    /// deposit, the US$10.00 loan, then US$4.00 used. Every entry carries the
    /// balances a local save writes, so the history validates and balances.
    static func localLoanSnapshot(withPlan: Bool, now: Date = .now, calendar: Calendar = .current) -> WalletSnapshot {
        let today = calendar.startOfDay(for: now)
        func daysAgo(_ days: Int) -> Date {
            calendar.date(byAdding: .day, value: -days, to: now) ?? now
        }
        let firstPayment = calendar.date(byAdding: .day, value: 3, to: today) ?? today
        let deposit = WalletEvent(type: .deposit, amountCents: 2_000, balanceBeforeCents: 0, balanceAfterCents: 2_000, reason: "Birthday", date: daysAgo(12), explanation: AcceptedEventCopy.explanation(for: .deposit, amountCents: 2_000))
        let loan = WalletEvent(type: .loan, amountCents: 1_000, balanceBeforeCents: 2_000, balanceAfterCents: 3_000, reason: "Bike helmet", date: daysAgo(8), explanation: AcceptedEventCopy.explanation(for: .loan, amountCents: 1_000))
        let used = WalletEvent(type: .withdrawal, amountCents: 400, balanceBeforeCents: 3_000, balanceAfterCents: 2_600, reason: "Comic book", date: daysAgo(5), explanation: AcceptedEventCopy.explanation(for: .withdrawal, amountCents: 400))
        return WalletSnapshot(
            acceptedBalanceCents: 2_600,
            activities: [used, loan, deposit],
            loan: Loan(
                remoteID: "local-loan",
                originalCents: 1_000,
                remainingCents: 1_000,
                purpose: "Bike helmet",
                schedule: withPlan
                    ? LoanSchedule.opening(LoanInstallmentPlan(cadence: .weekly, amountCents: 200, firstDueDate: firstPayment), asOf: now, calendar: calendar)
                    : nil
            ),
            allowance: nil,
            pendingEvents: [],
            lastUpdated: now,
            isStale: false,
            childNickname: "Eddie" // Synthetic fixture nickname only.
        )
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

/// Matches the shipped `AppleSignInCoordinator()`, which is built with no
/// authenticator. It verifies the Apple user and returns the short-lived
/// identity proof, and its `signIn` never exchanges that proof for a session.
@MainActor
final class IdentityOnlyAppleSignInProvider: AppleSignInProviding {
    private let appleUserID: String

    init(appleUserID: String) {
        self.appleUserID = appleUserID
    }

    func signIn(requiredAppleUserID: String?) async throws -> AppleSignInOutcome {
        try? await Task.sleep(nanoseconds: 300_000_000)
        if let requiredAppleUserID, requiredAppleUserID != appleUserID {
            throw WalletAPIError.identityMismatch
        }
        let identity = AppleIdentity(
            appleUserID: appleUserID,
            identityToken: "synthetic-identity-token",
            signedNonce: "synthetic-nonce"
        )
        return AppleSignInOutcome(session: nil, appleUserID: identity.appleUserID, identity: identity)
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
    private var allowance: SyntheticAllowanceRule?
    private var revision: Int64 = 2
    private var balanceCents = 750
    private var loan: SyntheticLoan?
    /// Entries accepted after the fixed history, oldest first, as JSON.
    private var acceptedEntries: [String] = []
    /// One answer per idempotency key, replayed exactly, as the service does.
    private var repaymentAnswers: [String: (body: String, status: Int)] = [:]
    private var repaymentConflictsRemaining: Int
    private var repaymentBodies: [[String: Any]] = []
    /// A bearer the service no longer accepts. Every request but launch
    /// bootstrap that presents it is answered 401 UNAUTHENTICATED. `POST
    /// /v1/auth/apple` mints a fresh session instead.
    private let staleToken: String?

    init(
        lineageID: UUID,
        readDelay: TimeInterval,
        failedReads: Int = 0,
        allowance: SyntheticAllowanceRule? = nil,
        loan: SyntheticLoan? = nil,
        repaymentConflicts: Int = 0,
        staleToken: String? = nil
    ) {
        self.lineageID = lineageID
        self.readDelay = readDelay
        self.failedReadsRemaining = failedReads
        self.allowance = allowance
        self.loan = loan
        self.repaymentConflictsRemaining = repaymentConflicts
        self.staleToken = staleToken
        if let loan {
            // The loan was handed over after the fixed history, at revision 3.
            revision = 3
            balanceCents += loan.principalCents
        }
    }

    /// How many `/v1/cloud/changes` reads this transport has been asked for.
    var reads: Int {
        lock.withLock { readCount }
    }

    /// Every repayment body this service accepted or refused, in order, as
    /// JSON objects - what a test reads to see the label actually sent.
    var receivedRepayments: [[String: Any]] {
        lock.withLock { repaymentBodies }
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let path = request.url?.path ?? ""
        let method = request.httpMethod ?? "GET"
        if method == "POST", path == "/v1/auth/apple" {
            return try respond(
                Data(#"{"token":"renewed-session","expiresAt":"2099-01-01T00:00:00.000Z"}"#.utf8),
                to: request
            )
        }
        let bearer = request.value(forHTTPHeaderField: "Authorization")?.replacingOccurrences(of: "Bearer ", with: "")
        if let staleToken, bearer == staleToken, path != "/v1/cloud/bootstrap" {
            return try respond(
                Data(#"{"error":{"code":"UNAUTHENTICATED","message":"A valid parent session is required."}}"#.utf8),
                to: request,
                status: 401
            )
        }
        switch path {
        case "/v1/cloud/bootstrap":
            return try respond(replica(), to: request)
        case "/v1/allowance-rule" where request.httpMethod == "GET":
            let rule = lock.withLock { allowance?.json ?? "null" }
            return try respond(Data("{\"allowanceRule\":\(rule)}".utf8), to: request)
        case "/v1/allowance-rule" where request.httpMethod == "PUT":
            return try setAllowance(request)
        case let repayments where method == "POST" && repayments.hasPrefix("/v1/loans/") && repayments.hasSuffix("/repayments"):
            let loanID = String(repayments.dropFirst("/v1/loans/".count).dropLast("/repayments".count))
            return try repay(request, loanID: loanID)
        case "/v1/cloud/changes":
            let shouldFail = lock.withLock {
                readCount += 1
                let shouldFail = failedReadsRemaining > 0
                if shouldFail { failedReadsRemaining -= 1 }
                return shouldFail
            }
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
            return try respond(replica(), to: request)
        default:
            return try respond(Data("{}".utf8), to: request, status: 501)
        }
    }

    /// Mirrors the service's `PUT /v1/allowance-rule` on an existing rule: a
    /// new amount, weekday and end date are accepted and advance the
    /// household revision, and the scheduled head moves to the next payout
    /// day on or after today; a changed start date is refused with the
    /// service's own 400, word for word.
    private func setAllowance(_ request: URLRequest) throws -> (Data, URLResponse) {
        guard let body = request.httpBody,
              let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let amountCents = object["amountCents"] as? Int,
              let weekday = object["weekday"] as? Int,
              let startDate = object["startDate"] as? String else {
            return try respond(
                Data(#"{"error":{"code":"VALIDATION_ERROR","message":"amountCents, weekday and startDate are required."}}"#.utf8),
                to: request,
                status: 400
            )
        }
        let endDate = object["endDate"] as? String
        let (responseBody, status): (String, Int) = lock.withLock {
            if let existing = allowance, existing.startDate != startDate {
                return (#"{"error":{"code":"VALIDATION_ERROR","message":"startDate cannot change after an allowance rule is created."}}"#, 400)
            }
            allowance = SyntheticAllowanceRule(
                amountCents: amountCents,
                weekday: weekday,
                startDate: startDate,
                endDate: endDate,
                calendar: .current
            )
            revision += 1
            return ("{\"revision\":\(revision)}", 200)
        }
        return try respond(Data(responseBody.utf8), to: request, status: status)
    }

    /// Mirrors the service's `POST /v1/loans/:loanId/repayments`: the
    /// `If-Match` revision, one answer per idempotency key, at most what is
    /// left and what is in the wallet, and an optional `recordedBy` of
    /// `parent` or `child` that the accepted entry keeps. A payment that
    /// clears the loan marks it paid.
    private func repay(_ request: URLRequest, loanID: String) throws -> (Data, URLResponse) {
        let object = request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        let key = request.value(forHTTPHeaderField: "Idempotency-Key") ?? ""
        let ifMatch = request.value(forHTTPHeaderField: "If-Match")
        let answer: (body: String, status: Int) = lock.withLock {
            repaymentBodies.append(object)
            if let replay = repaymentAnswers[key] { return replay }
            let answer = acceptRepayment(object, loanID: loanID, ifMatch: ifMatch)
            if answer.status == 200 { repaymentAnswers[key] = answer }
            return answer
        }
        return try respond(Data(answer.body.utf8), to: request, status: answer.status)
    }

    /// Called with `lock` held.
    private func acceptRepayment(_ object: [String: Any], loanID: String, ifMatch: String?) -> (body: String, status: Int) {
        func refusal(_ status: Int, _ code: String, _ message: String) -> (body: String, status: Int) {
            ("{\"error\":{\"code\":\"\(code)\",\"message\":\"\(message)\"}}", status)
        }
        guard let amountCents = object["amountCents"] as? Int, amountCents > 0 else {
            return refusal(400, "VALIDATION_ERROR", "amountCents must be a positive integer.")
        }
        let recordedBy = object["recordedBy"] as? String ?? "parent"
        guard recordedBy == "parent" || recordedBy == "child" else {
            return refusal(400, "VALIDATION_ERROR", "recordedBy must be parent or child.")
        }
        guard var current = loan, current.id == loanID, current.outstandingCents > 0 else {
            return refusal(404, "LOAN_NOT_FOUND", "The loan was not found.")
        }
        if repaymentConflictsRemaining > 0 {
            // Another device moved first: it deposited US$1.00, so this
            // device's revision is behind and nothing is recorded here.
            repaymentConflictsRemaining -= 1
            append(type: "deposit", direction: "credit", amountCents: 100, reason: "Another device", loanID: nil, recordedBy: "parent")
            return ("{\"error\":{\"code\":\"REVISION_CONFLICT\",\"message\":\"The wallet changed.\",\"details\":{\"currentRevision\":\(revision)}}}", 409)
        }
        guard ifMatch == "\"rev-\(revision)\"" else {
            return ("{\"error\":{\"code\":\"REVISION_CONFLICT\",\"message\":\"The wallet changed.\",\"details\":{\"currentRevision\":\(revision)}}}", 409)
        }
        guard amountCents <= current.outstandingCents else {
            return refusal(409, "REPAYMENT_EXCEEDS_OUTSTANDING", "The repayment is greater than the amount left to repay.")
        }
        guard amountCents <= balanceCents else {
            return refusal(409, "INSUFFICIENT_BALANCE", "The repayment is greater than the wallet balance.")
        }
        current.outstandingCents -= amountCents
        if current.outstandingCents == 0 { current.paidAt = Date() }
        loan = current
        let entry = append(type: "repayment", direction: "debit", amountCents: amountCents, reason: nil, loanID: loanID, recordedBy: recordedBy)
        return ("{\"entry\":\(entry),\"revision\":\(revision)}", 200)
    }

    /// Records one accepted entry at the next revision. Called with `lock` held.
    @discardableResult
    private func append(type: String, direction: String, amountCents: Int, reason: String?, loanID: String?, recordedBy: String) -> String {
        let before = balanceCents
        balanceCents += direction == "credit" ? amountCents : -amountCents
        revision += 1
        let reasonJSON = reason.map { "\"\($0)\"" } ?? "null"
        let loanJSON = loanID.map { "\"\($0)\"" } ?? "null"
        let entry = "{\"id\":\"\(UUID().uuidString.lowercased())\",\"type\":\"\(type)\",\"direction\":\"\(direction)\",\"amountCents\":\(amountCents),\"balanceBeforeCents\":\(before),\"balanceAfterCents\":\(balanceCents),\"reason\":\(reasonJSON),\"loanId\":\(loanJSON),\"recordedAt\":\"\(CloudImportManifest.timestamp(Date()))\",\"acceptedRevision\":\(revision),\"recordedBy\":\"\(recordedBy)\"}"
        acceptedEntries.append(entry)
        return entry
    }

    private func respond(_ body: Data, to request: URLRequest, status: Int = 200) throws -> (Data, URLResponse) {
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil) else {
            throw URLError(.badServerResponse)
        }
        return (body, response)
    }

    /// One settled household: two accepted entries, balance US$7.50, no loans,
    /// and the allowance rule this transport was given, if any, at the
    /// current revision (2 until a write advances it). With a loan, the loan
    /// entry follows at revision 3, and every entry accepted since follows
    /// that. A `changes` read answers the same accepted revision, which is
    /// what a healthy wallet with nothing new actually returns.
    private func replica() -> Data {
        let (rule, revision, balance, loan, accepted) = lock.withLock {
            (allowance?.json ?? "null", self.revision, balanceCents, self.loan, acceptedEntries)
        }
        let loanEntries = loan.map { [$0.entryJSON] } ?? []
        let laterEntries = (loanEntries + accepted).map { ",\n           " + $0 }.joined()
        return Data("""
        {"household":{"lineageId":"\(lineageID.uuidString.lowercased())","authority":"cloud","revision":\(revision)},
         "family":{"id":"f-1","name":"Eddie's family"},
         "child":{"id":"c-1","nickname":"Eddie","avatarUrl":null},
         "wallet":{"id":"w-1","balanceCents":\(balance)},
         "entries":[
           {"id":"c1111111-1111-4111-8111-111111111111","type":"deposit","direction":"credit","amountCents":1000,"balanceBeforeCents":0,"balanceAfterCents":1000,"reason":"chores","loanId":null,"recordedAt":"2026-07-24T10:00:00.000Z","acceptedRevision":1},
           {"id":"c2222222-2222-4222-8222-222222222222","type":"withdrawal","direction":"debit","amountCents":250,"balanceBeforeCents":1000,"balanceAfterCents":750,"reason":"sticker book","loanId":null,"recordedAt":"2026-07-25T10:00:00.000Z","acceptedRevision":2}\(laterEntries)],
         "loans":[\(loan?.json ?? "")],"allowanceRule":\(rule),"nextCursor":null}
        """.utf8)
    }
}

/// The one open loan a synthetic Cloud household may carry: US$5.00 for a
/// bike helmet, handed over after the fixed history, with no payment plan.
struct SyntheticLoan {
    let id: String
    let principalCents: Int
    var outstandingCents: Int
    var paidAt: Date?

    static let sample = SyntheticLoan(
        id: "d1111111-1111-4111-8111-111111111111",
        principalCents: 500,
        outstandingCents: 500,
        paidAt: nil
    )

    var json: String {
        let status = outstandingCents == 0 ? "paid" : "open"
        let paid = paidAt.map { "\"\(CloudImportManifest.timestamp($0))\"" } ?? "null"
        return "{\"id\":\"\(id)\",\"principalCents\":\(principalCents),\"outstandingCents\":\(outstandingCents),\"purpose\":\"Bike helmet\",\"dueDate\":null,\"status\":\"\(status)\",\"createdAt\":\"2026-07-26T10:00:00.000Z\",\"paidAt\":\(paid),\"schedule\":null}"
    }

    /// The parent's loan entry, accepted at revision 3 on top of the US$7.50
    /// the fixed history leaves.
    var entryJSON: String {
        "{\"id\":\"c3333333-3333-4333-8333-333333333333\",\"type\":\"loan\",\"direction\":\"credit\",\"amountCents\":\(principalCents),\"balanceBeforeCents\":750,\"balanceAfterCents\":\(750 + principalCents),\"reason\":\"Bike helmet\",\"loanId\":\"\(id)\",\"recordedAt\":\"2026-07-26T10:00:00.000Z\",\"acceptedRevision\":3,\"recordedBy\":\"parent\"}"
    }
}

/// The one weekly allowance rule a synthetic Cloud household may carry, kept
/// the way the service keeps it: `startDate` is a creation-time fact, the
/// amount, weekday and end date may change, and the scheduled head is the
/// next payout day on or after today.
struct SyntheticAllowanceRule {
    let amountCents: Int
    let weekday: Int
    let startDate: String
    let endDate: String?
    let nextDueDate: String

    init(amountCents: Int, weekday: Int, startDate: String, endDate: String?, calendar: Calendar) {
        self.amountCents = amountCents
        self.weekday = weekday
        self.startDate = startDate
        self.endDate = endDate
        let today = calendar.startOfDay(for: .now)
        let start = CloudDayFormat.date(from: startDate, calendar: calendar) ?? today
        let next = Self.nextWeeklyDate(onOrAfter: max(start, today), weekday: weekday, calendar: calendar)
        self.nextDueDate = CloudDayFormat.string(from: next, calendar: calendar)
    }

    /// US$10.00 every Friday, started six Fridays before the coming one, so
    /// the editor opens on a live plan whose start date is already behind it.
    static func sample(calendar: Calendar = .current) -> SyntheticAllowanceRule {
        let today = calendar.startOfDay(for: .now)
        let next = nextWeeklyDate(onOrAfter: today, weekday: 5, calendar: calendar)
        let start = calendar.date(byAdding: .day, value: -42, to: next) ?? next
        return SyntheticAllowanceRule(
            amountCents: 1_000,
            weekday: 5,
            startDate: CloudDayFormat.string(from: start, calendar: calendar),
            endDate: nil,
            calendar: calendar
        )
    }

    /// Weekday 0 is Sunday, as the service counts it; `Calendar` counts from 1.
    static func nextWeeklyDate(onOrAfter date: Date, weekday: Int, calendar: Calendar) -> Date {
        let current = calendar.component(.weekday, from: date) - 1
        let delta = (weekday - current + 7) % 7
        return calendar.date(byAdding: .day, value: delta, to: date) ?? date
    }

    var json: String {
        let end = endDate.map { "\"\($0)\"" } ?? "null"
        return "{\"id\":\"synthetic-allowance\",\"amountCents\":\(amountCents),\"cadence\":\"weekly\",\"weekday\":\(weekday),\"startDate\":\"\(startDate)\",\"endDate\":\(end),\"active\":true,\"nextOccurrenceId\":\"synthetic-allowance-head\",\"nextDueDate\":\"\(nextDueDate)\"}"
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
    case allowanceAdvanced
    case allowanceAcceptedScheduleUnavailable
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
    private var confirmedAllowance: AllowancePlan?

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
        self.confirmedAllowance = nil
    }

    var isAuthenticated: Bool { true }
    var hasConfiguredKid: Bool { inner.hasConfiguredKid && !requiresSetup }
    func snapshot() -> WalletSnapshot { applyingConfirmedAllowance(to: inner.snapshot()) }
    func childSnapshot() -> WalletSnapshot { applyingConfirmedAllowance(to: inner.childSnapshot()) }

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
        return applyingConfirmedAllowance(to: try await inner.refresh(for: role))
    }

    func activity(limit: Int) async throws -> [WalletEvent] { try await inner.activity(limit: limit) }
    func activityDetail(remoteID: String) async throws -> WalletEvent { try await inner.activityDetail(remoteID: remoteID) }
    func loanDetail(remoteID: String) async throws -> LoanDetail { try await inner.loanDetail(remoteID: remoteID) }

    func submit(_ command: WalletCommand) async throws -> CommandResult {
        if let refreshError { throw refreshError }
        switch mutationMode {
        case .normal, .profileAcceptedWaiting, .allowanceAdvanced, .allowanceAcceptedScheduleUnavailable, .rejectedCleanup:
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
        if mutationMode == .waiting {
            throw WalletAPIError.cloudMutationAwaitingReconciliation
        }
        if mutationMode == .allowanceAcceptedScheduleUnavailable {
            let refreshed = try await inner.setAllowance(command)
            if let plan = refreshed.allowance {
                confirmedAllowance = try AllowancePlan(
                    remoteID: "debug-submitted-allowance-rule",
                    amountCents: plan.amountCents,
                    cadence: plan.cadence,
                    weekday: plan.weekday,
                    nextDate: plan.nextDate,
                    endDate: plan.endDate,
                    nextOccurrenceID: plan.nextOccurrenceID,
                    syncState: plan.syncState,
                    isExhausted: plan.isExhausted,
                    occurrences: plan.occurrences
                )
            }
            throw WalletAPIError.cloudAcceptedScheduleUnavailable
        }
        if mutationMode == .allowanceAdvanced {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
        var refreshed = try await inner.setAllowance(command)
        if mutationMode == .allowanceAdvanced, let plan = refreshed.allowance {
            let nextDate = Calendar(identifier: .gregorian).date(byAdding: .day, value: 7, to: plan.nextDate) ?? plan.nextDate
            let advancedPlan = try AllowancePlan(
                remoteID: "debug-submitted-allowance-rule",
                amountCents: plan.amountCents,
                cadence: plan.cadence,
                weekday: plan.weekday,
                nextDate: nextDate,
                endDate: plan.endDate,
                nextOccurrenceID: plan.nextOccurrenceID,
                syncState: plan.syncState
            )
            confirmedAllowance = advancedPlan
            refreshed.allowance = advancedPlan
        }
        return refreshed
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

    private func applyingConfirmedAllowance(to snapshot: WalletSnapshot) -> WalletSnapshot {
        guard let confirmedAllowance else { return snapshot }
        var snapshot = snapshot
        snapshot.allowance = confirmedAllowance
        return snapshot
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
