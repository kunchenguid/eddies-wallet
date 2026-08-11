import Foundation
import XCTest
@testable import EddysWallet

/// What the family is told when a wallet read fails, and what evidence of that
/// failure survives.
///
/// Every case drives a real thrown transport error through the real
/// `APIWalletRepository` and `WalletStore`, then asserts the state a person
/// would actually see - the kid home's status line, the parent-facing message,
/// and the parent-only connection readout. Nothing here inspects source text.
///
/// All fixtures are synthetic and redacted: a fake host, a synthetic session
/// token, nickname "Robin" - deliberately not the product's own brand word, so
/// a privacy assertion cannot pass by accident - round amounts, and no account
/// or service data.
@MainActor
final class TransportDiagnosticTests: XCTestCase {
    // MARK: - Honest classification

    /// The reported defect. A device that is demonstrably online could not
    /// reach the service, and the kid home said "You're offline".
    func testAnUnreachableServiceOnAnOnlineDeviceIsNeverCalledOffline() async {
        for thrown in [
            URLError(.timedOut),
            URLError(.secureConnectionFailed),
            URLError(.cannotConnectToHost),
            URLError(.cannotFindHost),
            URLError(.dnsLookupFailed),
            URLError(.networkConnectionLost),
        ] {
            let store = await makeSignedInStore(throwing: thrown)

            XCTAssertEqual(
                store.connection,
                .serviceUnreachable,
                "\(thrown.code) is a service this app could not reach, not a device without a network"
            )
            XCTAssertEqual(kidStatusMessage(store), KidCopy.cannotReachBanner(lastUpdated: store.snapshot.lastUpdated))
            XCTAssertNotEqual(kidStatusMessage(store), KidCopy.offlineBanner(lastUpdated: store.snapshot.lastUpdated))
            XCTAssertEqual(store.latestTransportDiagnostic?.code, thrown.errorCode)
        }
    }

    func testAGenuinelyOfflineDeviceStillReadsOffline() async {
        for thrown in [
            URLError(.notConnectedToInternet),
            URLError(.internationalRoamingOff),
            URLError(.dataNotAllowed),
        ] {
            let store = await makeSignedInStore(throwing: thrown)

            XCTAssertEqual(store.connection, .deviceOffline)
            XCTAssertEqual(kidStatusMessage(store), KidCopy.offlineBanner(lastUpdated: store.snapshot.lastUpdated))
        }
    }

    func testATimeoutPreservesItsExactCategoryAndCode() async {
        let store = await makeSignedInStore(throwing: URLError(.timedOut))

        let diagnostic = store.latestTransportDiagnostic
        XCTAssertEqual(diagnostic?.category, .timedOut)
        XCTAssertEqual(diagnostic?.code, -1_001)
        XCTAssertEqual(diagnostic?.route, "/v1/child-view")
        XCTAssertNil(diagnostic?.httpStatus, "no response arrived, so there is no status to claim")
        XCTAssertTrue(store.snapshot.isStale, "a read that never got an answer leaves the wallet on screen dated")
    }

    /// A cancellation observed no answer at all, so it may not claim anything
    /// about this family's connection - and above all must not read as offline.
    func testACancelledReadIsNeverPresentedAsOffline() async {
        for thrown in [URLError(.cancelled) as Error, CancellationError()] {
            let store = await makeSignedInStore(throwing: thrown)

            XCTAssertEqual(store.connection, .reached)
            XCTAssertNil(kidStatusMessage(store))
            XCTAssertNil(store.errorMessage)
            XCTAssertNil(store.latestTransportDiagnostic)
            XCTAssertFalse(store.snapshot.isStale, "a cancelled read saw nothing, so it cannot age the wallet either")
        }
    }

    func testAnUnderlyingErrorIsRecordedOnlyAsPresent() async {
        let underlying = NSError(domain: "kCFStreamErrorDomainSSL", code: -9_806)
        let thrown = URLError(
            .secureConnectionFailed,
            userInfo: [NSUnderlyingErrorKey: underlying]
        )
        let store = await makeSignedInStore(throwing: thrown)

        guard let diagnostic = store.latestTransportDiagnostic else {
            return XCTFail("the failure the transport reported was not preserved")
        }
        XCTAssertTrue(diagnostic.hasUnderlyingError)
        XCTAssertFalse(diagnostic.shareableSummary.contains("9806"))
        XCTAssertFalse(diagnostic.shareableSummary.contains("kCFStreamErrorDomainSSL"))
    }

    // MARK: - Answers that did arrive

    func testAnExpiredSessionStaysASessionProblemAndStillRecordsItsStatus() async {
        let store = await makeSignedInStore(responding: 401)

        XCTAssertTrue(store.sessionExpired)
        XCTAssertEqual(store.connection, .reached, "a 401 is an answer: the service was reached")
        XCTAssertEqual(kidStatusMessage(store), KidCopy.sessionBanner)
        XCTAssertEqual(store.latestTransportDiagnostic?.category, .httpStatus)
        XCTAssertEqual(store.latestTransportDiagnostic?.httpStatus, 401)
    }

    func testAnOrdinaryServerErrorReadsAsTroubleNotAsOffline() async {
        let store = await makeSignedInStore(responding: 500)

        XCTAssertEqual(store.connection, .reached)
        XCTAssertNotNil(store.errorMessage)
        XCTAssertEqual(kidStatusMessage(store), KidCopy.cannotReachBanner(lastUpdated: store.snapshot.lastUpdated))
        XCTAssertNotEqual(kidStatusMessage(store), KidCopy.offlineBanner(lastUpdated: store.snapshot.lastUpdated))
        XCTAssertEqual(store.latestTransportDiagnostic?.httpStatus, 500)
    }

    func testAnHTTPAnswerReplacesAnEarlierOfflineClassification() async {
        let transport = ScriptedTransport(.failure(URLError(.notConnectedToInternet)))
        let store = await makeSignedInStore(transport)
        XCTAssertEqual(store.connection, .deviceOffline)
        XCTAssertEqual(kidStatusMessage(store), KidCopy.offlineBanner(lastUpdated: store.snapshot.lastUpdated))

        transport.outcome = .status(500)
        await refreshAndSettle(store, transport)

        XCTAssertEqual(store.connection, .reached)
        XCTAssertEqual(kidStatusMessage(store), KidCopy.cannotReachBanner(lastUpdated: store.snapshot.lastUpdated))
        XCTAssertNotEqual(kidStatusMessage(store), KidCopy.offlineBanner(lastUpdated: store.snapshot.lastUpdated))
        XCTAssertEqual(store.latestTransportDiagnostic?.httpStatus, 500)
    }

    /// The readout describes the most recent failure, and keeps describing it
    /// after the wallet recovers: an intermittent failure is exactly the one a
    /// parent needs to report once things are working again.
    func testTheReadoutSurvivesALaterSuccessfulRead() async {
        let transport = ScriptedTransport(.failure(URLError(.timedOut)))
        let store = await makeSignedInStore(transport)
        XCTAssertEqual(store.connection, .serviceUnreachable)

        transport.outcome = .success(Self.childViewResponse)
        await refreshAndSettle(store, transport)

        XCTAssertEqual(store.connection, .reached)
        XCTAssertNil(kidStatusMessage(store))
        XCTAssertEqual(store.latestTransportDiagnostic?.category, .timedOut)
    }

    // MARK: - Nothing sensitive can reach the readout

    /// A ledger entry id is wallet data. It appears in a request path, so the
    /// route a diagnostic keeps must be a template, never the concrete path.
    func testAnIdentifierInARequestPathNeverReachesTheDiagnostic() async {
        let entryID = "3F2504E0-4F89-11D3-9A0C-0305E82C3301"
        let repository = makeRepository(ScriptedTransport(.failure(URLError(.timedOut))))

        do {
            _ = try await repository.activityDetail(remoteID: entryID)
            XCTFail("expected the scripted transport failure")
        } catch {}

        let diagnostic = repository.latestTransportDiagnostic
        XCTAssertEqual(diagnostic?.route, "/v1/activity/{id}")
        XCTAssertFalse(diagnostic?.shareableSummary.contains(entryID) ?? true)
        XCTAssertFalse(diagnostic?.shareableSummary.contains("3F2504E0") ?? true)
    }

    func testAnIdentifierEqualToARouteWordIsStillRedacted() async {
        let repository = makeRepository(ScriptedTransport(.failure(URLError(.timedOut))))

        do {
            _ = try await repository.activityDetail(remoteID: "wallet")
            XCTFail("expected the scripted transport failure")
        } catch {}

        XCTAssertEqual(repository.latestTransportDiagnostic?.route, "/v1/activity/{id}")
    }

    func testAQueryNeverReachesTheDiagnostic() {
        XCTAssertEqual(TransportDiagnostic.route(forPath: "/v1/activity?limit=50"), "/v1/activity")
        XCTAssertEqual(TransportDiagnostic.route(forPath: "/v1/cloud/changes?afterRevision=41"), "/v1/cloud/changes")
        XCTAssertEqual(TransportDiagnostic.route(forPath: "/v1/loans/abc-123"), "/v1/loans/{id}")
        XCTAssertEqual(TransportDiagnostic.route(forPath: "/v1/child-view"), "/v1/child-view")
    }

    /// The copy action can only ever hand over what the screen already shows.
    func testTheCopiedReportSaysExactlyWhatTheReadoutShows() {
        let diagnostic = TransportDiagnostic(
            category: .timedOut,
            code: -1_001,
            hasUnderlyingError: false,
            route: "/v1/child-view",
            httpStatus: nil,
            elapsedMilliseconds: 30_012,
            timestamp: Date(timeIntervalSince1970: 1_770_000_000)
        )

        let expected = """
        \(TransportDiagnostic.summaryTitle)
        What failed: timedOut
        Error code: -1001
        Underlying error: absent
        Route: /v1/child-view
        Response status: no response
        Took: 30012 ms
        When: 2026-02-02T02:40:00Z
        """
        XCTAssertEqual(diagnostic.shareableSummary, expected)
        XCTAssertEqual(
            diagnostic.displayRows.map(\.id),
            ["category", "code", "underlying", "route", "status", "elapsed", "timestamp"]
        )
    }

    /// The session token the request carried must not survive into the report.
    func testTheReadoutCarriesNothingFromTheRequestItDescribes() async {
        let store = await makeSignedInStore(throwing: URLError(.timedOut))

        guard let summary = store.latestTransportDiagnostic?.shareableSummary else {
            return XCTFail("the failure the transport reported was not preserved")
        }
        for forbidden in [Self.sessionToken, "Bearer", "Authorization", "example.test", "https", "Robin"] {
            XCTAssertFalse(summary.contains(forbidden), "\(forbidden) must never reach a shared report")
        }
    }

    // MARK: - Parent mutations

    func testFailedParentMutationsReachTheConnectionReadout() async {
        let transport = ScriptedTransport(.success(Self.childViewResponse))
        let store = await makeSignedInStore(transport)
        let completedBeforeGate = transport.completedRequests

        store.openParentGate()
        for digit in "1234" {
            store.appendPINDigit(String(digit))
        }
        await expect("entering the Parent area finishes its wallet read") {
            transport.completedRequests > completedBeforeGate && !store.isLoading
        }
        XCTAssertEqual(store.elevation, .active)

        transport.outcome = .failure(URLError(.timedOut))

        let allowanceRecorded = await store.setAllowance(AllowanceRuleCommand(
            amountCents: 500,
            weekday: 6,
            startDate: .now
        ))
        XCTAssertFalse(allowanceRecorded)
        XCTAssertEqual(store.latestTransportDiagnostic?.route, "/v1/allowance-rule")

        let profileRecorded = await store.updateChildProfile(nickname: "Robin")
        XCTAssertFalse(profileRecorded)
        XCTAssertEqual(store.latestTransportDiagnostic?.route, "/v1/child")

        let result = await store.submit(WalletCommand(kind: .deposit, amountCents: 500))
        guard case .pending = result else {
            return XCTFail("a transport failure should leave the exact protected request pending")
        }
        XCTAssertEqual(store.latestTransportDiagnostic?.route, "/v1/wallet/deposits")
        XCTAssertEqual(store.latestTransportDiagnostic?.category, .timedOut)
        XCTAssertEqual(store.elevation, .active)
    }

    // MARK: - The local wallet is untouched

    /// A wallet with no service behind it has no transport to diagnose, so it
    /// never offers the parent-only readout.
    func testALocalWalletNeverProducesADiagnostic() async {
        let store = WalletStore(
            repository: MockWalletRepository(snapshot: Self.snapshot),
            initiallySignedIn: true,
            pinStore: InMemoryParentPINStore(pin: "1234"),
            identityStore: InMemoryParentIdentityStore(appleUserID: "synthetic-parent")
        )

        await store.refresh()

        XCTAssertNil(store.latestTransportDiagnostic)
        XCTAssertEqual(store.connection, .reached)
    }

    // MARK: - Helpers

    private static let sessionToken = "synthetic-session-token"

    private static var snapshot: WalletSnapshot {
        WalletSnapshot(
            acceptedBalanceCents: 2_400,
            activities: [],
            loan: nil,
            allowance: nil,
            pendingEvents: [],
            lastUpdated: Date(timeIntervalSince1970: 1_770_000_000),
            isStale: false,
            childNickname: "Robin"
        )
    }

    private static let childViewResponse = """
    {
      "family": {"id":"family","name":"Robin's family"},
      "child": {"id":"child","nickname":"Robin","avatarUrl":null},
      "wallet": {"id":"wallet","currency":"USD","balanceCents":2400,"virtualNotice":"Virtual practice only. These dollars are pretend, cannot be redeemed, and never move real money."},
      "allowanceRule": null,
      "loan": null,
      "recentActivity": [],
      "readOnly": true
    }
    """

    /// The kid home's own status derivation, driven from published state.
    private func kidStatusMessage(_ store: WalletStore) -> String? {
        KidCopy.statusBanner(
            sessionExpired: store.sessionExpired,
            connection: store.connection,
            hasError: store.errorMessage != nil,
            lastUpdated: store.snapshot.lastUpdated
        )
    }

    private func makeRepository(_ transport: ScriptedTransport) -> APIWalletRepository {
        APIWalletRepository(
            baseURL: URL(string: "https://api.example.test")!,
            sessionStore: InMemorySessionStore(
                session: AuthSession(token: Self.sessionToken, expiresAt: .now.addingTimeInterval(3_600))
            ),
            transport: transport,
            cache: PrimedSnapshotCache(snapshot: Self.snapshot),
            configuredKidStore: InMemoryConfiguredKidStore(isConfigured: true),
            pendingStore: InMemoryPendingCommandStore()
        )
    }

    private func makeSignedInStore(throwing error: Error) async -> WalletStore {
        await makeSignedInStore(ScriptedTransport(.failure(error)))
    }

    private func makeSignedInStore(responding statusCode: Int) async -> WalletStore {
        await makeSignedInStore(ScriptedTransport(.status(statusCode)))
    }

    /// A signed-in store whose launch read has already finished, plus one
    /// deliberate read of its own. The store reads at launch, so a test that
    /// asserted straight after its own `refresh()` would be racing that read.
    private func makeSignedInStore(_ transport: ScriptedTransport) async -> WalletStore {
        let store = WalletStore(
            repository: makeRepository(transport),
            initiallySignedIn: true,
            pinStore: InMemoryParentPINStore(pin: "1234"),
            identityStore: InMemoryParentIdentityStore(appleUserID: "synthetic-parent")
        )
        await expect("the store reads the wallet at launch") { transport.completedRequests >= 1 }
        await refreshAndSettle(store, transport)
        return store
    }

    /// Reads once and waits until no read is still in flight, so what is
    /// asserted is settled published state rather than a moment mid-read.
    private func refreshAndSettle(_ store: WalletStore, _ transport: ScriptedTransport) async {
        await store.refresh()
        await expect("every read finishes") { transport.inFlightRequests == 0 && !store.isLoading }
    }

    private func expect(
        _ description: String,
        timeout: TimeInterval = 3,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !condition() {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue(condition(), description, file: file, line: line)
    }
}

/// A transport that answers every request the same way until a test changes
/// the answer, so overlapping reads cannot make a result depend on which read
/// happened to arrive first. `data(for:)` is nonisolated and `WalletStore`
/// starts unstructured refresh tasks, so all state lives behind one lock.
private final class ScriptedTransport: HTTPTransport, @unchecked Sendable {
    enum Outcome {
        case failure(Error)
        case status(Int)
        case success(String)
    }

    private struct State {
        var outcome: Outcome
        var started = 0
        var completed = 0
    }

    private let lock = NSLock()
    private var state: State

    init(_ outcome: Outcome) {
        state = State(outcome: outcome)
    }

    private func withState<T>(_ body: (inout State) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&state)
    }

    var outcome: Outcome {
        get { withState { $0.outcome } }
        set { withState { $0.outcome = newValue } }
    }

    var completedRequests: Int { withState { $0.completed } }
    var inFlightRequests: Int { withState { $0.started - $0.completed } }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let outcome = withState { state -> Outcome in
            state.started += 1
            return state.outcome
        }
        defer { withState { $0.completed += 1 } }
        switch outcome {
        case let .failure(error):
            throw error
        case let .status(code):
            return (Data("{}".utf8), Self.response(for: request, statusCode: code))
        case let .success(body):
            return (Data(body.utf8), Self.response(for: request, statusCode: 200))
        }
    }

    private static func response(for request: URLRequest, statusCode: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: request.url!, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
    }
}

/// A cache that already holds an accepted wallet, so a failed read has a last
/// accepted balance to keep on screen exactly as a real device would.
@MainActor
private final class PrimedSnapshotCache: WalletSnapshotCache {
    private var stored: WalletSnapshot?

    init(snapshot: WalletSnapshot) { stored = snapshot }

    func load() -> WalletSnapshot? { stored }
    func save(_ snapshot: WalletSnapshot) { stored = snapshot }
    func clear() { stored = nil }
}
