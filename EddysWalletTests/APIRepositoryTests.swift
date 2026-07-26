import Foundation
import XCTest
@testable import EddysWallet

@MainActor
final class APIRepositoryTests: XCTestCase {
    func testAppleSessionRequestUsesIdentityTokenAndNonceAndStoresOpaqueSession() async throws {
        let transport = StubHTTPTransport(responses: [
            StubHTTPTransport.Response(
                statusCode: 201,
                body: Data(#"{"token":"opaque-session","expiresAt":"2099-01-01T00:00:00Z","parent":{"provider":"apple","subject":"apple-subject","email":null}}"#.utf8)
            )
        ])
        let sessions = InMemorySessionStore()
        let repository = APIWalletRepository(
            baseURL: URL(string: "https://api.example.test")!,
            sessionStore: sessions,
            transport: transport,
            cache: TestSnapshotCache()
        )

        let session = try await repository.authenticateApple(identityToken: "native.identity.token", nonce: "signed-nonce")

        XCTAssertEqual(session.token, "opaque-session")
        XCTAssertEqual(sessions.session?.token, "opaque-session")
        XCTAssertEqual(transport.requests.count, 1)
        guard let request = transport.requests.first else { return XCTFail("The authentication request was not sent") }
        XCTAssertEqual(request.url?.absoluteString, "https://api.example.test/v1/auth/apple")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        guard let bodyData = request.httpBody else { return XCTFail("The authentication request had no body") }
        let body = try bodyData.jsonObject()
        XCTAssertEqual(body["identityToken"] as? String, "native.identity.token")
        XCTAssertEqual(body["nonce"] as? String, "signed-nonce")
    }

    func testDepositUsesIdempotencyKeyAndOnlyAcceptedResponseChangesBalance() async throws {
        let entryID = "11111111-1111-1111-1111-111111111111"
        let transport = StubHTTPTransport(responses: [
            StubHTTPTransport.Response(statusCode: 200, body: snapshotBody(balance: 0)),
            StubHTTPTransport.Response(
                statusCode: 201,
                body: Data(#"{"entry":{"id":"11111111-1111-1111-1111-111111111111","type":"deposit","direction":"credit","amountCents":150,"balanceBeforeCents":0,"balanceAfterCents":150,"reason":"first","loanId":null,"recordedBy":"parent","recordedAt":"2099-01-01T00:00:00Z"},"wallet":{"id":"wallet","currency":"USD","balanceCents":150,"virtualNotice":"Virtual practice only. These dollars are pretend, cannot be redeemed, and never move real money."}}"#.utf8)
            )
        ])
        let repository = APIWalletRepository(
            baseURL: URL(string: "https://api.example.test")!,
            sessionStore: InMemorySessionStore(session: validSession),
            transport: transport,
            cache: TestSnapshotCache()
        )

        _ = try await repository.refresh(for: .parent)
        let result = try await repository.submit(WalletCommand(kind: .deposit, amountCents: 150, reason: "first", idempotencyKey: "deposit-key"))

        guard case .accepted(let event) = result else { return XCTFail("The accepted response must be recorded") }
        XCTAssertEqual(event.remoteID, entryID)
        XCTAssertEqual(repository.snapshot().acceptedBalanceCents, 150)
        XCTAssertEqual(repository.snapshot().activities.first?.amountCents, 150)
        let post = try XCTUnwrap(transport.requests.last)
        XCTAssertEqual(post.httpMethod, "POST")
        XCTAssertEqual(post.value(forHTTPHeaderField: "Idempotency-Key"), "deposit-key")
        XCTAssertEqual(post.url?.path, "/v1/wallet/deposits")
    }

    func testNetworkFailureReturnsWaitingToSyncAndDoesNotChangeAcceptedBalance() async throws {
        let transport = StubHTTPTransport(error: URLError(.notConnectedToInternet))
        let repository = APIWalletRepository(
            baseURL: URL(string: "https://api.example.test")!,
            sessionStore: InMemorySessionStore(session: validSession),
            transport: transport,
            cache: TestSnapshotCache()
        )
        _ = try? await repository.refresh(for: .parent)

        let result = try await repository.submit(WalletCommand(kind: .withdrawal, amountCents: 50, idempotencyKey: "offline-key"))

        guard case .pending(let event) = result else { return XCTFail("A network failure must remain pending") }
        XCTAssertEqual(event.syncState, .pending)
        XCTAssertEqual(repository.snapshot().acceptedBalanceCents, 0)
        XCTAssertEqual(repository.snapshot().pendingEvents.count, 1)
    }

    func testExpiredSessionIsClearedOnUnauthorizedResponse() async throws {
        let transport = StubHTTPTransport(responses: [StubHTTPTransport.Response(statusCode: 401, body: Data(#"{"error":{"code":"UNAUTHENTICATED","message":"expired"}}"#.utf8))])
        let sessions = InMemorySessionStore(session: validSession)
        let repository = APIWalletRepository(
            baseURL: URL(string: "https://api.example.test")!,
            sessionStore: sessions,
            transport: transport,
            cache: TestSnapshotCache()
        )

        do {
            _ = try await repository.refresh(for: .parent)
            XCTFail("Unauthorized responses must fail")
        } catch let error as WalletAPIError {
            XCTAssertEqual(error, .unauthorized)
        }
        XCTAssertNil(sessions.session)
        XCTAssertFalse(repository.isAuthenticated)
    }

    func testChildRefreshRequiresServerReadOnlyResponse() async throws {
        let body = Data("""
        {
          "wallet": {"id":"wallet","currency":"USD","balanceCents":0,"virtualNotice":"Virtual practice only. These dollars are pretend, cannot be redeemed, and never move real money."},
          "allowanceRule": null,
          "loan": null,
          "recentActivity": [],
          "readOnly": false
        }
        """.utf8)
        let repository = APIWalletRepository(
            baseURL: URL(string: "https://api.example.test")!,
            sessionStore: InMemorySessionStore(session: validSession),
            transport: StubHTTPTransport(responses: [StubHTTPTransport.Response(statusCode: 200, body: body)]),
            cache: TestSnapshotCache()
        )

        do {
            _ = try await repository.refresh(for: .child)
            XCTFail("The client must reject a child response without a server read-only marker")
        } catch let error as WalletAPIError {
            guard case .invalidResponse = error else { return XCTFail("Expected an invalid response error") }
        }
    }

    func testInvalidVirtualNoticeCannotBecomeAnAcceptedSnapshot() async throws {
        let invalid = Data(#"{"wallet":{"id":"wallet","currency":"USD","balanceCents":999,"virtualNotice":"US dollars"},"allowanceRule":null,"loan":null,"recentActivity":[]}"#.utf8)
        let repository = APIWalletRepository(
            baseURL: URL(string: "https://api.example.test")!,
            sessionStore: InMemorySessionStore(session: validSession),
            transport: StubHTTPTransport(responses: [StubHTTPTransport.Response(statusCode: 200, body: invalid)]),
            cache: TestSnapshotCache()
        )

        do {
            _ = try await repository.refresh(for: .parent)
            XCTFail("An invalid authoritative response must fail")
        } catch let error as WalletAPIError {
            guard case .invalidResponse = error else { return XCTFail("Expected an invalid response error") }
        }
        XCTAssertEqual(repository.snapshot().acceptedBalanceCents, 0)
    }

    private var validSession: AuthSession {
        AuthSession(token: "opaque-session", expiresAt: Date(timeIntervalSince1970: 4_000_000_000))
    }

    private func snapshotBody(balance: Int) -> Data {
        Data("""
        {
          "family": {"id":"family","name":"Eddie's family"},
          "child": {"id":"child","nickname":"Eddie","avatarUrl":null,"lessonAgeBand":"school-age"},
          "wallet": {"id":"wallet","currency":"USD","balanceCents":\(balance),"virtualNotice":"Virtual practice only. These dollars are pretend, cannot be redeemed, and never move real money."},
          "allowanceRule": null,
          "loan": null,
          "recentActivity": []
        }
        """.utf8)
    }
}

private final class StubHTTPTransport: HTTPTransport {
    struct Response {
        let statusCode: Int
        let body: Data
    }

    var responses: [Response]
    var requests: [URLRequest] = []
    let error: Error?

    init(responses: [Response] = [], error: Error? = nil) {
        self.responses = responses
        self.error = error
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        if let error { throw error }
        guard !responses.isEmpty else { throw URLError(.badServerResponse) }
        let response = responses.removeFirst()
        let http = HTTPURLResponse(url: request.url!, statusCode: response.statusCode, httpVersion: nil, headerFields: nil)!
        return (response.body, http)
    }
}

@MainActor
private final class TestSnapshotCache: WalletSnapshotCache {
    var value: WalletSnapshot?
    func load() -> WalletSnapshot? { value }
    func save(_ snapshot: WalletSnapshot) { value = snapshot }
    func clear() { value = nil }
}

private extension Data {
    func jsonObject() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: self) as? [String: Any])
    }
}
