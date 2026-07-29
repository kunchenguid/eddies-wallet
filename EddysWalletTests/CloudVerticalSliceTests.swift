import Foundation
import XCTest
@testable import EddysWallet

/// End-to-end behaviour of the guarded Cloud slice against synthetic backend
/// responses: activation upload, replica bootstrap, revision conflict and
/// re-review, expiry with local continuation, authority-aware sign-out, outage,
/// and corrupt local history. No Apple account, purchase, or real family data.
@MainActor
final class CloudVerticalSliceTests: XCTestCase {
    private var directory: URL!
    private let session = AuthSession(token: "synthetic-session", expiresAt: .distantFuture)
    private static let baseURL = URL(string: "https://api.example.test")!

    override func setUp() async throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("cloud-slice-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Activation and first upload

    func testPaidActivationUploadsTheCompleteLocalHouseholdOnceAndMirrorsTheReplica() async throws {
        let local = try await localWalletWithHistory()
        let lineage = try XCTUnwrap(local.lineageID)
        let transport = RoutingTransport()
        transport.stub("GET", "/v1/cloud/context", CloudSliceFixtures.contextActiveNoHousehold)
        transport.stub("POST", "/v1/cloud/household/import", CloudSliceFixtures.importAccepted(lineage: lineage), status: 201)
        transport.stub("GET", "/v1/cloud/bootstrap", CloudSliceFixtures.bootstrap(lineage: lineage))
        let coordinator = CloudCoordinator(client: client(transport), subscriptions: silentSubscriptionStore(transport))

        await coordinator.refreshContext()
        XCTAssertTrue(coordinator.isCloudActive, "the backend projection is what enables Cloud")

        let cloud = try await coordinator.activateCloud(from: local, familyName: "Test Kid's family")
        XCTAssertEqual(cloud.lineageID, lineage, "activation keeps one wallet lineage")
        XCTAssertEqual(cloud.revision, 2)
        XCTAssertTrue(local.isCloudAuthority)
        XCTAssertEqual(local.cloudRevision, 2)
        XCTAssertEqual(cloud.snapshot().acceptedBalanceCents, 750, "the mirrored replica is the accepted Cloud balance")

        let importRequest = try XCTUnwrap(transport.requests.first { $0.url?.path == "/v1/cloud/household/import" })
        let body = try XCTUnwrap(importRequest.httpBody).jsonObject()
        XCTAssertEqual(body["lineageId"] as? String, lineage.uuidString.lowercased())
        XCTAssertEqual((body["entries"] as? [[String: Any]])?.count, 2, "the complete accepted history is uploaded")
        XCTAssertEqual((body["aggregateSha256"] as? String)?.count, 64)
        XCTAssertEqual(importRequest.value(forHTTPHeaderField: "Idempotency-Key"), "cloud-import-\(try XCTUnwrap(local.cloudImportOperationID).uuidString.lowercased())")
    }

    func testAnInterruptedActivationRetriesWithTheSameOperationAndKey() async throws {
        let local = try await localWalletWithHistory()
        let reserved = try local.reserveCloudImportOperation()
        XCTAssertEqual(try local.reserveCloudImportOperation(), reserved, "the import identity is reserved once")

        let lineage = try XCTUnwrap(local.lineageID)
        let transport = RoutingTransport()
        transport.stub("GET", "/v1/cloud/context", CloudSliceFixtures.contextActiveNoHousehold)
        transport.stub("POST", "/v1/cloud/household/import", CloudSliceFixtures.importAccepted(lineage: lineage), status: 200)
        transport.stub("GET", "/v1/cloud/bootstrap", CloudSliceFixtures.bootstrap(lineage: lineage))
        let coordinator = CloudCoordinator(client: client(transport), subscriptions: silentSubscriptionStore(transport))
        await coordinator.refreshContext()
        _ = try await coordinator.activateCloud(from: local, familyName: "Test Kid's family")

        let importRequest = try XCTUnwrap(transport.requests.first { $0.url?.path == "/v1/cloud/household/import" })
        XCTAssertEqual(importRequest.value(forHTTPHeaderField: "Idempotency-Key"), "cloud-import-\(reserved.uuidString.lowercased())")
    }

    func testActivationConflictLeavesTheFreeLocalWalletUntouched() async throws {
        let local = try await localWalletWithHistory()
        let transport = RoutingTransport()
        transport.stub("GET", "/v1/cloud/context", CloudSliceFixtures.contextActiveNoHousehold)
        transport.stub("POST", "/v1/cloud/household/import", CloudSliceFixtures.conflictError, status: 409)
        let coordinator = CloudCoordinator(client: client(transport), subscriptions: silentSubscriptionStore(transport))
        await coordinator.refreshContext()

        do {
            _ = try await coordinator.activateCloud(from: local, familyName: "Test Kid's family")
            XCTFail("a conflicting household must not activate")
        } catch {
            XCTAssertTrue(coordinator.activationConflict)
        }
        XCTAssertFalse(local.isCloudAuthority, "the device stays on free local authority")
        XCTAssertEqual(local.snapshot().acceptedBalanceCents, 750, "nothing local changed")
        guard case .accepted = try await local.submit(WalletCommand(kind: .deposit, amountCents: 25)) else {
            return XCTFail("the free wallet must remain fully usable after a failed activation")
        }
    }

    func testActivationIsRefusedWithoutTheBackendProjectedEntitlement() async throws {
        let local = try await localWalletWithHistory()
        let transport = RoutingTransport()
        transport.stub("GET", "/v1/cloud/context", CloudSliceFixtures.contextNoEntitlement)
        let coordinator = CloudCoordinator(client: client(transport), subscriptions: silentSubscriptionStore(transport))
        await coordinator.refreshContext()
        XCTAssertFalse(coordinator.isCloudActive)
        do {
            _ = try await coordinator.activateCloud(from: local, familyName: "Test Kid's family")
            XCTFail("no entitlement means no activation")
        } catch WalletAPIError.cloudEntitlementRequired {
            XCTAssertFalse(local.isCloudAuthority)
        }
    }

    // MARK: - Second device

    func testSecondDeviceBootstrapsTheExistingHouseholdWithoutUploading() async throws {
        // A clean device: no local wallet history at all.
        let local = try LocalWalletRepository(directory: directory)
        let lineage = UUID()
        let transport = RoutingTransport()
        transport.stub("GET", "/v1/cloud/context", CloudSliceFixtures.contextActive(lineage: lineage, revision: 2))
        transport.stub("GET", "/v1/cloud/bootstrap", CloudSliceFixtures.bootstrap(lineage: lineage))
        let coordinator = CloudCoordinator(client: client(transport), subscriptions: silentSubscriptionStore(transport))

        let adopted = try await coordinator.adoptExistingCloudHousehold(into: local)
        let cloud = try XCTUnwrap(adopted)
        XCTAssertEqual(cloud.lineageID, lineage)
        XCTAssertEqual(cloud.snapshot().acceptedBalanceCents, 750)
        XCTAssertEqual(cloud.snapshot().activities.count, 2)
        XCTAssertEqual(cloud.snapshot().childNickname, "Test Kid")
        XCTAssertFalse(transport.requests.contains { $0.url?.path == "/v1/cloud/household/import" }, "device B never uploads")
    }

    // MARK: - Revision discipline in the app

    func testConflictingWriteIsNotRecordedAndAsksForReReview() async throws {
        let local = try LocalWalletRepository(directory: directory)
        let lineage = UUID()
        let transport = RoutingTransport()
        transport.stub("GET", "/v1/cloud/bootstrap", CloudSliceFixtures.bootstrap(lineage: lineage))
        transport.stub("POST", "/v1/wallet/deposits", CloudSliceFixtures.revisionConflictError, status: 409)
        transport.stub("GET", "/v1/cloud/changes", CloudSliceFixtures.changes(lineage: lineage, revision: 7, balanceCents: 900))
        let cloud = CloudWalletRepository(client: client(transport), replica: local, lineageID: lineage, revision: 2)
        _ = try await cloud.bootstrap()

        let store = WalletStore(
            repository: cloud,
            appleSignInProvider: SliceSignInProvider(),
            initiallySignedIn: true,
            pinStore: InMemoryParentPINStore(pin: "1234"),
            identityStore: InMemoryParentIdentityStore(appleUserID: "synthetic-parent")
        )
        store.openParentGate()
        for digit in ["1", "2", "3", "4"] { store.appendPINDigit(digit) }
        XCTAssertEqual(store.elevation, .active)

        let result = await store.submit(WalletCommand(kind: .deposit, amountCents: 250))
        guard case .rejected(let event) = result else { return XCTFail("a conflicting write is Not recorded, got \(result)") }
        XCTAssertEqual(event.syncState, .rejected)
        XCTAssertTrue(store.needsCloudReview, "the parent is asked to review the latest accepted balance")
        XCTAssertEqual(cloud.lastConflictRevision, 7)
        XCTAssertEqual(cloud.revision, 7, "the client adopts the server's current revision before retrying")
        let deposit = try XCTUnwrap(transport.requests.first { $0.url?.path == "/v1/wallet/deposits" })
        XCTAssertEqual(deposit.value(forHTTPHeaderField: "If-Match"), "\"rev-2\"")
        store.acknowledgeCloudReview()
        XCTAssertFalse(store.needsCloudReview)
    }

    func testAcceptedCloudWriteAdvancesTheRevisionAndMirrorsAcceptedState() async throws {
        let local = try LocalWalletRepository(directory: directory)
        let lineage = UUID()
        let transport = RoutingTransport()
        transport.stub("GET", "/v1/cloud/bootstrap", CloudSliceFixtures.bootstrap(lineage: lineage))
        transport.stub("POST", "/v1/wallet/deposits", CloudSliceFixtures.depositAccepted(revision: 3))
        transport.stub("GET", "/v1/cloud/changes", CloudSliceFixtures.changes(lineage: lineage, revision: 3, balanceCents: 1_000))
        let cloud = CloudWalletRepository(client: client(transport), replica: local, lineageID: lineage, revision: 2)
        _ = try await cloud.bootstrap()

        guard case .accepted = try await cloud.submit(WalletCommand(kind: .deposit, amountCents: 250, reason: "chores")) else {
            return XCTFail("an accepted Cloud write must be Recorded")
        }
        XCTAssertEqual(cloud.revision, 3)
        XCTAssertEqual(cloud.snapshot().acceptedBalanceCents, 1_000, "only server-accepted state is rendered")
        XCTAssertTrue(cloud.snapshot().pendingEvents.isEmpty)
    }

    // MARK: - Expiry, sign-out, outage

    func testExpiredCloudRefusesWritesAndOffersLocalContinuation() async throws {
        let local = try LocalWalletRepository(directory: directory)
        let lineage = UUID()
        let transport = RoutingTransport()
        transport.stub("GET", "/v1/cloud/bootstrap", CloudSliceFixtures.bootstrap(lineage: lineage))
        transport.stub("POST", "/v1/wallet/deposits", CloudSliceFixtures.entitlementRequiredError, status: 403)
        transport.stub("GET", "/v1/cloud/context", CloudSliceFixtures.contextExpired(lineage: lineage))
        let cloudClient = client(transport)
        let cloud = CloudWalletRepository(client: cloudClient, replica: local, lineageID: lineage, revision: 2)
        _ = try await cloud.bootstrap()
        let coordinator = CloudCoordinator(client: cloudClient, subscriptions: silentSubscriptionStore(transport))
        await coordinator.refreshContext()
        XCTAssertFalse(coordinator.isCloudActive)

        let store = elevatedStore(repository: cloud, coordinator: coordinator)
        let result = await store.submit(WalletCommand(kind: .deposit, amountCents: 250))
        guard case .rejected = result else { return XCTFail("an expired entitlement must refuse Cloud writes") }
        XCTAssertEqual(store.snapshot.acceptedBalanceCents, 750, "reads keep working and nothing was deleted")

        XCTAssertTrue(store.continueLocallyAfterCloud(), "the parent can keep using this device")
        XCTAssertTrue(store.authorityState.isLocalAuthority)
        XCTAssertFalse(local.isCloudAuthority)
        XCTAssertEqual(store.snapshot.acceptedBalanceCents, 750, "the mirrored history stays after continuing locally")
        guard case .accepted = await store.submit(WalletCommand(kind: .deposit, amountCents: 100)) else {
            return XCTFail("local authority accepts parent actions again")
        }
        XCTAssertEqual(store.snapshot.acceptedBalanceCents, 850)
    }

    func testCloudSignOutStopsSyncingWithoutDeletingTheWallet() async throws {
        let local = try LocalWalletRepository(directory: directory)
        let lineage = UUID()
        let transport = RoutingTransport()
        transport.stub("GET", "/v1/cloud/bootstrap", CloudSliceFixtures.bootstrap(lineage: lineage))
        transport.stub("DELETE", "/v1/session/current", Data(), status: 204)
        let cloudClient = client(transport)
        let cloud = CloudWalletRepository(client: cloudClient, replica: local, lineageID: lineage, revision: 2)
        _ = try await cloud.bootstrap()
        let store = elevatedStore(repository: cloud, coordinator: CloudCoordinator(client: cloudClient, subscriptions: silentSubscriptionStore(transport)))
        XCTAssertEqual(store.cloudSignOutMode, .cloudDevice, "a Cloud device never offers the destructive erase copy")
        XCTAssertTrue(store.canSignOutOfCloudOnThisDevice)

        await store.signOutOfCloudOnThisDevice()
        XCTAssertEqual(store.snapshot.acceptedBalanceCents, 750, "the wallet is still here")
        XCTAssertTrue(store.authorityState.isLocalAuthority)
        XCTAssertEqual(store.cloudEntitlement, .none)
        XCTAssertTrue(transport.requests.contains { $0.httpMethod == "DELETE" && $0.url?.path == "/v1/session/current" })
    }

    func testLocalOnlyWalletKeepsTheDestructiveSignOutWarning() async throws {
        let local = try await localWalletWithHistory()
        let store = elevatedStore(repository: local, coordinator: nil)
        XCTAssertEqual(store.cloudSignOutMode, .localErase, "a local-only wallet keeps the erase warning")
        XCTAssertFalse(store.canSignOutOfCloudOnThisDevice)
        XCTAssertTrue(store.cloudPlans.isEmpty, "no coordinator means no plans are ever shown")
    }

    func testLegacyServiceWalletKeepsItsNonDestructiveSignOutCopy() async throws {
        let store = WalletStore(
            repository: MockWalletRepository(),
            appleSignInProvider: SliceSignInProvider(),
            initiallySignedIn: true,
            pinStore: InMemoryParentPINStore(pin: "1234"),
            identityStore: InMemoryParentIdentityStore(appleUserID: "synthetic-parent")
        )
        XCTAssertEqual(store.cloudSignOutMode, .serviceDevice, "a service wallet never claims to erase the wallet")
        XCTAssertFalse(store.canSignOutOfCloudOnThisDevice)
    }

    func testBackendOutageKeepsTheCloudReplicaReadableAndOffersNoGrant() async throws {
        let local = try LocalWalletRepository(directory: directory)
        let lineage = UUID()
        let transport = RoutingTransport()
        transport.stub("GET", "/v1/cloud/bootstrap", CloudSliceFixtures.bootstrap(lineage: lineage))
        let cloudClient = client(transport)
        let cloud = CloudWalletRepository(client: cloudClient, replica: local, lineageID: lineage, revision: 2)
        _ = try await cloud.bootstrap()
        transport.failEverything = true

        let coordinator = CloudCoordinator(client: cloudClient, subscriptions: silentSubscriptionStore(transport))
        await coordinator.refreshAvailability()
        XCTAssertFalse(coordinator.canOfferPlans, "an unreachable backend never offers plans")
        XCTAssertEqual(coordinator.entitlement, .none, "an unreachable backend never grants")

        let store = elevatedStore(repository: cloud, coordinator: coordinator)
        await store.refresh()
        XCTAssertTrue(store.isOffline)
        XCTAssertEqual(store.snapshot.acceptedBalanceCents, 750, "the last accepted Cloud state stays readable offline")
        if case .cloudOffline = store.authorityState {} else {
            XCTFail("an offline Cloud wallet is presented as offline, not as local authority: \(store.authorityState)")
        }
    }

    func testUnknownOrMalformedHouseholdNeverBecomesCloudAuthority() async throws {
        let local = try await localWalletWithHistory()
        let transport = RoutingTransport()
        transport.stub("GET", "/v1/cloud/context", CloudSliceFixtures.contextActiveUnknownAuthority)
        let coordinator = CloudCoordinator(client: client(transport), subscriptions: silentSubscriptionStore(transport))
        await coordinator.refreshContext()
        XCTAssertNil(coordinator.household, "an unknown authority is not a Cloud household")
        let adopted = try await coordinator.adoptExistingCloudHousehold(into: local)
        XCTAssertNil(adopted, "there is nothing to adopt")
        XCTAssertFalse(local.isCloudAuthority)
    }

    func testCorruptCloudReplicaIsRefusedInsteadOfReplacingAcceptedHistory() async throws {
        let local = try await localWalletWithHistory()
        let lineage = try XCTUnwrap(local.lineageID)
        // A payload whose ledger chain does not balance must never be persisted.
        let broken = try JSONDecoder.cloud.decode(CloudReplica.self, from: CloudSliceFixtures.brokenChainBootstrap(lineage: lineage))
        XCTAssertThrowsError(try local.applyCloudReplica(broken, merging: false))
        XCTAssertEqual(local.snapshot().acceptedBalanceCents, 750, "the accepted local history is untouched")
    }

    // MARK: - Helpers

    private func client(_ transport: RoutingTransport) -> CloudAPIClient {
        CloudAPIClient(baseURL: Self.baseURL, sessionStore: InMemorySessionStore(session: session), transport: transport)
    }

    /// A subscription store that does not subscribe to StoreKit streams, so unit
    /// tests never depend on the local StoreKit environment.
    private func silentSubscriptionStore(_ transport: RoutingTransport) -> CloudSubscriptionStore {
        CloudSubscriptionStore(client: client(transport), observeTransactions: false)
    }

    private func localWalletWithHistory() async throws -> LocalWalletRepository {
        let local = try LocalWalletRepository(directory: directory)
        _ = try await local.setup(ParentSetup(nickname: "Test Kid"))
        _ = try await local.submit(WalletCommand(kind: .deposit, amountCents: 1_000, reason: "chores"))
        _ = try await local.submit(WalletCommand(kind: .withdrawal, amountCents: 250, reason: "sticker book"))
        return local
    }

    private func elevatedStore(repository: any WalletRepository, coordinator: CloudCoordinator?) -> WalletStore {
        let store = WalletStore(
            repository: repository,
            appleSignInProvider: SliceSignInProvider(),
            initiallySignedIn: true,
            pinStore: InMemoryParentPINStore(pin: "1234"),
            identityStore: InMemoryParentIdentityStore(appleUserID: "synthetic-parent"),
            cloudCoordinator: coordinator
        )
        store.openParentGate()
        for digit in ["1", "2", "3", "4"] { store.appendPINDigit(digit) }
        return store
    }
}

// MARK: - Fixtures and stubs

enum CloudSliceFixtures {
    static let contextNoEntitlement = Data("""
    {"storeAccountToken":"11111111-1111-4111-8111-111111111111","entitlement":null,"household":null}
    """.utf8)
    static let contextActiveNoHousehold = Data("""
    {"storeAccountToken":"11111111-1111-4111-8111-111111111111",
     "entitlement":{"state":"active","accessUntil":"2027-01-01T00:00:00.000Z","active":true},"household":null}
    """.utf8)
    static let contextActiveUnknownAuthority = Data("""
    {"storeAccountToken":"11111111-1111-4111-8111-111111111111",
     "entitlement":{"state":"active","accessUntil":"2027-01-01T00:00:00.000Z","active":true},
     "household":{"lineageId":"22222222-2222-4222-8222-222222222222","authority":"future_mode","revision":9}}
    """.utf8)
    static let revisionConflictError = Data("""
    {"error":{"code":"REVISION_CONFLICT","message":"This wallet changed on another device.","details":{"currentRevision":7}}}
    """.utf8)
    static let entitlementRequiredError = Data("""
    {"error":{"code":"CLOUD_ENTITLEMENT_REQUIRED","message":"An active Cloud subscription is required to record this action."}}
    """.utf8)
    static let conflictError = Data("""
    {"error":{"code":"CLOUD_HOUSEHOLD_CONFLICT","message":"A different Cloud household already belongs to this parent."}}
    """.utf8)

    static func contextActive(lineage: UUID, revision: Int64) -> Data {
        Data("""
        {"storeAccountToken":"11111111-1111-4111-8111-111111111111",
         "entitlement":{"state":"active","accessUntil":"2027-01-01T00:00:00.000Z","active":true},
         "household":{"lineageId":"\(lineage.uuidString.lowercased())","authority":"cloud","revision":\(revision)}}
        """.utf8)
    }

    static func contextExpired(lineage: UUID) -> Data {
        Data("""
        {"storeAccountToken":"11111111-1111-4111-8111-111111111111",
         "entitlement":{"state":"expired","accessUntil":"2026-01-01T00:00:00.000Z","active":false},
         "household":{"lineageId":"\(lineage.uuidString.lowercased())","authority":"cloud","revision":2}}
        """.utf8)
    }

    static func importAccepted(lineage: UUID) -> Data {
        Data("""
        {"household":{"lineageId":"\(lineage.uuidString.lowercased())","authority":"cloud","revision":2}}
        """.utf8)
    }

    static func depositAccepted(revision: Int64) -> Data {
        Data("""
        {"entry":{"id":"e-9","type":"deposit","amountCents":250},"wallet":{"id":"w-1","balanceCents":1000},"revision":\(revision)}
        """.utf8)
    }

    /// Two accepted events, balance 750, one open loan-free wallet.
    static func bootstrap(lineage: UUID) -> Data {
        Data("""
        {"household":{"lineageId":"\(lineage.uuidString.lowercased())","authority":"cloud","revision":2},
         "family":{"id":"f-1","name":"Test Kid's family"},
         "child":{"id":"c-1","nickname":"Test Kid","avatarUrl":null},
         "wallet":{"id":"w-1","balanceCents":750},
         "entries":[
           {"id":"c1111111-1111-4111-8111-111111111111","type":"deposit","direction":"credit","amountCents":1000,"balanceBeforeCents":0,"balanceAfterCents":1000,"reason":"chores","loanId":null,"recordedAt":"2026-07-24T10:00:00.000Z","acceptedRevision":1},
           {"id":"c2222222-2222-4222-8222-222222222222","type":"withdrawal","direction":"debit","amountCents":250,"balanceBeforeCents":1000,"balanceAfterCents":750,"reason":"sticker book","loanId":null,"recordedAt":"2026-07-25T10:00:00.000Z","acceptedRevision":2}],
         "loans":[],"allowanceRule":null,"nextCursor":null}
        """.utf8)
    }

    static func changes(lineage: UUID, revision: Int64, balanceCents: Int) -> Data {
        Data("""
        {"household":{"lineageId":"\(lineage.uuidString.lowercased())","authority":"cloud","revision":\(revision)},
         "family":{"id":"f-1","name":"Test Kid's family"},
         "child":{"id":"c-1","nickname":"Test Kid","avatarUrl":null},
         "wallet":{"id":"w-1","balanceCents":\(balanceCents)},
         "entries":[{"id":"c3333333-3333-4333-8333-333333333333","type":"deposit","direction":"credit","amountCents":\(balanceCents - 750),"balanceBeforeCents":750,"balanceAfterCents":\(balanceCents),"reason":"another device","loanId":null,"recordedAt":"2026-07-26T10:00:00.000Z","acceptedRevision":\(revision)}],
         "loans":[],"allowanceRule":null}
        """.utf8)
    }

    static func brokenChainBootstrap(lineage: UUID) -> Data {
        Data("""
        {"household":{"lineageId":"\(lineage.uuidString.lowercased())","authority":"cloud","revision":2},
         "family":{"id":"f-1","name":"Test Kid's family"},
         "child":{"id":"c-1","nickname":"Test Kid","avatarUrl":null},
         "wallet":{"id":"w-1","balanceCents":9999},
         "entries":[{"id":"c1111111-1111-4111-8111-111111111111","type":"deposit","direction":"credit","amountCents":1000,"balanceBeforeCents":0,"balanceAfterCents":1000,"reason":"chores","loanId":null,"recordedAt":"2026-07-24T10:00:00.000Z","acceptedRevision":1}],
         "loans":[],"allowanceRule":null,"nextCursor":null}
        """.utf8)
    }
}

extension JSONDecoder {
    /// Mirrors the client's decoder for fixtures decoded directly in tests.
    static var cloud: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)
            guard let date = CloudDateFormat.date(from: raw) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "bad date"))
            }
            return date
        }
        return decoder
    }
}

/// Routes stubbed responses by method and path, and can simulate an outage.
final class RoutingTransport: HTTPTransport, @unchecked Sendable {
    private struct Stub {
        let statusCode: Int
        let body: Data
    }

    private(set) var requests: [URLRequest] = []
    var failEverything = false
    private var stubs: [String: Stub] = [:]

    func stub(_ method: String, _ path: String, _ body: Data, status: Int = 200) {
        stubs["\(method) \(path)"] = Stub(statusCode: status, body: body)
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        if failEverything { throw URLError(.notConnectedToInternet) }
        let key = "\(request.httpMethod ?? "GET") \(request.url?.path ?? "")"
        guard let stub = stubs[key] else {
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 501, httpVersion: nil, headerFields: nil)!)
        }
        return (stub.body, HTTPURLResponse(url: request.url!, statusCode: stub.statusCode, httpVersion: nil, headerFields: nil)!)
    }
}

@MainActor
final class SliceSignInProvider: AppleSignInProviding {
    func signIn(requiredAppleUserID: String?) async throws -> AppleSignInOutcome {
        AppleSignInOutcome(
            session: AuthSession(token: "synthetic-session", expiresAt: .distantFuture),
            appleUserID: requiredAppleUserID ?? "synthetic-parent"
        )
    }
}

private extension Data {
    func jsonObject() -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: self)) as? [String: Any] ?? [:]
    }
}
