import XCTest
@testable import EddysWallet

/// The child home's refresh contract. Reads overlap by design - the store's
/// own launch read, the kid home's `.task`, returning from the Parent area,
/// coming back to the foreground, and every pull-to-refresh - so what the kid
/// sees must be the newest observation, never whichever request finished last.
///
/// All fixtures here are synthetic and redacted: nickname "Eddie", round
/// amounts, no account, family, or service data of any kind.
@MainActor
final class ChildHomeRefreshTests: XCTestCase {
    private let cachedBalanceCents = 2_400
    private let freshBalanceCents = 3_675

    // MARK: - Reported defect

    /// Reproduces the reported defect. The read issued at launch stalls; a read
    /// issued after it succeeds and publishes the current wallet. When the
    /// stalled read finally fails it must change nothing - the session is
    /// demonstrably online, and the wallet on screen was fetched, not cached.
    func testStalledLaunchReadNeverRelabelsANewerSuccessfulReadAsOffline() async {
        let repository = OrderedReadRepository(published: cachedSnapshot())
        let store = makeStore(repository)

        await expect("the store reads the wallet at launch") { repository.startedReads == 1 }

        let pull = Task { await store.refresh() }
        await expect("pull-to-refresh issues its own read") { repository.startedReads == 2 }
        repository.finish(read: 2, with: freshSnapshot())
        await pull.value

        XCTAssertEqual(store.snapshot.acceptedBalanceCents, freshBalanceCents)
        XCTAssertEqual(store.connection, .reached)

        repository.fail(read: 1, with: unreachableAuthority())

        let relabelled = await waitUntil { !store.connection.reachedAuthority || store.errorMessage != nil }
        XCTAssertFalse(relabelled, "a stalled older read must not relabel a newer, successful read as offline")
        XCTAssertEqual(store.snapshot.acceptedBalanceCents, freshBalanceCents)
        XCTAssertFalse(store.snapshot.isStale)
    }

    func testOlderFailureCannotPublishWhileNewerReadIsInFlight() async {
        let repository = OrderedReadRepository(published: cachedSnapshot())
        let store = makeStore(repository)

        await expect("the store reads the wallet at launch") { repository.startedReads == 1 }
        let pull = Task { await store.refresh() }
        await expect("pull-to-refresh issues its own read") { repository.startedReads == 2 }

        repository.fail(read: 1, with: unreachableAuthority())

        let relabelled = await waitUntil(timeout: 0.5) { !store.connection.reachedAuthority || store.errorMessage != nil }
        XCTAssertFalse(relabelled, "an older failure must not publish while a newer read is still in flight")
        XCTAssertTrue(store.isLoading)

        repository.finish(read: 2, with: freshSnapshot())
        await pull.value
        XCTAssertEqual(store.snapshot.acceptedBalanceCents, freshBalanceCents)
        XCTAssertEqual(store.connection, .reached)
    }

    /// The reverse case, so the rule above cannot be satisfied by simply
    /// ignoring failures: when the *newest* read is the one that fails, the kid
    /// home is genuinely out of touch with its authority and must say so.
    func testNewestFailedReadStillReportsOfflineOverAnOlderSuccess() async {
        let repository = OrderedReadRepository(published: cachedSnapshot())
        let store = makeStore(repository)

        await expect("the store reads the wallet at launch") { repository.startedReads == 1 }
        let pull = Task { await store.refresh() }
        await expect("a second read is issued while the first is still in flight") { repository.startedReads == 2 }

        repository.finish(read: 1, with: freshSnapshot())
        let publishedOlderRead = await waitUntil(timeout: 0.5) {
            store.snapshot.acceptedBalanceCents == self.freshBalanceCents
        }
        XCTAssertFalse(publishedOlderRead, "an older success must not publish while the newest read is in flight")

        repository.fail(read: 2, with: unreachableAuthority())
        await pull.value

        XCTAssertEqual(store.connection, .deviceOffline, "the newest read reported a device with no network, so the kid home is offline")
        XCTAssertNotNil(store.errorMessage)
    }

    func testRetiredChildUnauthorizedReadCannotDeElevateParentArea() async {
        let repository = OrderedReadRepository(published: cachedSnapshot())
        let store = makeStore(repository)

        await expect("the store reads the child wallet at launch") { repository.startedReads == 1 }
        store.openParentGate()
        for digit in "1234" {
            store.appendPINDigit(String(digit))
        }
        XCTAssertEqual(store.elevation, .active)
        await expect("entering the Parent area starts its own read") { repository.startedReads == 2 }
        XCTAssertEqual(repository.readRoles, [.child, .parent])

        repository.fail(read: 1, with: .unauthorized)

        let deElevated = await waitUntil(timeout: 0.5) { store.elevation != .active }
        XCTAssertFalse(deElevated, "a retired child result must not close the Parent area")
        XCTAssertFalse(store.sessionExpired)

        repository.finish(read: 2, with: freshSnapshot())
        await expect("the Parent read publishes normally") {
            store.snapshot.acceptedBalanceCents == self.freshBalanceCents
        }
        XCTAssertEqual(store.elevation, .active)
    }

    // MARK: - Pull-to-refresh

    /// Pull-to-refresh performs and awaits the authoritative read, applies what
    /// it returns, moves the visible freshness forward, and drops the offline
    /// presentation the earlier failure left behind.
    func testChildPullToRefreshAppliesFreshStateAndClearsTheOfflinePresentation() async {
        let repository = OrderedReadRepository(published: cachedSnapshot())
        let store = makeStore(repository)

        await expect("the store reads the wallet at launch") { repository.startedReads == 1 }
        repository.fail(read: 1, with: unreachableAuthority())
        await expect("a genuinely offline device reports offline") { store.connection == .deviceOffline }
        let staleTimestamp = store.snapshot.lastUpdated
        XCTAssertEqual(store.snapshot.acceptedBalanceCents, cachedBalanceCents)

        let pull = Task { await store.refresh() }
        await expect("pull-to-refresh must fetch, not re-show the cache") { repository.startedReads == 2 }
        XCTAssertEqual(repository.readRoles.last, .child, "the kid home reads the read-only child view")
        repository.finish(read: 2, with: freshSnapshot())
        await pull.value

        XCTAssertEqual(store.connection, .reached)
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(store.snapshot.acceptedBalanceCents, freshBalanceCents)
        XCTAssertFalse(store.snapshot.isStale)
        XCTAssertGreaterThan(store.snapshot.lastUpdated, staleTimestamp, "the visible freshness must move forward")
    }

    /// Local-first behaviour is preserved: a read that genuinely cannot reach
    /// its authority keeps the last accepted wallet on screen rather than
    /// blanking it, and says so.
    func testUnreachableAuthorityKeepsTheLastAcceptedWalletAndReportsOffline() async {
        let repository = OrderedReadRepository(published: cachedSnapshot())
        let store = makeStore(repository)

        await expect("the store reads the wallet at launch") { repository.startedReads == 1 }
        repository.fail(read: 1, with: unreachableAuthority())

        await expect("a genuinely offline device is reported as offline") { store.connection == .deviceOffline }
        XCTAssertEqual(store.snapshot.acceptedBalanceCents, cachedBalanceCents)
        XCTAssertFalse(store.sessionExpired)
    }

    // MARK: - Returning to the foreground

    /// Backgrounding retires every read in flight, so coming back has to issue
    /// a new one. Without it the kid home keeps whatever the retired attempt
    /// left behind - including a stale offline banner over an online session.
    func testReturningToTheForegroundReReadsTheRetiredWallet() async {
        let repository = OrderedReadRepository(published: cachedSnapshot())
        let store = makeStore(repository)

        await expect("the store reads the wallet at launch") { repository.startedReads == 1 }
        repository.fail(read: 1, with: unreachableAuthority())
        await expect("a genuinely offline device is reported as offline") { store.connection == .deviceOffline }

        store.handleAppBackgrounded()
        store.handleAppForegrounded()

        await expect("returning to the foreground re-reads the wallet") { repository.startedReads == 2 }
        repository.finish(read: 2, with: freshSnapshot())
        await expect("the re-read clears the offline presentation") { store.connection == .reached }
        XCTAssertEqual(store.snapshot.acceptedBalanceCents, freshBalanceCents)
    }

    /// Negative case: a foreground notification that does not follow a
    /// backgrounding is not a reason to re-read anything.
    func testForegroundWithoutBackgroundingIssuesNoRead() async {
        let repository = OrderedReadRepository(published: cachedSnapshot())
        let store = makeStore(repository)

        await expect("the store reads the wallet at launch") { repository.startedReads == 1 }
        repository.finish(read: 1, with: freshSnapshot())
        await expect("the successful read reaches published state") { store.snapshot.acceptedBalanceCents == self.freshBalanceCents }

        store.handleAppForegrounded()

        let issued = await waitUntil(timeout: 0.5) { repository.startedReads > 1 }
        XCTAssertFalse(issued, "no backgrounding happened, so nothing was retired and nothing needs re-reading")
    }

    // MARK: - Helpers

    private func makeStore(_ repository: any WalletRepository) -> WalletStore {
        WalletStore(
            repository: repository,
            initiallySignedIn: true,
            pinStore: InMemoryParentPINStore(pin: "1234"),
            identityStore: InMemoryParentIdentityStore(appleUserID: "synthetic-parent")
        )
    }

    /// A read that genuinely could not reach its authority, preserved the way
    /// a real transport failure is: the device itself reported no network.
    private func unreachableAuthority() -> WalletAPIError {
        .transportFailure(
            TransportDiagnostic.transportFailure(
                URLError(.notConnectedToInternet),
                path: "/v1/child-view",
                elapsedMilliseconds: 1
            )
        )
    }

    private func cachedSnapshot() -> WalletSnapshot {
        syntheticSnapshot(cents: cachedBalanceCents, lastUpdated: .now.addingTimeInterval(-3_600), isStale: true)
    }

    private func freshSnapshot() -> WalletSnapshot {
        syntheticSnapshot(cents: freshBalanceCents, lastUpdated: .now, isStale: false)
    }

    private func syntheticSnapshot(cents: Int, lastUpdated: Date, isStale: Bool) -> WalletSnapshot {
        WalletSnapshot(
            acceptedBalanceCents: cents,
            activities: [],
            loan: nil,
            allowance: nil,
            pendingEvents: [],
            lastUpdated: lastUpdated,
            isStale: isStale,
            childNickname: "Eddie"
        )
    }

    /// Waits for a main-actor condition and fails the test if it never holds.
    private func expect(
        _ description: String,
        timeout: TimeInterval = 3,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: () -> Bool
    ) async {
        let held = await waitUntil(timeout: timeout, condition)
        XCTAssertTrue(held, description, file: file, line: line)
    }

    /// Polls a main-actor condition, returning whether it held within `timeout`.
    private func waitUntil(timeout: TimeInterval = 3, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return condition()
    }
}

/// A wallet whose reads complete only when the test says so, in whatever order
/// the test chooses. Reads are numbered in the order they start, which is the
/// only thing the store may order its published state by.
@MainActor
private final class OrderedReadRepository: WalletRepository {
    private var inFlight: [Int: CheckedContinuation<WalletSnapshot, Error>] = [:]
    private(set) var startedReads = 0
    private(set) var readRoles: [UserRole] = []
    private var published: WalletSnapshot

    init(published: WalletSnapshot) {
        self.published = published
    }

    var isAuthenticated: Bool { true }
    var hasConfiguredKid: Bool { true }
    func snapshot() -> WalletSnapshot { published }
    func childSnapshot() -> WalletSnapshot { published }

    func refresh(for role: UserRole) async throws -> WalletSnapshot {
        startedReads += 1
        readRoles.append(role)
        let read = startedReads
        return try await withCheckedThrowingContinuation { continuation in
            inFlight[read] = continuation
        }
    }

    /// Completes a read the way an accepted server read does: the accepted
    /// wallet this device holds becomes what the read returned.
    func finish(read: Int, with snapshot: WalletSnapshot) {
        published = snapshot
        inFlight.removeValue(forKey: read)?.resume(returning: snapshot)
    }

    func fail(read: Int, with error: WalletAPIError) {
        inFlight.removeValue(forKey: read)?.resume(throwing: error)
    }

    func activity(limit _: Int) async throws -> [WalletEvent] { published.activities }
    func activityDetail(remoteID _: String) async throws -> WalletEvent {
        throw WalletAPIError.invalidResponse("Not used in these tests.")
    }
    func loanDetail(remoteID _: String) async throws -> LoanDetail {
        throw WalletAPIError.invalidResponse("Not used in these tests.")
    }
    func submit(_: WalletCommand) async throws -> CommandResult {
        throw WalletAPIError.invalidResponse("Not used in these tests.")
    }
    func setAllowance(_: AllowanceRuleCommand) async throws -> WalletSnapshot {
        throw WalletAPIError.invalidResponse("Not used in these tests.")
    }
    func setup(_: ParentSetup) async throws -> WalletSnapshot {
        throw WalletAPIError.invalidResponse("Not used in these tests.")
    }
    func updateChildProfile(_: ChildProfileUpdate) async throws -> WalletSnapshot {
        throw WalletAPIError.invalidResponse("Not used in these tests.")
    }
    func clearAuthentication() {}
    func clearSession() throws {}
}
