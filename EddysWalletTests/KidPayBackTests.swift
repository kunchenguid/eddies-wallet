import XCTest
@testable import EddysWallet

/// The kid's own loan payment (EDW-22, built by EDW-24). The captain's words:
/// "my son asked for the ability for the kid to pay back loan without
/// requiring parents." His answers fix the rules these tests hold: any amount
/// up to what is left and what is in the wallet, planned payments keep
/// coming, no undo, no parent switch, and the payment reads as the kid's on
/// free and Cloud wallets alike.
@MainActor
final class KidPayBackTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("KidPayBackTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Free wallet

    func testFreeWalletRecordsTheKidsPaymentAsTheKidsAndKeepsIt() async throws {
        let local = try await freeWalletWithLoan()
        let store = kidStore(repository: local)
        await waitUntil("the kid home to offer Pay back") { store.canKidPayBackLoan }
        XCTAssertEqual(store.kidPayBackLimitCents, 1_000, "what is left, because the wallet holds more")

        let outcome = await store.payBackLoan(amountCents: 300)

        XCTAssertEqual(outcome, .paid(amountCents: 300, remainingCents: 700))
        XCTAssertEqual(KidCopy.payBackResult(outcome), "You paid back US$3.00. US$7.00 left.")
        XCTAssertEqual(store.snapshot.acceptedBalanceCents, 2_300)
        XCTAssertEqual(store.snapshot.loan?.remainingCents, 700)
        XCTAssertEqual(store.elevation, .none, "paying back never opens the Parent area")

        // A relaunch reads the same history: the payment stays the kid's.
        let reopened = try LocalWalletRepository(directory: try walletDirectory("free"))
        let payment = try XCTUnwrap(reopened.snapshot().activities.first)
        XCTAssertEqual(payment.type, .repayment)
        XCTAssertEqual(payment.amountCents, 300)
        XCTAssertEqual(payment.syncState, .recorded)
        XCTAssertEqual(payment.recordedBy, "child")
        XCTAssertEqual(payment.explanation, "You paid US$3.00 toward your loan.")
        XCTAssertEqual(reopened.snapshot().loan?.remainingCents, 700)
    }

    func testKidCanPayAtMostWhatIsLeftAndWhatIsInTheWallet() async throws {
        let local = try await freeWalletWithLoan(depositCents: 0, loanCents: 1_000, usedCents: 750)
        let store = kidStore(repository: local)
        await waitUntil("the kid home to offer Pay back") { store.canKidPayBackLoan }
        XCTAssertEqual(store.kidPayBackLimitCents, 250, "the wallet holds less than what is left")

        let tooMuch = await store.payBackLoan(amountCents: 251)
        XCTAssertEqual(tooMuch, .notPaid)
        let nothing = await store.payBackLoan(amountCents: 0)
        XCTAssertEqual(nothing, .notPaid)
        XCTAssertEqual(local.snapshot().acceptedBalanceCents, 250, "a refused amount changes nothing")
        XCTAssertFalse(local.snapshot().activities.contains { $0.type == .repayment })

        let all = await store.payBackLoan(amountCents: 250)
        XCTAssertEqual(all, .paid(amountCents: 250, remainingCents: 750))
        XCTAssertEqual(store.snapshot.acceptedBalanceCents, 0)
        XCTAssertFalse(store.canKidPayBackLoan, "an empty wallet hides Pay back")
    }

    func testClearingTheLoanHidesPayBack() async throws {
        let store = kidStore(repository: try await freeWalletWithLoan())
        await waitUntil("the kid home to offer Pay back") { store.canKidPayBackLoan }

        let outcome = await store.payBackLoan(amountCents: 1_000)

        XCTAssertEqual(outcome, .paid(amountCents: 1_000, remainingCents: 0))
        XCTAssertEqual(KidCopy.payBackResult(outcome), "You paid back your whole loan.")
        XCTAssertEqual(store.snapshot.loan?.isPaid, true)
        XCTAssertFalse(store.canKidPayBackLoan)
        XCTAssertEqual(store.kidPayBackLimitCents, 0)
    }

    // MARK: - Who can pay, and with what

    func testPayBackIsOfferedOnlyOnTheKidHome() async throws {
        let store = kidStore(repository: try await freeWalletWithLoan())
        await waitUntil("the kid home to offer Pay back") { store.canKidPayBackLoan }

        store.openParentGate()
        XCTAssertEqual(store.elevation, .gate)
        XCTAssertFalse(store.canKidPayBackLoan, "the PIN pad is not the kid home")
        for digit in "1234" { store.appendPINDigit(String(digit)) }
        XCTAssertEqual(store.elevation, .active)
        XCTAssertFalse(store.canKidPayBackLoan, "the Parent area keeps its own Pay toward loan")
        let fromParentArea = await store.payBackLoan(amountCents: 100)
        XCTAssertEqual(fromParentArea, .notPaid)
    }

    func testPayBackNeedsAnOpenLoanAndDollarsInTheWallet() async throws {
        let noLoan = try LocalWalletRepository(directory: try walletDirectory("no-loan"))
        _ = try await noLoan.setup(ParentSetup(nickname: "Eddie"))
        _ = try await noLoan.submit(WalletCommand(kind: .deposit, amountCents: 2_000, reason: "Birthday"))
        let noLoanStore = kidStore(repository: noLoan)
        await waitUntil("the kid home to read the wallet") { noLoanStore.snapshot.acceptedBalanceCents == 2_000 }
        XCTAssertFalse(noLoanStore.canKidPayBackLoan, "no loan, nothing to pay back")

        let emptyWallet = try await freeWalletWithLoan(in: "empty", depositCents: 0, loanCents: 1_000, usedCents: 1_000)
        let emptyStore = kidStore(repository: emptyWallet)
        await waitUntil("the kid home to read the loan") { emptyStore.snapshot.loan != nil }
        XCTAssertFalse(emptyStore.canKidPayBackLoan, "no dollars, nothing to pay with")
    }

    func testOnlyAuthoritiesThatKeepTheKidsLabelOfferPayBack() async throws {
        XCTAssertFalse(try LocalWalletRepository(inMemory: true).supportsChildRepayment, "a wallet that is not set up has nothing to pay")
        let free = try await freeWalletWithLoan()
        XCTAssertTrue(free.supportsChildRepayment)
        // The legacy service has no kid label, so it would record the payment
        // as the parent's. Its reads go nowhere: no stub answers them.
        let legacy = APIWalletRepository(
            baseURL: URL(string: "https://api.example.test")!,
            sessionStore: InMemorySessionStore(session: AuthSession(token: "synthetic-session", expiresAt: .distantFuture)),
            transport: RoutingTransport(),
            cache: InMemoryWalletSnapshotCache(snapshot: .fixture()),
            configuredKidStore: InMemoryConfiguredKidStore(isConfigured: true),
            pendingStore: InMemoryPendingCommandStore()
        )
        XCTAssertFalse(legacy.supportsChildRepayment)
        let legacyStore = kidStore(repository: legacy)
        XCTAssertNotNil(legacyStore.snapshot.loan)
        XCTAssertGreaterThan(legacyStore.snapshot.acceptedBalanceCents, 0)
        XCTAssertFalse(legacyStore.canKidPayBackLoan)
    }

    func testKidLabelIsRefusedOnAnythingButALoanPayment() async throws {
        let local = try await freeWalletWithLoan()
        let labelledDeposit = WalletCommand(kind: .deposit, amountCents: 100, recordedBy: "child")
        guard case .rejected = try await local.submit(labelledDeposit) else {
            return XCTFail("a free wallet must not record a kid-labelled deposit")
        }
        XCTAssertEqual(local.snapshot().acceptedBalanceCents, 2_600)

        // The parent's own path still needs the Parent area, kid label or not.
        let store = kidStore(repository: local)
        guard case .rejected = await store.submit(.childRepayment(amountCents: 100)) else {
            return XCTFail("submit must keep requiring parent elevation")
        }
        XCTAssertEqual(local.snapshot().acceptedBalanceCents, 2_600)
    }

    // MARK: - Amount rules

    func testAmountStartsAtTheNextPlannedPaymentAndMovesInWholeDollars() throws {
        let planned = try XCTUnwrap(DebugLaunchScenario.localLoanSnapshot(withPlan: true).loan)
        let unplanned = try XCTUnwrap(DebugLaunchScenario.localLoanSnapshot(withPlan: false).loan)
        XCTAssertEqual(KidPayBackAmount.starting(for: planned, limitCents: 1_000), 200, "the next planned payment")
        XCTAssertEqual(KidPayBackAmount.starting(for: unplanned, limitCents: 1_000), 100, "US$1.00 without a plan")
        XCTAssertEqual(KidPayBackAmount.starting(for: planned, limitCents: 150), 150, "never more than the limit")

        XCTAssertEqual(KidPayBackAmount.more(than: 200, limitCents: 1_000), 300)
        XCTAssertEqual(KidPayBackAmount.more(than: 950, limitCents: 1_000), 1_000, "+ stops at the limit")
        XCTAssertEqual(KidPayBackAmount.less(than: 300, limitCents: 1_000), 200)
        XCTAssertEqual(KidPayBackAmount.less(than: 150, limitCents: 1_000), 100, "- stops at US$1.00")
        XCTAssertFalse(KidPayBackAmount.canLower(100, limitCents: 1_000))
        XCTAssertEqual(KidPayBackAmount.less(than: 75, limitCents: 75), 75, "a limit under US$1.00 is the whole amount")
        XCTAssertFalse(KidPayBackAmount.canLower(75, limitCents: 75))
        XCTAssertEqual(KidPayBackAmount.clamped(300, limitCents: 0), 0)
    }

    // MARK: - Words

    func testEachAudienceReadsWhoPaid() {
        let kidPayment = WalletEvent(
            type: .repayment,
            amountCents: 300,
            recordedBy: "child",
            explanation: AcceptedEventCopy.explanation(for: .repayment, amountCents: 300, recordedBy: "child")
        )
        XCTAssertTrue(ActivityDetailCopy.attribution(for: kidPayment, audience: .kid, childNickname: "Eddie") == ("Changed by", "You"))
        XCTAssertEqual(ActivityDetailCopy.explanation(for: kidPayment, audience: .kid, childNickname: "Eddie"), "You paid US$3.00 toward your loan.")
        XCTAssertTrue(ActivityDetailCopy.attribution(for: kidPayment, audience: .parent, childNickname: "Eddie") == ("Recorded by", "Eddie"))
        XCTAssertEqual(ActivityDetailCopy.explanation(for: kidPayment, audience: .parent, childNickname: "Eddie"), "Eddie paid US$3.00 toward the loan.")
        XCTAssertTrue(ActivityDetailCopy.attribution(for: kidPayment, audience: .parent, childNickname: nil) == ("Recorded by", "Your child"))
        XCTAssertEqual(ActivityDetailCopy.explanation(for: kidPayment, audience: .parent, childNickname: nil), "Your child paid US$3.00 toward the loan.")

        // A parent's payment still reads as the parent's.
        let parentPayment = WalletEvent(type: .repayment, amountCents: 300, recordedBy: "parent", explanation: "")
        XCTAssertTrue(ActivityDetailCopy.attribution(for: parentPayment, audience: .kid) == ("Changed by", "Your parent"))
        XCTAssertEqual(ActivityDetailCopy.explanation(for: parentPayment, audience: .kid), "Your parent paid US$3.00 toward your loan.")
        XCTAssertTrue(ActivityDetailCopy.attribution(for: parentPayment, audience: .parent) == ("Recorded by", "Parent"))
    }

    func testKidPayBackWordsNeverClaimAConnectionState() throws {
        let outcomes: [KidPayBackOutcome] = [
            .paid(amountCents: 300, remainingCents: 700),
            .paid(amountCents: 700, remainingCents: 0),
            .checking,
            .walletChanged,
            .notPaid,
        ]
        let loan = try XCTUnwrap(DebugLaunchScenario.localLoanSnapshot(withPlan: true).loan)
        let nextPayment = try XCTUnwrap(loan.schedule?.nextDueDate)
        let note = KidCopy.payBackPlanNote(nextPaymentDate: nextPayment, cadence: .weekly)
        XCTAssertEqual(
            note,
            "Your \(nextPayment.formatted(.dateTime.weekday(.wide))) payment still happens. Paying extra means you finish sooner."
        )
        for words in outcomes.map(KidCopy.payBackResult) + [note] {
            for claim in ["sync", "offline", "online", "cloud", "review", "connection", "internet"] {
                XCTAssertFalse(words.lowercased().contains(claim), "\"\(words)\" must not mention \(claim)")
            }
        }
    }

    // MARK: - Moving to Cloud

    func testMovingToCloudCarriesTheKidLabelOnTheKidsPaymentOnly() async throws {
        let local = try await freeWalletWithLoan()
        _ = try await local.submit(WalletCommand(kind: .repayment, amountCents: 200))
        _ = try await local.submit(.childRepayment(amountCents: 300))

        let manifest = try CloudImportManifestBuilder.manifest(
            lineageID: UUID(),
            operationID: UUID(),
            familyName: "Eddie's family",
            nickname: "Eddie",
            snapshot: local.snapshot()
        )

        XCTAssertEqual(manifest.entries.map(\.type), ["deposit", "loan", "withdrawal", "repayment", "repayment"])
        XCTAssertEqual(manifest.entries.map(\.recordedBy), [nil, nil, nil, nil, "child"])
        guard case .object(let aggregate) = manifest.canonicalAggregate,
              case .array(let entries)? = aggregate.first(where: { $0.0 == "entries" })?.1,
              case .object(let kidEntry) = entries.last,
              case .object(let parentEntry) = entries[3] else {
            return XCTFail("the aggregate must carry its entries")
        }
        XCTAssertEqual(kidEntry.suffix(2).map { $0.0 }, ["recordedAt", "recordedBy"], "the label follows recordedAt, as the service hashes it")
        XCTAssertEqual(kidEntry.last?.1, .string("child"))
        XCTAssertFalse(parentEntry.contains { $0.0 == "recordedBy" }, "an unlabelled entry hashes as it always did")
    }

    // MARK: - Cloud

    #if DEBUG
    func testCloudRecordsTheKidsPaymentWithTheKidLabel() async throws {
        let (store, _, service) = try cloudKidStore()
        await waitUntilReadSettles(store)
        XCTAssertTrue(store.canKidPayBackLoan, "a Cloud wallet in sync offers Pay back")
        XCTAssertEqual(store.kidPayBackLimitCents, 500)

        let first = await store.payBackLoan(amountCents: 100)

        XCTAssertEqual(first, .paid(amountCents: 100, remainingCents: 400))
        XCTAssertEqual(service.receivedRepayments.last?["recordedBy"] as? String, "child")
        XCTAssertEqual(service.receivedRepayments.last?["amountCents"] as? Int, 100)
        XCTAssertEqual(store.snapshot.acceptedBalanceCents, 1_150)
        let entry = try XCTUnwrap(store.snapshot.activities.first)
        XCTAssertEqual(entry.type, .repayment)
        XCTAssertEqual(entry.recordedBy, "child", "the accepted entry the service returned keeps the kid label")
        XCTAssertFalse(store.needsCloudReview)

        XCTAssertTrue(store.canKidPayBackLoan, "the accepted write leaves the wallet in sync")
        let rest = await store.payBackLoan(amountCents: store.kidPayBackLimitCents)
        XCTAssertEqual(rest, .paid(amountCents: 400, remainingCents: 0))
        XCTAssertEqual(store.snapshot.loan?.isPaid, true)
        XCTAssertFalse(store.canKidPayBackLoan, "a paid loan hides Pay back")
    }

    func testCloudConflictReadsTheWalletAgainWithoutAParentReview() async throws {
        let (store, _, service) = try cloudKidStore(repaymentConflicts: 1)
        await waitUntilReadSettles(store)
        XCTAssertTrue(store.canKidPayBackLoan)

        let conflicted = await store.payBackLoan(amountCents: 100)

        XCTAssertEqual(conflicted, .walletChanged)
        XCTAssertFalse(store.needsCloudReview, "nothing was recorded, so there is nothing for a parent to review")
        XCTAssertEqual(store.snapshot.acceptedBalanceCents, 1_350, "the kid sees the other device's deposit")
        XCTAssertFalse(store.snapshot.activities.contains { $0.type == .repayment })

        XCTAssertTrue(store.canKidPayBackLoan, "the fresh read puts the wallet back in sync")
        let retried = await store.payBackLoan(amountCents: 100)
        XCTAssertEqual(retried, .paid(amountCents: 100, remainingCents: 400))
        XCTAssertEqual(service.receivedRepayments.count, 2)
        XCTAssertEqual(store.snapshot.acceptedBalanceCents, 1_250)
    }

    func testLostCloudAnswerWaitsAsTheKidsPaymentAndReplaysExactlyOnce() async throws {
        let replicaDirectory = directory.appendingPathComponent("replica")
        let (store, cloud, service) = try cloudKidStore(losesFirstRepaymentAnswer: true, replicaDirectory: replicaDirectory)
        await waitUntilReadSettles(store)
        XCTAssertTrue(store.canKidPayBackLoan)

        let outcome = await store.payBackLoan(amountCents: 100)

        XCTAssertEqual(outcome, .checking)
        XCTAssertEqual(KidCopy.payBackResult(outcome), "Still checking on your payment.")
        XCTAssertFalse(store.canKidPayBackLoan, "one unresolved payment at a time")
        // The parent's Waiting to sync row names the kid, and so does the
        // stored request a relaunch would replay.
        let waiting = try XCTUnwrap(cloud.snapshot().pendingEvents.first)
        XCTAssertEqual(waiting.recordedBy, "child")
        XCTAssertTrue(ActivityDetailCopy.attribution(for: waiting, audience: .parent, childNickname: "Eddie") == ("Recorded by", "Eddie"))
        XCTAssertEqual(try LocalWalletRepository(directory: replicaDirectory).unsettledCloudMutation?.recordedBy, "child")

        await store.refresh()
        await waitUntilReadSettles(store)

        let bodies = service.receivedRepayments
        XCTAssertEqual(bodies.count, 2, "the one unresolved request is replayed, not a new one")
        XCTAssertEqual(bodies.map { $0["recordedBy"] as? String }, ["child", "child"])
        XCTAssertEqual(bodies.map { $0["amountCents"] as? Int }, [100, 100])
        XCTAssertFalse(cloud.hasUnsettledMutation)
        XCTAssertEqual(store.snapshot.acceptedBalanceCents, 1_150)
        XCTAssertEqual(store.snapshot.activities.filter { $0.type == .repayment }.map(\.recordedBy), ["child"])
        XCTAssertTrue(store.canKidPayBackLoan)
    }

    func testAStoredChangeFromBeforeKidLabelsStillReads() throws {
        let kidPayment = PendingCloudMutation(
            kind: .repayment,
            method: "POST",
            path: "/v1/loans/d1111111-1111-4111-8111-111111111111/repayments",
            body: Data("{\"amountCents\":100,\"recordedBy\":\"child\"}".utf8),
            idempotencyKey: "kid-key",
            expectedRevision: 3,
            amountCents: 100,
            recordedBy: "child"
        )
        let encoded = try JSONEncoder().encode(kidPayment)
        XCTAssertEqual(try JSONDecoder().decode(PendingCloudMutation.self, from: encoded).recordedBy, "child")

        var older = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        older.removeValue(forKey: "recordedBy")
        let decoded = try JSONDecoder().decode(PendingCloudMutation.self, from: JSONSerialization.data(withJSONObject: older))
        XCTAssertNil(decoded.recordedBy)
        XCTAssertEqual(decoded.idempotencyKey, "kid-key")
    }
    #endif

    // MARK: - Helpers

    /// A real free wallet with history: a deposit, a US$10.00 loan, then some
    /// of the money used. Its defaults leave US$26.00 with US$10.00 to repay.
    private func freeWalletWithLoan(
        in folder: String = "free",
        depositCents: Int = 2_000,
        loanCents: Int = 1_000,
        usedCents: Int = 400
    ) async throws -> LocalWalletRepository {
        let local = try LocalWalletRepository(directory: try walletDirectory(folder))
        _ = try await local.setup(ParentSetup(nickname: "Eddie"))
        if depositCents > 0 {
            _ = try await local.submit(WalletCommand(kind: .deposit, amountCents: depositCents, reason: "Birthday"))
        }
        _ = try await local.submit(WalletCommand(kind: .loan, amountCents: loanCents, reason: "Bike helmet"))
        _ = try await local.submit(WalletCommand(kind: .withdrawal, amountCents: usedCents, reason: "Comic book"))
        return local
    }

    private func walletDirectory(_ folder: String) throws -> URL {
        let url = directory.appendingPathComponent(folder, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// The kid home's own store: signed in and never elevated.
    private func kidStore(repository: any WalletRepository) -> WalletStore {
        WalletStore(
            repository: repository,
            initiallySignedIn: true,
            pinStore: InMemoryParentPINStore(pin: "1234"),
            identityStore: InMemoryParentIdentityStore(appleUserID: "synthetic-parent")
        )
    }

    #if DEBUG
    /// The `cloud-live-parent` composition with its US$5.00 loan: the real
    /// `CloudWalletRepository` over the in-process synthetic service, seen
    /// from the kid home. The service is returned so a test can read the
    /// bodies it was sent.
    private func cloudKidStore(
        repaymentConflicts: Int = 0,
        losesFirstRepaymentAnswer: Bool = false,
        replicaDirectory: URL? = nil
    ) throws -> (WalletStore, CloudWalletRepository, SyntheticCloudTransport) {
        let lineage = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
        let service = SyntheticCloudTransport(lineageID: lineage, readDelay: 0, loan: .sample, repaymentConflicts: repaymentConflicts)
        let transport: any HTTPTransport = losesFirstRepaymentAnswer ? FirstRepaymentAnswerLosingTransport(service) : service
        let replica = try replicaDirectory.map { try LocalWalletRepository(directory: $0) } ?? LocalWalletRepository(inMemory: true)
        let cloud = CloudWalletRepository(
            client: CloudAPIClient(
                baseURL: SyntheticCloudTransport.baseURL,
                sessionStore: InMemorySessionStore(session: AuthSession(token: "synthetic-session", expiresAt: .distantFuture)),
                transport: transport
            ),
            replica: replica,
            lineageID: lineage,
            revision: 0,
            requiresBootstrap: true
        )
        let store = kidStore(repository: cloud)
        store.applyDebugCloudState(
            authority: .cloud(lineageID: lineage, revision: 2),
            entitlement: .active(accessUntil: .distantFuture, autoRenewEnabled: true)
        )
        return (store, cloud, service)
    }
    #endif

    /// Waits out every read the store has started - its launch read included
    /// - so what it publishes is the repository's settled state.
    private func waitUntilReadSettles(_ store: WalletStore) async {
        await waitUntil("the kid home's read to settle") { !store.isLoading && store.snapshot.loan != nil }
    }

    private func waitUntil(_ description: String, condition: @escaping @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(5)
        while !condition() {
            if Date() > deadline {
                XCTFail("timed out waiting for \(description)")
                return
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

#if DEBUG
/// Passes every request to the synthetic service, but loses the answer to the
/// first loan payment after the service committed it: the payment happened
/// and this device did not hear so. Thread-safe, because the app reaches a
/// transport from several threads at once.
private final class FirstRepaymentAnswerLosingTransport: HTTPTransport, @unchecked Sendable {
    private let service: SyntheticCloudTransport
    private let lock = NSLock()
    private var hasLostAnswer = false

    init(_ service: SyntheticCloudTransport) {
        self.service = service
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let answer = try await service.data(for: request)
        let losesThisAnswer = lock.withLock { () -> Bool in
            guard !hasLostAnswer,
                  request.httpMethod == "POST",
                  request.url?.path.hasSuffix("/repayments") == true else { return false }
            hasLostAnswer = true
            return true
        }
        if losesThisAnswer { throw URLError(.networkConnectionLost) }
        return answer
    }
}
#endif
