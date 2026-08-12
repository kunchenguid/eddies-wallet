import Foundation
import StoreKit
import XCTest
@testable import EddysWallet

/// End-to-end behaviour of the guarded Cloud slice against synthetic backend
/// responses: activation upload, replica bootstrap, runtime write settlement,
/// expiry with local continuation, authority-aware sign-out, outage, and
/// corrupt local history. No Apple account, purchase, or real family data.
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

    func testConfirmedImportRetriesAuthorityPersistenceThroughBootstrap() async throws {
        let persistence = CloudSliceFailingPersistence()
        let local = try LocalWalletRepository(persistence: persistence)
        _ = try await local.setup(ParentSetup(nickname: "Test Kid"))
        _ = try await local.submit(WalletCommand(kind: .deposit, amountCents: 750))
        let lineage = try XCTUnwrap(local.lineageID)
        _ = try local.reserveCloudImportOperation()
        persistence.failNextSave = true

        let transport = RoutingTransport()
        transport.stub("GET", "/v1/cloud/context", CloudSliceFixtures.contextActiveNoHousehold)
        transport.stub("POST", "/v1/cloud/household/import", CloudSliceFixtures.importAccepted(lineage: lineage), status: 201)
        transport.stub("GET", "/v1/cloud/bootstrap", CloudSliceFixtures.bootstrap(lineage: lineage))
        let coordinator = CloudCoordinator(client: client(transport), subscriptions: silentSubscriptionStore(transport))
        await coordinator.refreshContext()

        let cloud = try await coordinator.activateCloud(from: local, familyName: "Test Kid's family")
        let relaunched = try LocalWalletRepository(persistence: persistence)
        let selected = WalletRepositoryFactory.select(
            local: relaunched,
            legacy: MockWalletRepository(),
            cloudClient: client(transport)
        )

        XCTAssertTrue(local.isCloudAuthority, "bootstrap retries the durable Cloud marker after the first save fails")
        XCTAssertTrue(cloud.supportsRuntimeMutations)
        XCTAssertEqual(cloud.snapshot().acceptedBalanceCents, 750)
        XCTAssertTrue(selected is CloudWalletRepository)
    }

    func testAcceptedImportRemainsReadableWhenBootstrapFailsAndOfflineRelaunches() async throws {
        let local = try await localWalletWithHistory()
        let lineage = try XCTUnwrap(local.lineageID)
        let transport = RoutingTransport()
        transport.stub("GET", "/v1/cloud/context", CloudSliceFixtures.contextActiveNoHousehold)
        transport.stub("POST", "/v1/cloud/household/import", CloudSliceFixtures.importAccepted(lineage: lineage), status: 201)
        let coordinator = CloudCoordinator(client: client(transport), subscriptions: silentSubscriptionStore(transport))
        await coordinator.refreshContext()

        let cloud = try await coordinator.activateCloud(from: local, familyName: "Test Kid's family")
        XCTAssertTrue(cloud.hasValidReplica)
        XCTAssertEqual(cloud.snapshot().acceptedBalanceCents, 750)
        XCTAssertEqual(cloud.snapshot().activities.count, 2)

        transport.failEverything = true
        let relaunched = try LocalWalletRepository(directory: directory)
        let selected = WalletRepositoryFactory.select(
            local: relaunched,
            legacy: MockWalletRepository(),
            cloudClient: client(transport)
        )
        let relaunchedCloud = try XCTUnwrap(selected as? CloudWalletRepository)

        XCTAssertTrue(relaunchedCloud.hasValidReplica)
        XCTAssertEqual(relaunchedCloud.snapshot().acceptedBalanceCents, 750)
        XCTAssertEqual(relaunchedCloud.snapshot().activities.count, 2)
        XCTAssertTrue(relaunchedCloud.supportsRuntimeMutations)
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

    func testConfirmedContextKeepsReadOnlyCloudAuthorityWhenBootstrapFails() async throws {
        let local = try await localWalletWithHistory()
        let lineage = try XCTUnwrap(local.lineageID)
        let transport = RoutingTransport()
        transport.stub("GET", "/v1/cloud/context", CloudSliceFixtures.contextActive(lineage: lineage, revision: 2))
        let coordinator = CloudCoordinator(client: client(transport), subscriptions: silentSubscriptionStore(transport))
        let store = elevatedStore(repository: local, coordinator: coordinator)

        await store.recoverCloudEntitlements()
        let relaunched = try LocalWalletRepository(directory: directory)
        let selected = WalletRepositoryFactory.select(
            local: relaunched,
            legacy: MockWalletRepository(),
            cloudClient: client(transport)
        )

        XCTAssertTrue(store.repository is CloudWalletRepository)
        XCTAssertTrue(store.authorityState.isCloudAuthority)
        XCTAssertTrue(store.canModifyWallet)
        XCTAssertFalse(store.canStartParentMutation)
        XCTAssertEqual(store.snapshot.acceptedBalanceCents, 0)
        XCTAssertEqual(local.snapshot().acceptedBalanceCents, 750)
        XCTAssertTrue(store.cloudMessage?.contains("Cloud owns this wallet") == true)
        XCTAssertTrue(relaunched.isCloudAuthority)
        let relaunchedCloud = try XCTUnwrap(selected as? CloudWalletRepository)
        XCTAssertFalse(relaunchedCloud.hasValidReplica)
        XCTAssertEqual(relaunchedCloud.snapshot().acceptedBalanceCents, 0)
    }

    func testDifferentLineageCloudAuthorityHidesLocalDataUntilBootstrap() async throws {
        let local = try await localWalletWithHistory()
        _ = try await local.submit(WalletCommand(kind: .deposit, amountCents: 125))
        let localLineage = try XCTUnwrap(local.lineageID)
        let cloudLineage = UUID()
        let transport = RoutingTransport()
        transport.stub("GET", "/v1/cloud/context", CloudSliceFixtures.contextActive(lineage: cloudLineage, revision: 2))
        let coordinator = CloudCoordinator(client: client(transport), subscriptions: silentSubscriptionStore(transport))

        let adopted = try await coordinator.adoptExistingCloudHousehold(into: local)
        let cloud = try XCTUnwrap(adopted)

        XCTAssertEqual(local.lineageID, localLineage)
        XCTAssertEqual(local.cloudAuthorityLineageID, cloudLineage)
        XCTAssertEqual(local.snapshot().acceptedBalanceCents, 875)
        XCTAssertFalse(cloud.hasValidReplica)
        XCTAssertEqual(cloud.snapshot().acceptedBalanceCents, 0)
        XCTAssertTrue(cloud.snapshot().activities.isEmpty)

        let relaunched = try LocalWalletRepository(directory: directory)
        let selected = WalletRepositoryFactory.select(
            local: relaunched,
            legacy: MockWalletRepository(),
            cloudClient: client(transport)
        )
        let relaunchedCloud = try XCTUnwrap(selected as? CloudWalletRepository)

        XCTAssertEqual(relaunched.lineageID, localLineage)
        XCTAssertEqual(relaunched.cloudAuthorityLineageID, cloudLineage)
        XCTAssertEqual(relaunched.snapshot().acceptedBalanceCents, 875)
        XCTAssertFalse(relaunchedCloud.hasValidReplica)
        XCTAssertEqual(relaunchedCloud.snapshot().acceptedBalanceCents, 0)
        let unavailableStore = elevatedStore(repository: relaunchedCloud, coordinator: nil)
        XCTAssertFalse(unavailableStore.canShowWalletData)
        XCTAssertTrue(KidCopy.cloudReplicaUnavailableMessage(deviceNoun: "iPad").contains("reconnect"))
        XCTAssertTrue(ParentAreaView.cloudReplicaUnavailableMessage(deviceNoun: "iPad").contains("balance and activity"))
        XCTAssertTrue(CloudStatusView.cloudReplicaUnavailableStatusCopy(deviceNoun: "iPad").contains("Reconnect before"))
        do {
            _ = try await relaunchedCloud.submit(WalletCommand(kind: .deposit, amountCents: 25))
            XCTFail("a device without a valid Cloud replica must not write")
        } catch {
            XCTAssertTrue(error is WalletAPIError)
        }
        XCTAssertFalse(transport.requests.contains { $0.httpMethod == "POST" })

        transport.stub("GET", "/v1/cloud/bootstrap", CloudSliceFixtures.bootstrap(lineage: cloudLineage))
        _ = try await relaunchedCloud.refresh(for: .parent)

        XCTAssertTrue(relaunchedCloud.hasValidReplica)
        XCTAssertEqual(relaunchedCloud.snapshot().acceptedBalanceCents, 750)
        XCTAssertEqual(relaunched.lineageID, cloudLineage)
        XCTAssertEqual(relaunched.cloudAuthorityLineageID, cloudLineage)
    }

    func testValidZeroBalanceCloudReplicaStillShowsWalletData() async throws {
        let local = try LocalWalletRepository(directory: directory)
        let lineage = UUID()
        let transport = RoutingTransport()
        transport.stub("GET", "/v1/cloud/bootstrap", CloudSliceFixtures.zeroBalanceBootstrap(lineage: lineage))
        let cloud = CloudWalletRepository(client: client(transport), replica: local, lineageID: lineage, revision: 2)
        _ = try await cloud.bootstrap()
        let store = elevatedStore(repository: cloud, coordinator: nil)

        XCTAssertTrue(cloud.hasValidReplica)
        XCTAssertTrue(store.canShowWalletData)
        XCTAssertEqual(store.snapshot.acceptedBalanceCents, 0)
        XCTAssertTrue(store.snapshot.activities.isEmpty)
    }

    func testSuccessfulCloudWriteUsesIfMatchThenObservesTheStableEntry() async throws {
        let (cloud, transport, lineage) = try await writableCloud()
        transport.stub("POST", "/v1/wallet/deposits", CloudSliceFixtures.depositAccepted(revision: 3, entryID: "e-9"), status: 201)
        transport.stub("GET", "/v1/cloud/changes", CloudSliceFixtures.changes(lineage: lineage, revision: 3, balanceCents: 1_000, entryID: "e-9"))

        let command = WalletCommand(kind: .deposit, amountCents: 250, reason: "synthetic chores", idempotencyKey: "stable-write-key")
        guard case .accepted(let event) = try await cloud.submit(command) else {
            return XCTFail("the accepted entry must be observed before Recorded")
        }

        XCTAssertEqual(event.remoteID, "e-9")
        XCTAssertEqual(cloud.revision, 3)
        XCTAssertEqual(cloud.snapshot().acceptedBalanceCents, 1_000)
        XCTAssertFalse(cloud.hasUnsettledMutation)
        let request = try XCTUnwrap(transport.requests.first { $0.url?.path == "/v1/wallet/deposits" })
        XCTAssertEqual(request.value(forHTTPHeaderField: "If-Match"), "\"rev-2\"")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Idempotency-Key"), "stable-write-key")
        XCTAssertTrue(transport.requests.contains { $0.url?.path == "/v1/cloud/changes" && $0.url?.query == "afterRevision=2" })
    }

    func testAcceptedResponseWithoutEntryUsesAcceptedRevisionToProveObservation() async throws {
        let (cloud, transport, lineage) = try await writableCloud()
        transport.stub("POST", "/v1/wallet/deposits", CloudSliceFixtures.revisionAccepted(revision: 3), status: 201)
        transport.stub("GET", "/v1/cloud/changes", CloudSliceFixtures.changes(lineage: lineage, revision: 3, balanceCents: 1_000, entryID: "revision-entry"))

        guard case .accepted(let event) = try await cloud.submit(
            WalletCommand(kind: .deposit, amountCents: 250, idempotencyKey: "revision-fallback-key")
        ) else {
            return XCTFail("the accepted revision must resolve its exact ledger entry")
        }

        XCTAssertEqual(event.remoteID, "revision-entry")
        XCTAssertEqual(cloud.snapshot().acceptedBalanceCents, 1_000)
        XCTAssertFalse(cloud.hasUnsettledMutation)
    }

    func testAcceptedRevisionCanComeOnlyFromTheResponseETag() async throws {
        let (cloud, transport, lineage) = try await writableCloud()
        transport.stub(
            "POST",
            "/v1/wallet/deposits",
            Data("{}".utf8),
            status: 201,
            headers: ["ETag": "\"rev-3\""]
        )
        transport.stub("GET", "/v1/cloud/changes", CloudSliceFixtures.changes(lineage: lineage, revision: 3, balanceCents: 1_000, entryID: "etag-entry"))

        guard case .accepted(let event) = try await cloud.submit(
            WalletCommand(kind: .deposit, amountCents: 250, idempotencyKey: "etag-fallback-key")
        ) else {
            return XCTFail("the ETag revision must prove the exact observed write")
        }
        XCTAssertEqual(event.remoteID, "etag-entry")
    }

    func testResponseLossReplaysExactRequestAndObservesOneCommit() async throws {
        let (cloud, transport, lineage) = try await writableCloud()
        transport.stub("POST", "/v1/wallet/deposits", CloudSliceFixtures.depositAccepted(revision: 3, entryID: "lost-response-entry"), status: 201)
        transport.stub("GET", "/v1/cloud/changes", CloudSliceFixtures.changes(lineage: lineage, revision: 3, balanceCents: 1_000, entryID: "lost-response-entry"))
        transport.dropNextResponse("POST", "/v1/wallet/deposits")

        let command = WalletCommand(kind: .deposit, amountCents: 250, reason: "synthetic response loss", idempotencyKey: "response-loss-key")
        guard case .pending(let waiting, let attemptDiagnostic) = try await cloud.submit(command) else {
            return XCTFail("a lost response is unresolved, not rejected")
        }
        XCTAssertEqual(waiting.syncState, .pending)
        XCTAssertEqual(attemptDiagnostic?.category, .networkConnectionLost)
        XCTAssertEqual(attemptDiagnostic?.route, "/v1/wallet/deposits")
        XCTAssertTrue(cloud.hasUnsettledMutation)
        XCTAssertEqual(cloud.snapshot().acceptedBalanceCents, 750)

        _ = try await cloud.refresh(for: .parent)

        let writes = transport.requests.filter { $0.url?.path == "/v1/wallet/deposits" }
        XCTAssertEqual(writes.count, 2)
        XCTAssertEqual(writes[0].httpBody, writes[1].httpBody)
        XCTAssertEqual(Set(writes.compactMap { $0.value(forHTTPHeaderField: "Idempotency-Key") }), ["response-loss-key"])
        XCTAssertEqual(Set(writes.compactMap { $0.value(forHTTPHeaderField: "If-Match") }), ["\"rev-2\""])
        XCTAssertEqual(transport.committedMutationCount, 1)
        XCTAssertEqual(cloud.snapshot().activities.filter { $0.remoteID == "lost-response-entry" }.count, 1)
        XCTAssertEqual(cloud.snapshot().acceptedBalanceCents, 1_000)
        XCTAssertFalse(cloud.hasUnsettledMutation)
        XCTAssertEqual(attemptDiagnostic?.category, .networkConnectionLost)
        XCTAssertEqual(attemptDiagnostic?.route, "/v1/wallet/deposits")
    }

    func testServerCommandInProgressReplaysOnlyTheOriginalRequest() async throws {
        let (cloud, transport, lineage) = try await writableCloud()
        transport.enqueue("POST", "/v1/wallet/deposits", CloudSliceFixtures.commandInProgressError, status: 409)
        transport.enqueue("POST", "/v1/wallet/deposits", CloudSliceFixtures.depositAccepted(revision: 3, entryID: "in-progress-entry"), status: 201)
        transport.stub("GET", "/v1/cloud/changes", CloudSliceFixtures.changes(lineage: lineage, revision: 3, balanceCents: 1_000, entryID: "in-progress-entry"))

        guard case .pending = try await cloud.submit(
            WalletCommand(kind: .deposit, amountCents: 250, idempotencyKey: "in-progress-key")
        ) else {
            return XCTFail("COMMAND_IN_PROGRESS is ambiguous, not a rejection")
        }
        XCTAssertTrue(cloud.hasUnsettledMutation)
        _ = try await cloud.refresh(for: .parent)

        let writes = transport.requests.filter { $0.url?.path == "/v1/wallet/deposits" }
        XCTAssertEqual(writes.count, 2)
        XCTAssertEqual(writes[0].httpBody, writes[1].httpBody)
        XCTAssertEqual(Set(writes.compactMap { $0.value(forHTTPHeaderField: "Idempotency-Key") }), ["in-progress-key"])
        XCTAssertEqual(Set(writes.compactMap { $0.value(forHTTPHeaderField: "If-Match") }), ["\"rev-2\""])
        XCTAssertEqual(transport.committedMutationCount, 1)
        XCTAssertFalse(cloud.hasUnsettledMutation)
    }

    func testMalformedAcceptedResponseReplaysExactRequestWithoutContentInference() async throws {
        let (cloud, transport, lineage) = try await writableCloud()
        transport.enqueue("POST", "/v1/wallet/deposits", Data("{\"wallet\":{\"balanceCents\":1000}}".utf8), status: 201)
        transport.enqueue(
            "POST",
            "/v1/wallet/deposits",
            CloudSliceFixtures.depositAccepted(revision: 3, entryID: "malformed-replay-entry"),
            status: 201
        )
        transport.stub(
            "GET",
            "/v1/cloud/changes",
            CloudSliceFixtures.changes(
                lineage: lineage,
                revision: 3,
                balanceCents: 1_000,
                entryID: "malformed-replay-entry"
            )
        )

        guard case .pending = try await cloud.submit(
            WalletCommand(kind: .deposit, amountCents: 250, reason: "identical content", idempotencyKey: "malformed-key")
        ) else {
            return XCTFail("an unreadable proof must remain unresolved")
        }

        XCTAssertTrue(cloud.hasUnsettledMutation)
        XCTAssertEqual(cloud.snapshot().acceptedBalanceCents, 750)
        XCTAssertEqual(transport.requests.filter { $0.httpMethod == "POST" }.count, 1)

        _ = try await cloud.refresh(for: .parent)

        let writes = transport.requests.filter { $0.url?.path == "/v1/wallet/deposits" }
        XCTAssertEqual(writes.count, 2)
        XCTAssertEqual(writes[0].httpBody, writes[1].httpBody)
        XCTAssertEqual(Set(writes.compactMap { $0.value(forHTTPHeaderField: "Idempotency-Key") }), ["malformed-key"])
        XCTAssertEqual(Set(writes.compactMap { $0.value(forHTTPHeaderField: "If-Match") }), ["\"rev-2\""])
        XCTAssertEqual(transport.committedMutationCount, 1)
        XCTAssertFalse(cloud.hasUnsettledMutation)
        XCTAssertEqual(cloud.snapshot().activities.filter { $0.remoteID == "malformed-replay-entry" }.count, 1)
    }

    func testAcceptedWriteWithFailedReplicaPersistenceIsNeverReportedRejected() async throws {
        let persistence = CloudSliceFailingPersistence()
        let local = try LocalWalletRepository(persistence: persistence)
        let lineage = UUID()
        let transport = RoutingTransport()
        transport.stub("GET", "/v1/cloud/bootstrap", CloudSliceFixtures.bootstrap(lineage: lineage))
        transport.stub("POST", "/v1/wallet/deposits", CloudSliceFixtures.depositAccepted(revision: 3, entryID: "persistence-entry"), status: 201)
        transport.stub("GET", "/v1/cloud/changes", CloudSliceFixtures.changes(lineage: lineage, revision: 3, balanceCents: 1_000, entryID: "persistence-entry"))
        let cloud = CloudWalletRepository(client: client(transport), replica: local, lineageID: lineage, revision: 2)
        _ = try await cloud.bootstrap()
        // Stage, transport-attempt, and accepted-proof saves succeed. The
        // accepted replica save then fails after the server has accepted.
        persistence.failOnSaveNumber = persistence.saveCount + 4

        guard case .acceptedAwaitingReplica(let event, _) = try await cloud.submit(
            WalletCommand(kind: .deposit, amountCents: 250, idempotencyKey: "persistence-key")
        ) else {
            return XCTFail("local persistence failure after acceptance cannot become rejection")
        }

        XCTAssertTrue(event.explanation.contains("Cloud accepted"))
        XCTAssertTrue(cloud.hasUnsettledMutation)
        XCTAssertEqual(cloud.snapshot().acceptedBalanceCents, 750)
    }

    func testAcceptedWriteWithFailedRereadIsNeverReportedRejected() async throws {
        let (cloud, transport, _) = try await writableCloud()
        transport.stub("POST", "/v1/wallet/deposits", CloudSliceFixtures.depositAccepted(revision: 3, entryID: "accepted-unseen"), status: 201)
        transport.dropNextResponse("GET", "/v1/cloud/changes")

        guard case .acceptedAwaitingReplica(let event, _) = try await cloud.submit(
            WalletCommand(kind: .deposit, amountCents: 250, idempotencyKey: "accepted-unseen-key")
        ) else {
            return XCTFail("server acceptance plus failed reread needs its own truthful result")
        }

        XCTAssertEqual(event.syncState, .pending)
        XCTAssertTrue(event.explanation.contains("Cloud accepted"))
        XCTAssertTrue(cloud.hasUnsettledMutation)
        XCTAssertEqual(cloud.unsettledMutationPhase, .acceptedAwaitingReplica)
        XCTAssertEqual(cloud.snapshot().acceptedBalanceCents, 750)
    }

    func testReconciliationHTTPFailureKeepsKidStatusAndWaitingWallet() async throws {
        let (cloud, transport, _) = try await writableCloud()
        let store = elevatedStore(repository: cloud, coordinator: nil)
        await waitUntil("the Parent-area read settles") { !store.isLoading }
        transport.stub("POST", "/v1/wallet/deposits", Data("{}".utf8), status: 500)

        guard case .pending = await store.submit(
            WalletCommand(kind: .deposit, amountCents: 250, idempotencyKey: "http-waiting-key")
        ) else {
            return XCTFail("an HTTP failure cannot resolve an ambiguous Cloud mutation")
        }

        await store.refresh()

        XCTAssertTrue(cloud.hasUnsettledMutation)
        XCTAssertEqual(store.snapshot.acceptedBalanceCents, 750)
        XCTAssertEqual(store.connection, .reached)
        XCTAssertEqual(store.latestTransportDiagnostic?.httpStatus, 500)
        XCTAssertEqual(
            KidCopy.statusBanner(
                sessionExpired: store.sessionExpired,
                connection: store.connection,
                hasError: store.errorMessage != nil,
                lastUpdated: store.snapshot.lastUpdated
            ),
            KidCopy.couldNotUpdateBanner(lastUpdated: store.snapshot.lastUpdated)
        )
    }

    func testAcceptedProfileWriteWithFailedRereadIsDistinctFromRejection() async throws {
        let (cloud, transport, _) = try await writableCloud()
        transport.stub("PUT", "/v1/child", CloudSliceFixtures.profileAccepted(revision: 3), status: 200)
        transport.dropNextResponse("GET", "/v1/cloud/changes")
        let store = elevatedStore(repository: cloud, coordinator: nil)

        let saved = await store.updateChildProfile(nickname: "Synthetic Maya")

        XCTAssertFalse(saved, "the stale replica cannot claim the new name is already visible")
        XCTAssertEqual(store.latestParentMutationOutcome, .acceptedAwaitingReplica)
        XCTAssertNil(store.errorMessage)
        XCTAssertTrue(cloud.hasUnsettledMutation)
        XCTAssertEqual(store.snapshot.childNickname, "Test Kid")
    }

    func testExplicitConflictKeepsReplicaUnchangedAndRequiresReview() async throws {
        let (cloud, transport, _) = try await writableCloud()
        transport.stub("POST", "/v1/wallet/deposits", CloudSliceFixtures.revisionConflictError, status: 409)
        let store = elevatedStore(repository: cloud, coordinator: nil)

        guard case .rejected(let event) = await store.submit(
            WalletCommand(kind: .deposit, amountCents: 250, idempotencyKey: "stale-revision-key")
        ) else {
            return XCTFail("a 409 is an explicit rejection")
        }

        XCTAssertEqual(event.syncState, .rejected)
        XCTAssertTrue(store.needsCloudReview)
        XCTAssertEqual(store.snapshot.acceptedBalanceCents, 750)
        XCTAssertFalse(cloud.hasUnsettledMutation)
        XCTAssertFalse(store.canStartParentMutation)
    }

    func testDurableRejectionRetiresLocallyWithoutReplayAndUnblocksLaterWork() async throws {
        let persistence = CloudSliceFailingPersistence()
        let local = try LocalWalletRepository(persistence: persistence)
        let lineage = UUID()
        let transport = RoutingTransport()
        transport.stub("GET", "/v1/cloud/bootstrap", CloudSliceFixtures.bootstrap(lineage: lineage))
        transport.stub("POST", "/v1/wallet/deposits", CloudSliceFixtures.entitlementRequiredError, status: 403)
        let cloud = CloudWalletRepository(client: client(transport), replica: local, lineageID: lineage, revision: 2)
        _ = try await cloud.bootstrap()
        persistence.failOnSaveNumber = persistence.saveCount + 3

        do {
            _ = try await cloud.submit(
                WalletCommand(kind: .deposit, amountCents: 250, idempotencyKey: "durably-rejected-key")
            )
            XCTFail("the service explicitly rejected the command")
        } catch let error as WalletAPIError {
            XCTAssertEqual(error.operationError, .cloudEntitlementRequired)
            XCTAssertEqual(error.transportDiagnostic?.httpStatus, 403)
            XCTAssertEqual(error.transportDiagnostic?.route, "/v1/wallet/deposits")
        }

        let relaunchedLocal = try LocalWalletRepository(persistence: persistence)
        let relaunched = CloudWalletRepository(
            client: client(transport),
            replica: relaunchedLocal,
            lineageID: lineage,
            revision: 2
        )
        transport.stub(
            "POST",
            "/v1/wallet/deposits",
            CloudSliceFixtures.depositAccepted(revision: 3, entryID: "deliberate-later-entry"),
            status: 201
        )
        persistence.failNextSave = true

        do {
            _ = try await relaunched.refresh(for: .parent)
            XCTFail("failed terminal cleanup must remain unresolved")
        } catch {
            XCTAssertEqual(relaunched.unsettledMutationPhase, .rejected)
            XCTAssertEqual(error as? WalletAPIError, .cloudMutationAwaitingReconciliation)
        }
        XCTAssertTrue(relaunched.snapshot().pendingEvents.isEmpty)
        XCTAssertThrowsError(try relaunchedLocal.continueLocallyAfterCloud()) { error in
            XCTAssertEqual(error as? WalletAPIError, .cloudMutationAwaitingReconciliation)
        }
        XCTAssertEqual(
            transport.requests.filter { $0.url?.path == "/v1/wallet/deposits" }.count,
            1
        )

        do {
            _ = try await relaunched.refresh(for: .parent)
            XCTFail("successful cleanup must still surface the stored rejection")
        } catch WalletAPIError.server(let status, let code, _) {
            XCTAssertEqual(status, 403)
            XCTAssertEqual(code, "CLOUD_ENTITLEMENT_REQUIRED")
        }
        XCTAssertFalse(relaunched.hasUnsettledMutation)
        XCTAssertTrue(relaunched.snapshot().pendingEvents.isEmpty)
        XCTAssertEqual(
            transport.requests.filter { $0.url?.path == "/v1/wallet/deposits" }.count,
            1
        )

        transport.stub("GET", "/v1/cloud/changes", CloudSliceFixtures.revisionChanges(lineage: lineage, revision: 2))
        _ = try await relaunched.refresh(for: .parent)
        transport.stub(
            "GET",
            "/v1/cloud/changes",
            CloudSliceFixtures.changes(lineage: lineage, revision: 3, balanceCents: 1_000, entryID: "deliberate-later-entry")
        )
        guard case .accepted = try await relaunched.submit(
            WalletCommand(kind: .deposit, amountCents: 250, idempotencyKey: "deliberate-later-key")
        ) else {
            return XCTFail("a deliberate later action is allowed after terminal cleanup")
        }
        XCTAssertEqual(
            transport.requests.filter { $0.url?.path == "/v1/wallet/deposits" }.count,
            2
        )
        XCTAssertNoThrow(try relaunchedLocal.continueLocallyAfterCloud())
    }

    func testFailedTransportPhasePersistenceDoesNotSend() async throws {
        let persistence = CloudSliceFailingPersistence()
        let local = try LocalWalletRepository(persistence: persistence)
        let lineage = UUID()
        let transport = RoutingTransport()
        transport.stub("GET", "/v1/cloud/bootstrap", CloudSliceFixtures.bootstrap(lineage: lineage))
        transport.stub("POST", "/v1/wallet/deposits", CloudSliceFixtures.depositAccepted(revision: 3, entryID: "never-sent-entry"), status: 201)
        let cloud = CloudWalletRepository(client: client(transport), replica: local, lineageID: lineage, revision: 2)
        _ = try await cloud.bootstrap()
        persistence.failOnSaveNumber = persistence.saveCount + 2

        guard case .pending = try await cloud.submit(
            WalletCommand(kind: .deposit, amountCents: 250, idempotencyKey: "protected-before-send-key")
        ) else {
            return XCTFail("failed transport-phase persistence must remain locally staged")
        }

        XCTAssertEqual(cloud.unsettledMutationPhase, .staged)
        XCTAssertEqual(local.unsettledCloudMutation?.phase, .staged)
        XCTAssertFalse(transport.requests.contains { $0.httpMethod == "POST" })
    }

    func testRejectedPersistenceFailuresRemainWaitingUntilExactReplayIsAccepted() async throws {
        let persistence = CloudSliceFailingPersistence()
        let local = try LocalWalletRepository(persistence: persistence)
        let lineage = UUID()
        let transport = RoutingTransport()
        transport.stub("GET", "/v1/cloud/bootstrap", CloudSliceFixtures.bootstrap(lineage: lineage))
        transport.enqueue("POST", "/v1/wallet/deposits", CloudSliceFixtures.entitlementRequiredError, status: 403)
        transport.enqueue("POST", "/v1/wallet/deposits", CloudSliceFixtures.entitlementRequiredError, status: 403)
        transport.enqueue(
            "POST",
            "/v1/wallet/deposits",
            CloudSliceFixtures.depositAccepted(revision: 3, entryID: "accepted-after-waiting"),
            status: 201
        )
        let cloud = CloudWalletRepository(client: client(transport), replica: local, lineageID: lineage, revision: 2)
        _ = try await cloud.bootstrap()
        let firstMutationSave = persistence.saveCount + 1
        persistence.failOnSaveNumbers = [
            firstMutationSave + 2,
            firstMutationSave + 3,
            firstMutationSave + 4,
            firstMutationSave + 5,
        ]

        guard case .pending(let waiting, _) = try await cloud.submit(
            WalletCommand(kind: .deposit, amountCents: 250, idempotencyKey: "rejection-waiting-key")
        ) else {
            return XCTFail("a rejection without durable settlement must remain Waiting")
        }
        XCTAssertEqual(waiting.syncState, .pending)
        XCTAssertEqual(cloud.unsettledMutationPhase, .awaitingOutcome)
        XCTAssertEqual(local.unsettledCloudMutation?.phase, .awaitingOutcome)
        XCTAssertEqual(transport.requests.filter { $0.httpMethod == "POST" }.count, 1)

        let relaunchedLocal = try LocalWalletRepository(persistence: persistence)
        let relaunched = CloudWalletRepository(
            client: client(transport),
            replica: relaunchedLocal,
            lineageID: lineage,
            revision: 2
        )
        transport.stub(
            "GET",
            "/v1/cloud/changes",
            CloudSliceFixtures.changes(
                lineage: lineage,
                revision: 3,
                balanceCents: 1_000,
                entryID: "accepted-after-waiting"
            )
        )

        do {
            _ = try await relaunched.refresh(for: .parent)
            XCTFail("a repeated rejection without durable settlement stays Waiting")
        } catch {
            XCTAssertEqual(error as? WalletAPIError, .cloudMutationAwaitingReconciliation)
        }
        XCTAssertEqual(relaunched.unsettledMutationPhase, .awaitingOutcome)
        XCTAssertFalse(relaunched.snapshot().pendingEvents.isEmpty)

        _ = try await relaunched.refresh(for: .parent)

        let writes = transport.requests.filter { $0.url?.path == "/v1/wallet/deposits" }
        XCTAssertEqual(writes.count, 3)
        XCTAssertEqual(writes[0].httpBody, writes[1].httpBody)
        XCTAssertEqual(writes[1].httpBody, writes[2].httpBody)
        XCTAssertEqual(Set(writes.compactMap { $0.value(forHTTPHeaderField: "Idempotency-Key") }), ["rejection-waiting-key"])
        XCTAssertEqual(Set(writes.compactMap { $0.value(forHTTPHeaderField: "If-Match") }), ["\"rev-2\""])
        XCTAssertEqual(transport.committedMutationCount, 1)
        XCTAssertFalse(relaunched.hasUnsettledMutation)
        XCTAssertEqual(relaunched.snapshot().activities.filter { $0.remoteID == "accepted-after-waiting" }.count, 1)
    }

    func testScheduledAllowanceRejectsCallerAmountMismatchBeforeStaging() async throws {
        let (cloud, transport, _) = try await writableCloud()
        transport.stub("GET", "/v1/allowance-rule", CloudSliceFixtures.allowanceDue)

        do {
            _ = try await cloud.submit(
                WalletCommand(kind: .allowance, amountCents: 100, idempotencyKey: "wrong-allowance-key")
            )
            XCTFail("the fixed scheduled amount must not accept caller-invented metadata")
        } catch {
            XCTAssertEqual(error as? WalletAPIError, .invalidResponse("The allowance amount changed. Review the current schedule before recording it."))
        }

        XCTAssertFalse(cloud.hasUnsettledMutation)
        XCTAssertFalse(transport.requests.contains { $0.httpMethod == "POST" })
    }

    func testScheduledAllowanceStagesTheServerFixedAmountExactly() async throws {
        let (cloud, transport, _) = try await writableCloud()
        transport.stub("GET", "/v1/allowance-rule", CloudSliceFixtures.allowanceDue)
        transport.stub(
            "POST",
            "/v1/allowance-rule/a-1/occurrences/o-7/record",
            CloudSliceFixtures.depositAccepted(revision: 3, entryID: "allowance-entry"),
            status: 201
        )
        transport.dropNextResponse("POST", "/v1/allowance-rule/a-1/occurrences/o-7/record")

        guard case .pending(let event, _) = try await cloud.submit(
            WalletCommand(kind: .allowance, amountCents: 500, idempotencyKey: "exact-allowance-key")
        ) else {
            return XCTFail("the lost response should leave the exact scheduled amount waiting")
        }

        XCTAssertEqual(event.amountCents, 500)
        XCTAssertEqual(cloud.localReplica.unsettledCloudMutation?.amountCents, 500)
    }

    func testConcurrentIdenticalActionsDoNotShareIdentityOrSendTwice() async throws {
        let (cloud, transport, lineage) = try await writableCloud()
        transport.stub("POST", "/v1/wallet/deposits", CloudSliceFixtures.depositAccepted(revision: 3, entryID: "concurrent-entry"), status: 201)
        transport.stub("GET", "/v1/cloud/changes", CloudSliceFixtures.changes(lineage: lineage, revision: 3, balanceCents: 1_000, entryID: "concurrent-entry"))
        transport.suspend("POST", "/v1/wallet/deposits")

        let first = Task { try await cloud.submit(WalletCommand(kind: .deposit, amountCents: 250, reason: "same", idempotencyKey: "first-key")) }
        await transport.waitUntilSuspended()
        let second = try await cloud.submit(WalletCommand(kind: .deposit, amountCents: 250, reason: "same", idempotencyKey: "second-key"))
        guard case .rejected(let blocked) = second else {
            return XCTFail("the independent second action must be blocked, not folded into the first")
        }
        XCTAssertTrue(blocked.rejectionReason?.contains("previous Cloud change") == true)
        XCTAssertEqual(transport.requests.filter { $0.httpMethod == "POST" }.count, 1)

        transport.resumeSuspendedRequest()
        guard case .accepted = try await first.value else { return XCTFail("the first action should settle") }
        XCTAssertEqual(transport.requests.filter { $0.httpMethod == "POST" }.count, 1)
    }

    func testBackgroundRefreshDoesNotReplaySuspendedAcceptedMutation() async throws {
        let (cloud, transport, lineage) = try await writableCloud()
        transport.stub("POST", "/v1/wallet/deposits", CloudSliceFixtures.depositAccepted(revision: 3, entryID: "background-entry"), status: 201)
        transport.stub("GET", "/v1/cloud/changes", CloudSliceFixtures.changes(lineage: lineage, revision: 3, balanceCents: 1_000, entryID: "background-entry"))
        transport.suspend("POST", "/v1/wallet/deposits")
        let store = elevatedStore(repository: cloud, coordinator: nil)

        let submission = Task {
            await store.submit(
                WalletCommand(kind: .deposit, amountCents: 250, idempotencyKey: "background-accepted-key")
            )
        }
        await transport.waitUntilSuspended()
        store.handleAppBackgrounded()
        for _ in 0..<5 { await Task.yield() }

        XCTAssertEqual(transport.requests.filter { $0.httpMethod == "POST" }.count, 1)
        transport.resumeSuspendedRequest()

        guard case .accepted = await submission.value else {
            return XCTFail("the original suspended mutation should complete")
        }
        for _ in 0..<50 where store.snapshot.acceptedBalanceCents != 1_000 {
            await Task.yield()
        }
        XCTAssertEqual(transport.requests.filter { $0.httpMethod == "POST" }.count, 1)
        XCTAssertFalse(cloud.hasUnsettledMutation)
        XCTAssertEqual(cloud.snapshot().activities.filter { $0.remoteID == "background-entry" }.count, 1)
        XCTAssertEqual(store.snapshot.acceptedBalanceCents, 1_000)
        XCTAssertFalse(store.snapshot.isStale)
        XCTAssertEqual(store.connection, .reached)
        XCTAssertTrue(store.authorityState.isCloudAuthority)
    }

    func testBackgroundRefreshDoesNotReplaySuspendedDefinitiveRejection() async throws {
        let (cloud, transport, _) = try await writableCloud()
        transport.stub("POST", "/v1/wallet/deposits", CloudSliceFixtures.revisionConflictError, status: 409)
        transport.suspend("POST", "/v1/wallet/deposits")
        let store = elevatedStore(repository: cloud, coordinator: nil)

        let submission = Task {
            await store.submit(
                WalletCommand(kind: .deposit, amountCents: 250, idempotencyKey: "background-rejected-key")
            )
        }
        await transport.waitUntilSuspended()
        store.handleAppBackgrounded()
        for _ in 0..<5 { await Task.yield() }

        XCTAssertEqual(transport.requests.filter { $0.httpMethod == "POST" }.count, 1)
        transport.resumeSuspendedRequest()

        guard case .rejected = await submission.value else {
            return XCTFail("the original definitive result should remain rejected")
        }
        XCTAssertEqual(transport.requests.filter { $0.httpMethod == "POST" }.count, 1)
        XCTAssertFalse(cloud.hasUnsettledMutation)
        XCTAssertEqual(cloud.snapshot().acceptedBalanceCents, 750)
        XCTAssertEqual(store.snapshot.acceptedBalanceCents, 750)
        XCTAssertEqual(store.connection, .reached)
        XCTAssertFalse(store.snapshot.isStale)
        XCTAssertTrue(store.authorityState.isCloudAuthority)
    }

    func testSuspendedAmbiguousAttemptAllowsOneReplayOnlyAfterCompletion() async throws {
        let (cloud, transport, lineage) = try await writableCloud()
        transport.stub("POST", "/v1/wallet/deposits", CloudSliceFixtures.depositAccepted(revision: 3, entryID: "barrier-replay-entry"), status: 201)
        transport.stub("GET", "/v1/cloud/changes", CloudSliceFixtures.changes(lineage: lineage, revision: 3, balanceCents: 1_000, entryID: "barrier-replay-entry"))
        transport.suspend("POST", "/v1/wallet/deposits")
        transport.timeOutSuspendedResponse("POST", "/v1/wallet/deposits")

        let submission = Task {
            try await cloud.submit(
                WalletCommand(kind: .deposit, amountCents: 250, idempotencyKey: "barrier-replay-key")
            )
        }
        await transport.waitUntilSuspended()
        let overlappingRefresh = Task { try await cloud.refresh(for: .child) }
        for _ in 0..<5 { await Task.yield() }
        XCTAssertEqual(transport.requests.filter { $0.httpMethod == "POST" }.count, 1)

        transport.resumeSuspendedRequest()
        guard case .pending = try await submission.value else {
            return XCTFail("the timed-out original attempt is ambiguous")
        }
        do {
            _ = try await overlappingRefresh.value
            XCTFail("the joined ambiguous settlement must remain waiting")
        } catch let error as WalletAPIError {
            XCTAssertEqual(error.operationError, .cloudMutationAwaitingReconciliation)
            XCTAssertEqual(error.transportDiagnostic?.category, .timedOut)
            XCTAssertEqual(error.transportDiagnostic?.route, "/v1/wallet/deposits")
        } catch {
            XCTFail("the joined settlement should preserve its wallet failure")
        }
        XCTAssertEqual(transport.requests.filter { $0.httpMethod == "POST" }.count, 1)

        _ = try await cloud.refresh(for: .parent)

        let writes = transport.requests.filter { $0.url?.path == "/v1/wallet/deposits" }
        XCTAssertEqual(writes.count, 2)
        XCTAssertEqual(writes[0].httpBody, writes[1].httpBody)
        XCTAssertEqual(Set(writes.compactMap { $0.value(forHTTPHeaderField: "Idempotency-Key") }), ["barrier-replay-key"])
        XCTAssertEqual(Set(writes.compactMap { $0.value(forHTTPHeaderField: "If-Match") }), ["\"rev-2\""])
        XCTAssertFalse(cloud.hasUnsettledMutation)
    }

    func testSessionInvalidationIgnoresLateAcceptanceUntilRelaunchReplay() async throws {
        let (cloud, transport, lineage) = try await writableCloud()
        transport.stub("POST", "/v1/wallet/deposits", CloudSliceFixtures.depositAccepted(revision: 3, entryID: "session-replay-entry"), status: 201)
        transport.stub("GET", "/v1/cloud/changes", CloudSliceFixtures.changes(lineage: lineage, revision: 3, balanceCents: 1_000, entryID: "session-replay-entry"))
        transport.suspend("POST", "/v1/wallet/deposits")

        let submission = Task {
            try await cloud.submit(
                WalletCommand(kind: .deposit, amountCents: 250, idempotencyKey: "session-replay-key")
            )
        }
        await transport.waitUntilSuspended()
        cloud.clearAuthentication()
        transport.resumeSuspendedRequest()

        guard case .pending = try await submission.value else {
            return XCTFail("the late response must not settle an invalidated repository lifecycle")
        }
        XCTAssertEqual(cloud.snapshot().acceptedBalanceCents, 750)
        XCTAssertEqual(cloud.unsettledMutationPhase, .awaitingOutcome)
        XCTAssertEqual(transport.requests.filter { $0.httpMethod == "POST" }.count, 1)

        let relaunchedLocal = try LocalWalletRepository(directory: directory)
        let relaunched = CloudWalletRepository(
            client: client(transport),
            replica: relaunchedLocal,
            lineageID: lineage,
            revision: 2
        )
        _ = try await relaunched.refresh(for: .parent)

        let writes = transport.requests.filter { $0.url?.path == "/v1/wallet/deposits" }
        XCTAssertEqual(writes.count, 2)
        XCTAssertEqual(writes[0].httpBody, writes[1].httpBody)
        XCTAssertEqual(Set(writes.compactMap { $0.value(forHTTPHeaderField: "Idempotency-Key") }), ["session-replay-key"])
        XCTAssertEqual(transport.committedMutationCount, 1)
        XCTAssertFalse(relaunched.hasUnsettledMutation)
        XCTAssertEqual(relaunched.snapshot().activities.filter { $0.remoteID == "session-replay-entry" }.count, 1)
    }

    func testAuthorityChangeWhileMutationIsSuspendedIgnoresLateResponse() async throws {
        let (cloud, transport, _) = try await writableCloud()
        transport.stub("POST", "/v1/wallet/deposits", CloudSliceFixtures.depositAccepted(revision: 3, entryID: "ignored-authority-entry"), status: 201)
        transport.suspend("POST", "/v1/wallet/deposits")

        let submission = Task {
            try await cloud.submit(
                WalletCommand(kind: .deposit, amountCents: 250, idempotencyKey: "authority-change-key")
            )
        }
        await transport.waitUntilSuspended()
        let operationID = try XCTUnwrap(cloud.localReplica.unsettledCloudMutation?.operationID)
        try cloud.localReplica.clearCloudMutation(operationID: operationID)
        try cloud.localReplica.continueLocallyAfterCloud()
        transport.resumeSuspendedRequest()

        guard case .pending = try await submission.value else {
            return XCTFail("a late response cannot reclaim relinquished Cloud authority")
        }
        XCTAssertFalse(cloud.localReplica.isCloudAuthority)
        XCTAssertEqual(cloud.localReplica.snapshot().acceptedBalanceCents, 750)
        XCTAssertEqual(transport.requests.filter { $0.httpMethod == "POST" }.count, 1)
    }

    func testTimeoutBeforeReceiptCompletesOnlyOriginalRequestOnReplay() async throws {
        let (cloud, transport, lineage) = try await writableCloud()
        transport.stub("POST", "/v1/wallet/deposits", CloudSliceFixtures.depositAccepted(revision: 3, entryID: "timeout-entry"), status: 201)
        transport.stub("GET", "/v1/cloud/changes", CloudSliceFixtures.changes(lineage: lineage, revision: 3, balanceCents: 1_000, entryID: "timeout-entry"))
        transport.timeOutNextResponse("POST", "/v1/wallet/deposits")

        guard case .pending = try await cloud.submit(
            WalletCommand(kind: .deposit, amountCents: 250, idempotencyKey: "timeout-original-key")
        ) else {
            return XCTFail("a timeout is ambiguous")
        }
        guard case .rejected = try await cloud.submit(
            WalletCommand(kind: .deposit, amountCents: 250, idempotencyKey: "timeout-new-key")
        ) else {
            return XCTFail("a new action must be blocked until the timeout is reconciled")
        }
        XCTAssertEqual(transport.requests.filter { $0.httpMethod == "POST" }.count, 1)
        XCTAssertEqual(cloud.localReplica.unsettledCloudMutation?.idempotencyKey, "timeout-original-key")

        _ = try await cloud.refresh(for: .parent)

        let writes = transport.requests.filter { $0.url?.path == "/v1/wallet/deposits" }
        XCTAssertEqual(writes.count, 2)
        XCTAssertEqual(writes[0].httpBody, writes[1].httpBody)
        XCTAssertEqual(Set(writes.compactMap { $0.value(forHTTPHeaderField: "Idempotency-Key") }), ["timeout-original-key"])
        XCTAssertEqual(Set(writes.compactMap { $0.value(forHTTPHeaderField: "If-Match") }), ["\"rev-2\""])
        XCTAssertEqual(transport.committedMutationCount, 1)
        XCTAssertFalse(cloud.hasUnsettledMutation)
    }

    func testRelaunchReplaysOnlyPersistedBodyRevisionAndKey() async throws {
        let (cloud, transport, lineage) = try await writableCloud()
        transport.stub("POST", "/v1/wallet/deposits", CloudSliceFixtures.depositAccepted(revision: 3, entryID: "relaunched-entry"), status: 201)
        transport.stub("GET", "/v1/cloud/changes", CloudSliceFixtures.changes(lineage: lineage, revision: 3, balanceCents: 1_000, entryID: "relaunched-entry"))
        transport.dropNextResponse("POST", "/v1/wallet/deposits")

        guard case .pending = try await cloud.submit(
            WalletCommand(kind: .deposit, amountCents: 250, idempotencyKey: "relaunch-stable-key")
        ) else {
            return XCTFail("the first response is intentionally lost")
        }

        let relaunchedLocal = try LocalWalletRepository(directory: directory)
        let signedOutClient = CloudAPIClient(
            baseURL: Self.baseURL,
            sessionStore: InMemorySessionStore(),
            transport: transport
        )
        let selected = WalletRepositoryFactory.select(
            local: relaunchedLocal,
            legacy: MockWalletRepository(),
            cloudClient: signedOutClient
        )
        let signedOutRelaunch = try XCTUnwrap(selected as? CloudWalletRepository)
        XCTAssertTrue(signedOutRelaunch.hasUnsettledMutation)
        do {
            _ = try await signedOutRelaunch.refresh(for: .parent)
            XCTFail("missing session must not resolve the previous ambiguous attempt")
        } catch {
            XCTAssertEqual(error as? WalletAPIError, .noSession)
        }
        XCTAssertTrue(signedOutRelaunch.hasUnsettledMutation)
        XCTAssertNotNil(relaunchedLocal.unsettledCloudMutation)
        XCTAssertEqual(transport.requests.filter { $0.url?.path == "/v1/wallet/deposits" }.count, 1)

        let relaunched = CloudWalletRepository(
            client: client(transport),
            replica: relaunchedLocal,
            lineageID: lineage,
            revision: 2
        )
        _ = try await relaunched.refresh(for: .parent)

        let writes = transport.requests.filter { $0.url?.path == "/v1/wallet/deposits" }
        XCTAssertEqual(writes.count, 2)
        XCTAssertEqual(writes[0].httpBody, writes[1].httpBody)
        XCTAssertEqual(Set(writes.compactMap { $0.value(forHTTPHeaderField: "Idempotency-Key") }), ["relaunch-stable-key"])
        XCTAssertEqual(Set(writes.compactMap { $0.value(forHTTPHeaderField: "If-Match") }), ["\"rev-2\""])
        XCTAssertEqual(transport.committedMutationCount, 1)
        XCTAssertEqual(relaunched.snapshot().acceptedBalanceCents, 1_000)
        XCTAssertFalse(relaunched.hasUnsettledMutation)
    }

    func testAcceptedAllowanceRuleUsesRevisionObservation() async throws {
        let (cloud, transport, lineage) = try await writableCloud()
        transport.stub("PUT", "/v1/allowance-rule", CloudSliceFixtures.profileAccepted(revision: 3), status: 200)
        transport.stub("GET", "/v1/cloud/changes", CloudSliceFixtures.allowanceRuleChanges(lineage: lineage, revision: 3))

        let snapshot = try await cloud.setAllowance(
            AllowanceRuleCommand(amountCents: 600, weekday: 2, startDate: Date(timeIntervalSince1970: 1_800_000_000), idempotencyKey: "allowance-rule-key")
        )

        XCTAssertEqual(snapshot.allowance?.amountCents, 600)
        XCTAssertEqual(snapshot.allowance?.weekday, 2)
        XCTAssertEqual(cloud.revision, 3)
        XCTAssertFalse(cloud.hasUnsettledMutation)
    }

    func testUnsettledMutationBlocksEveryCloudToLocalAuthorityHandoff() async throws {
        let (cloud, transport, _) = try await writableCloud()
        transport.stub("POST", "/v1/wallet/deposits", CloudSliceFixtures.depositAccepted(revision: 3, entryID: "handoff-entry"), status: 201)
        transport.dropNextResponse("POST", "/v1/wallet/deposits")
        guard case .pending = try await cloud.submit(
            WalletCommand(kind: .deposit, amountCents: 250, idempotencyKey: "handoff-key")
        ) else {
            return XCTFail("the mutation should remain unresolved")
        }

        XCTAssertThrowsError(try cloud.localReplica.continueLocallyAfterCloud()) { error in
            XCTAssertEqual(error as? WalletAPIError, .cloudMutationAwaitingReconciliation)
        }
        XCTAssertTrue(cloud.localReplica.isCloudAuthority)
        let relaunchedLocal = try LocalWalletRepository(directory: directory)
        XCTAssertTrue(relaunchedLocal.isCloudAuthority)
        XCTAssertNotNil(relaunchedLocal.unsettledCloudMutation)
    }

    func testInFlightCloudRefreshCannotReclaimAuthorityAfterLocalHandoff() async throws {
        let (cloud, transport, lineage) = try await writableCloud()
        transport.stub(
            "GET",
            "/v1/cloud/changes",
            CloudSliceFixtures.changes(lineage: lineage, revision: 3, balanceCents: 1_000, entryID: "late-cloud-entry")
        )
        transport.suspend("GET", "/v1/cloud/changes")

        let refresh = Task { try await cloud.refresh(for: .parent) }
        await transport.waitUntilSuspended()
        try cloud.localReplica.continueLocallyAfterCloud()
        transport.resumeSuspendedRequest()

        do {
            _ = try await refresh.value
            XCTFail("a response from the relinquished Cloud lifecycle must be ignored")
        } catch {
            XCTAssertEqual(error as? WalletAPIError, .cancelled)
        }
        XCTAssertFalse(cloud.localReplica.isCloudAuthority)
        XCTAssertEqual(cloud.localReplica.snapshot().acceptedBalanceCents, 750)

        let relaunchedLocal = try LocalWalletRepository(directory: directory)
        let selected = WalletRepositoryFactory.select(
            local: relaunchedLocal,
            legacy: MockWalletRepository(),
            cloudClient: client(transport)
        )
        XCTAssertTrue(selected is LocalWalletRepository)
        XCTAssertFalse(relaunchedLocal.isCloudAuthority)
    }

    /// Repository reads are serialized: a second read does not even start
    /// until the first settles, so "an older read landing after a newer one"
    /// is no longer a representable state, and whatever revisions the answers
    /// carry, the accepted replica only ever moves forward.
    func testSerializedReadsCannotReverseCompletionOrRegressTheReplica() async throws {
        let (cloud, transport, lineage) = try await writableCloud()
        transport.enqueue(
            "GET",
            "/v1/cloud/changes",
            CloudSliceFixtures.changes(lineage: lineage, revision: 4, balanceCents: 1_200, entryID: "newer-entry")
        )
        transport.enqueue(
            "GET",
            "/v1/cloud/changes",
            CloudSliceFixtures.changes(lineage: lineage, revision: 3, balanceCents: 1_000, entryID: "older-entry")
        )
        transport.suspend("GET", "/v1/cloud/changes")

        let first = Task { try await cloud.refresh(for: .parent) }
        await transport.waitUntilSuspended()
        let second = Task { try await cloud.refresh(for: .parent) }
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(
            transport.requests.filter { $0.url?.path == "/v1/cloud/changes" }.count,
            1,
            "the second read waits its turn instead of racing the first on the wire"
        )
        transport.resumeSuspendedRequest()

        let firstSnapshot = try await first.value
        let secondSnapshot = try await second.value
        XCTAssertEqual(firstSnapshot.acceptedBalanceCents, 1_200)
        XCTAssertEqual(
            secondSnapshot.acceptedBalanceCents, 1_200,
            "an answer the accepted replica has overtaken is benign and reports the newer wallet"
        )
        XCTAssertEqual(cloud.revision, 4)
        XCTAssertEqual(cloud.snapshot().acceptedBalanceCents, 1_200)
        XCTAssertEqual(cloud.localReplica.cloudRevision, 4)
        XCTAssertTrue(cloud.isReadyForRuntimeMutations, "a benign overtaken answer takes nothing away")
    }

    /// The reported defect, reproduced: every Cloud request answered 200, and
    /// the kid home said "You're offline".
    ///
    /// Kid-home reads overlap by design, and the service can answer a
    /// later-started read from an older snapshot than one that already landed.
    /// That answer used to pass the read-generation test, reach the replica,
    /// be refused there for regressing the accepted revision, and arrive on the
    /// kid home as a connection failure - over the newer wallet that had
    /// already overtaken it.
    func testAnOvertakenCloudAnswerIsBenignAndNeverReadsAsAConnectionProblem() async throws {
        let (cloud, transport, lineage) = try await writableCloud()
        transport.stub("GET", "/v1/cloud/changes", CloudSliceFixtures.revisionChanges(lineage: lineage, revision: 2))
        let store = kidStore(repository: cloud)
        await waitUntilFirstReadSettles(store, transport)

        transport.stub(
            "GET",
            "/v1/cloud/changes",
            CloudSliceFixtures.changes(lineage: lineage, revision: 4, balanceCents: 1_200, entryID: "newer-entry")
        )
        transport.enqueue(
            "GET",
            "/v1/cloud/changes",
            CloudSliceFixtures.changes(lineage: lineage, revision: 3, balanceCents: 1_000, entryID: "overtaken-entry")
        )
        transport.suspend("GET", "/v1/cloud/changes")

        let newer = Task { await store.refresh() }
        await transport.waitUntilSuspended(count: 1)
        // The later-started read queues behind the suspended one; the service
        // answers it from an older snapshot once its turn comes.
        let overtaken = Task { await store.refresh() }
        transport.resumeSuspendedRequest()
        await newer.value
        await overtaken.value
        await waitUntil("the newer revision is accepted") { cloud.revision == 4 }

        XCTAssertEqual(cloud.revision, 4, "the accepted revision never regresses")
        XCTAssertEqual(cloud.localReplica.cloudRevision, 4)
        XCTAssertEqual(cloud.snapshot().acceptedBalanceCents, 1_200)
        XCTAssertTrue(cloud.isReadyForRuntimeMutations, "the newer read was a genuinely current one")
        XCTAssertEqual(store.snapshot.acceptedBalanceCents, 1_200, "the kid is shown the newer wallet")
        XCTAssertEqual(store.connection, .reached)
        XCTAssertNil(store.errorMessage, "an overtaken answer is nobody's failure")
        XCTAssertNil(kidStatusMessage(store), "nothing to tell the kid: this is the current wallet")
    }

    func testAnOlderResponseFromAnotherLineageIsNotTreatedAsBenign() async throws {
        let (cloud, transport, lineage) = try await writableCloud()
        transport.stub(
            "GET",
            "/v1/cloud/changes",
            CloudSliceFixtures.changes(lineage: lineage, revision: 4, balanceCents: 1_200)
        )
        _ = try await cloud.refresh(for: .parent)

        transport.stub(
            "GET",
            "/v1/cloud/changes",
            CloudSliceFixtures.changes(lineage: UUID(), revision: 3, balanceCents: 1_000)
        )

        do {
            _ = try await cloud.refresh(for: .parent)
            XCTFail("a different wallet history must not be accepted as an overtaken response")
        } catch let error as WalletAPIError {
            guard case .invalidResponse = error else {
                return XCTFail("expected an invalid Cloud response, got \(error)")
            }
        }

        XCTAssertEqual(cloud.revision, 4)
        XCTAssertEqual(cloud.localReplica.cloudRevision, 4)
        XCTAssertEqual(cloud.snapshot().acceptedBalanceCents, 1_200)
        XCTAssertFalse(cloud.isReadyForRuntimeMutations)
    }

    /// A 200 whose body this app cannot read is still a wallet that answered.
    /// Calling that offline - or hard to reach - is the same false claim.
    func testACloudAnswerThatCannotBeReadClearsAnEarlierOfflineClassification() async throws {
        let (cloud, transport, _) = try await writableCloud()
        let acceptedSnapshot = cloud.snapshot()
        let acceptedRevision = cloud.localReplica.cloudRevision
        transport.failEverything = true
        let store = kidStore(repository: cloud)
        await waitUntil("the genuinely offline read settles") {
            transport.requests.contains { $0.url?.path == "/v1/cloud/changes" }
                && !store.isLoading
                && store.connection == .deviceOffline
        }

        XCTAssertEqual(kidStatusMessage(store), KidCopy.offlineBanner(lastUpdated: store.snapshot.lastUpdated))
        XCTAssertFalse(cloud.isReadyForRuntimeMutations)

        transport.failEverything = false
        transport.stub("GET", "/v1/cloud/changes", Data(#"{"household":{"lineageId":"#.utf8))
        await store.refresh()

        XCTAssertEqual(store.connection, .reached, "a body arrived, so the service was reached")
        XCTAssertEqual(store.latestTransportDiagnostic?.category, .unreadableResponse)
        XCTAssertEqual(store.latestTransportDiagnostic?.httpStatus, 200)
        XCTAssertEqual(store.latestTransportDiagnostic?.route, "/v1/cloud/changes")
        XCTAssertNotNil(store.errorMessage, "the parent still learns the read did not land")
        XCTAssertEqual(kidStatusMessage(store), KidCopy.couldNotUpdateBanner(lastUpdated: store.snapshot.lastUpdated))
        XCTAssertNotEqual(kidStatusMessage(store), KidCopy.offlineBanner(lastUpdated: store.snapshot.lastUpdated))
        XCTAssertNotEqual(kidStatusMessage(store), KidCopy.cannotReachBanner(lastUpdated: store.snapshot.lastUpdated))
        XCTAssertEqual(store.snapshot, acceptedSnapshot, "the last accepted wallet stays on screen")
        XCTAssertEqual(cloud.localReplica.cloudRevision, acceptedRevision, "an unreadable answer changes no accepted state")
        XCTAssertFalse(cloud.isReadyForRuntimeMutations, "no write until a current read is confirmed again")
    }

    func testRelaunchAndFailedRefreshCannotWriteFromAStaleReplica() async throws {
        let (cloud, _, lineage) = try await writableCloud()
        XCTAssertTrue(cloud.isReadyForRuntimeMutations)
        let relaunchedLocal = try LocalWalletRepository(directory: directory)

        let transport = RoutingTransport()
        transport.failEverything = true
        let relaunched = CloudWalletRepository(
            client: client(transport),
            replica: relaunchedLocal,
            lineageID: lineage,
            revision: 2
        )
        XCTAssertTrue(relaunched.hasValidReplica)
        XCTAssertFalse(relaunched.isReadyForRuntimeMutations)

        do {
            _ = try await relaunched.submit(
                WalletCommand(kind: .deposit, amountCents: 250, idempotencyKey: "stale-relaunch-key")
            )
            XCTFail("a persisted replica must be refreshed before it can write")
        } catch {
            XCTAssertEqual(error as? WalletAPIError, .revisionRequired)
        }
        XCTAssertFalse(relaunched.hasUnsettledMutation)
        XCTAssertFalse(transport.requests.contains { $0.httpMethod == "POST" })

        do {
            _ = try await relaunched.refresh(for: .parent)
            XCTFail("the synthetic refresh is offline")
        } catch {
            XCTAssertFalse(relaunched.isReadyForRuntimeMutations)
        }
        XCTAssertEqual(relaunched.snapshot().acceptedBalanceCents, 750)

        transport.failEverything = false
        transport.stub("GET", "/v1/cloud/changes", CloudSliceFixtures.revisionChanges(lineage: lineage, revision: 2))
        _ = try await relaunched.refresh(for: .parent)
        XCTAssertTrue(relaunched.isReadyForRuntimeMutations)
    }

    func testKnownOfflineCloudReplicaStaysReadableAndDoesNotQueueANewAction() async throws {
        let (cloud, transport, _) = try await writableCloud()
        let store = elevatedStore(repository: cloud, coordinator: nil)
        transport.failEverything = true
        await store.refresh()
        await waitUntil("the newest overlapping Cloud read reports the outage") { store.connection == .deviceOffline }

        XCTAssertEqual(store.connection, .deviceOffline)
        XCTAssertEqual(store.snapshot.acceptedBalanceCents, 750)
        XCTAssertTrue(cloud.hasValidReplica)
        XCTAssertFalse(cloud.isReadyForRuntimeMutations)
        XCTAssertFalse(store.canStartParentMutation)
        guard case .rejected(let event) = await store.submit(
            WalletCommand(kind: .deposit, amountCents: 250, idempotencyKey: "offline-new-key")
        ) else {
            return XCTFail("known-offline Cloud should ask for reconnect instead of staging a new request")
        }
        XCTAssertTrue(event.rejectionReason?.contains("Reconnect") == true)
        XCTAssertFalse(cloud.hasUnsettledMutation)
        XCTAssertFalse(transport.requests.contains { $0.httpMethod == "POST" })
    }

    /// The reported 0.1.14 parent-area defect, at the state boundary it broke.
    ///
    /// SwiftUI owns the task behind a pull-to-refresh and ends it, so an
    /// ordinary parent pull can kill its own read in flight. That read observed
    /// no answer at all, so it proves nothing about whether this device's
    /// confirmed revision is still current - and it used to withdraw write
    /// readiness anyway. `WalletStore` correctly published nothing for it, so
    /// the parent was left with every money action disabled, a green "syncing
    /// with Cloud" line beside them, no error, and - no review being pending -
    /// nothing on screen that could clear it.
    func testAParentPullCancelledInFlightKeepsTheWalletWritableAndInSync() async throws {
        let (cloud, transport, lineage) = try await writableCloud()
        transport.stub("GET", "/v1/cloud/changes", CloudSliceFixtures.revisionChanges(lineage: lineage, revision: 2))
        let store = syncedParentStore(cloud, lineage: lineage)
        await waitUntilFirstReadSettles(store, transport)
        XCTAssertNil(store.parentMutationBlock)
        XCTAssertTrue(store.isSyncedWithCloud)

        transport.suspend("GET", "/v1/cloud/changes")
        let pull = Task { await store.refresh() }
        await transport.waitUntilSuspended(count: 1)
        pull.cancel()
        transport.resumeSuspendedRequest()
        await pull.value

        XCTAssertNil(store.parentMutationBlock, "a read that observed nothing must not take write access away")
        XCTAssertTrue(store.canStartParentMutation)
        XCTAssertTrue(store.isSyncedWithCloud, "and it must not change what the Cloud card claims either")
        XCTAssertTrue(cloud.isReadyForRuntimeMutations)
        XCTAssertEqual(store.connection, .reached)
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(store.snapshot.acceptedBalanceCents, 750, "the accepted wallet is untouched")
        XCTAssertNil(kidStatusMessage(store), "the kid home stays silent for a cancelled read too")
    }

    /// The first of the three 0.1.14-series races, now unrepresentable: a
    /// newer pull whose caller stopped waiting used to take publication
    /// ownership with it, leaving an older read's successful answer silenced
    /// forever - a stale wallet with no publisher left. The store owns every
    /// read: a cancelled caller stops waiting and nothing else, so the pull's
    /// read still settles and, as the newest, still publishes.
    func testACancelledNewerPullCannotSuppressWhatTheWalletWasTold() async throws {
        let (cloud, transport, lineage) = try await writableCloud()
        transport.stub("GET", "/v1/cloud/changes", CloudSliceFixtures.revisionChanges(lineage: lineage, revision: 2))
        let store = syncedParentStore(cloud, lineage: lineage)
        await waitUntilFirstReadSettles(store, transport)

        transport.stub(
            "GET",
            "/v1/cloud/changes",
            CloudSliceFixtures.changes(lineage: lineage, revision: 3, balanceCents: 1_000, entryID: "fresh-entry")
        )
        transport.suspend("GET", "/v1/cloud/changes")
        let older = Task { await store.refresh() }
        await transport.waitUntilSuspended(count: 1)
        let pull = Task { await store.refresh() }
        // SwiftUI ends the task behind a pull-to-refresh: the caller is gone
        // before its read even reached the wire.
        pull.cancel()
        transport.resumeSuspendedRequest()
        await older.value
        await pull.value

        XCTAssertEqual(store.snapshot.acceptedBalanceCents, 1_000, "the newest read still published the fresh wallet")
        XCTAssertEqual(cloud.revision, 3)
        XCTAssertEqual(store.connection, .reached)
        XCTAssertNil(store.errorMessage)
        XCTAssertTrue(cloud.isReadyForRuntimeMutations)
        XCTAssertTrue(store.canStartParentMutation, "no gesture can take write access away with it")
        XCTAssertTrue(store.isSyncedWithCloud)
        XCTAssertNil(store.parentMutationBlock)
        XCTAssertNil(kidStatusMessage(store), "nothing to tell the kid: this is the current wallet")
    }

    /// The third of the three 0.1.14-series races, now unrepresentable: a
    /// read that began before a conflict - or a service still answering from
    /// its pre-conflict snapshot - can never end the review the conflict
    /// raised. A review ends only at or past the revision the refusal named,
    /// and the accepted revision is monotonic, so a pre-conflict balance sits
    /// below that floor by definition, however its read was delayed,
    /// reordered, or repeated.
    func testAPreConflictReadCanNeverEndTheReviewTheConflictRaised() async throws {
        let (cloud, transport, lineage) = try await writableCloud()
        transport.stub("GET", "/v1/cloud/changes", CloudSliceFixtures.revisionChanges(lineage: lineage, revision: 2))
        let store = syncedParentStore(cloud, lineage: lineage)
        await waitUntilFirstReadSettles(store, transport)

        // A pull is already in flight when the conflict arrives, and for a
        // while the service keeps answering every read from its pre-conflict
        // snapshot - while the 409 itself proves revision 7 exists.
        transport.suspend("GET", "/v1/cloud/changes")
        let preConflictPull = Task { await store.refresh() }
        await transport.waitUntilSuspended(count: 1)
        transport.stub("POST", "/v1/wallet/deposits", CloudSliceFixtures.revisionConflictError, status: 409)
        _ = await store.submit(WalletCommand(kind: .deposit, amountCents: 250, idempotencyKey: "pre-conflict-key"))
        XCTAssertTrue(store.needsCloudReview)
        transport.resumeSuspendedRequest()
        await preConflictPull.value
        await waitUntil("the conflict's own reread settles") { !store.isLoading }

        // The parent asks to review, but every read still lands revision 2.
        // No balance at or past the conflict has been shown, so the review
        // stands, with the same control still offered.
        await store.clearParentMutationBlock()
        XCTAssertTrue(store.needsCloudReview, "a pre-conflict balance must never end the review")
        XCTAssertEqual(store.parentMutationBlock, .awaitingReview)
        XCTAssertFalse(store.canStartParentMutation)
        XCTAssertFalse(store.isSyncedWithCloud)

        // Only the post-conflict wallet the refusal named can end it.
        transport.stub(
            "GET",
            "/v1/cloud/changes",
            CloudSliceFixtures.changes(lineage: lineage, revision: 7, balanceCents: 1_450, entryID: "conflict-winner")
        )
        await store.clearParentMutationBlock()
        XCTAssertFalse(store.needsCloudReview)
        XCTAssertNil(store.parentMutationBlock)
        XCTAssertEqual(store.snapshot.acceptedBalanceCents, 1_450, "the reviewed balance is the post-conflict one")
        XCTAssertTrue(store.canStartParentMutation)
    }

    /// A recovery whose own read fails leaves the review standing - and leaves
    /// the same control offered, so the parent is never dead-ended. The next
    /// recovery that lands a balance at the review's floor ends it.
    func testAFailedRecoveryLeavesTheReviewStandingWithItsControlStillOffered() async throws {
        let (cloud, transport, lineage) = try await writableCloud()
        transport.stub("GET", "/v1/cloud/changes", CloudSliceFixtures.revisionChanges(lineage: lineage, revision: 2))
        let store = syncedParentStore(cloud, lineage: lineage)
        await waitUntilFirstReadSettles(store, transport)

        transport.stub("POST", "/v1/wallet/deposits", CloudSliceFixtures.revisionConflictError, status: 409)
        _ = await store.submit(WalletCommand(kind: .deposit, amountCents: 250, idempotencyKey: "overlapping-review-key"))
        await waitUntil("the conflict's own reread settles") { !store.isLoading }
        XCTAssertEqual(store.parentMutationBlock, .awaitingReview)

        transport.failEverything = true
        await store.clearParentMutationBlock()
        XCTAssertTrue(store.needsCloudReview, "a failed read showed no balance to review")
        XCTAssertNotNil(store.parentMutationBlock, "the block still names the guard that is holding")
        XCTAssertEqual(store.parentMutationBlock?.recovery, .readLatest, "and keeps offering its own way out")
        XCTAssertFalse(store.canStartParentMutation)

        transport.failEverything = false
        transport.stub(
            "GET",
            "/v1/cloud/changes",
            CloudSliceFixtures.changes(lineage: lineage, revision: 7, balanceCents: 1_450, entryID: "reviewed-entry")
        )
        await store.clearParentMutationBlock()
        XCTAssertFalse(store.needsCloudReview)
        XCTAssertNil(store.parentMutationBlock)
        XCTAssertTrue(store.canStartParentMutation)
    }

    /// A write attempted from a replica no read has confirmed is refused before
    /// transport and raises the review. A read that started before that
    /// refusal cannot end it - no read ends a review by itself - and the
    /// parent's own recovery, once a balance actually lands, does.
    func testAWriteFromAnUnconfirmedReplicaRaisesAReviewOnlyItsRecoveryEnds() async throws {
        let (cloud, transport, lineage) = try await writableCloud()
        transport.stub("GET", "/v1/cloud/changes", CloudSliceFixtures.revisionChanges(lineage: lineage, revision: 2))
        let store = syncedParentStore(cloud, lineage: lineage)
        await waitUntilFirstReadSettles(store, transport)

        // An answer this device could not read withdraws the confirmation.
        transport.stub("GET", "/v1/cloud/changes", Data(#"{"household":{"lineageId":"#.utf8))
        await store.refresh()
        XCTAssertFalse(cloud.isReadyForRuntimeMutations)
        XCTAssertEqual(store.connection, .reached)
        XCTAssertEqual(store.parentMutationBlock, .revisionUnconfirmed)

        // A pull is in flight when the parent tries to record anyway.
        transport.stub("GET", "/v1/cloud/changes", CloudSliceFixtures.revisionChanges(lineage: lineage, revision: 2))
        transport.suspend("GET", "/v1/cloud/changes")
        let preRefusalRead = Task { await store.refresh() }
        await transport.waitUntilSuspended(count: 1)
        _ = await store.submit(
            WalletCommand(kind: .deposit, amountCents: 250, idempotencyKey: "readiness-review-key")
        )
        XCTAssertEqual(store.parentMutationBlock, .awaitingReview)
        XCTAssertFalse(transport.requests.contains { $0.httpMethod == "POST" }, "nothing was sent from a stale replica")

        transport.resumeSuspendedRequest()
        await preRefusalRead.value
        XCTAssertTrue(store.needsCloudReview, "a read that landed on its own ends no review")
        XCTAssertEqual(store.parentMutationBlock, .awaitingReview)

        await store.clearParentMutationBlock()
        await waitUntil("the recovery's own read lands") { store.parentMutationBlock == nil }
        XCTAssertFalse(store.needsCloudReview)
        XCTAssertTrue(store.canStartParentMutation)
    }

    /// The safety half of the same guard: a read that did observe something and
    /// still could not confirm this replica must keep blocking a protected
    /// write. Only an attempt that saw nothing is treated as having happened
    /// at all.
    func testAReadThatObservedAnAnswerItCouldNotUseStillBlocksTheNextWrite() async throws {
        let (cloud, transport, lineage) = try await writableCloud()
        transport.stub("GET", "/v1/cloud/changes", CloudSliceFixtures.revisionChanges(lineage: lineage, revision: 2))
        let store = syncedParentStore(cloud, lineage: lineage)
        await waitUntilFirstReadSettles(store, transport)
        XCTAssertNil(store.parentMutationBlock)

        transport.stub("GET", "/v1/cloud/changes", Data(#"{"household":{"lineageId":"#.utf8))
        await store.refresh()

        XCTAssertFalse(cloud.isReadyForRuntimeMutations, "an answer this device could not read confirms nothing")
        XCTAssertEqual(store.connection, .reached, "a body arrived, so the service was reached")
        XCTAssertEqual(store.parentMutationBlock, .revisionUnconfirmed)
        XCTAssertFalse(store.canStartParentMutation)
        XCTAssertFalse(store.isSyncedWithCloud)

        transport.failEverything = true
        await store.refresh()
        XCTAssertEqual(store.parentMutationBlock, .authorityUnreached, "an unreached authority is its own reason")
        XCTAssertFalse(store.isSyncedWithCloud)
    }

    /// The green "syncing with Cloud" claim and the money controls now read the
    /// same evidence, so no genuinely blocked state can be presented as a
    /// device that is in sync. 0.1.14 derived them independently and showed
    /// both at once.
    func testTheSyncClaimIsNeverTrueWhileAProtectedWriteIsBlocked() async throws {
        let (cloud, transport, lineage) = try await writableCloud()
        transport.stub("GET", "/v1/cloud/changes", CloudSliceFixtures.revisionChanges(lineage: lineage, revision: 2))
        let store = syncedParentStore(cloud, lineage: lineage)
        await waitUntilFirstReadSettles(store, transport)
        assertSyncClaimAgreesWithTheWriteGuard(store, "a healthy synced wallet")

        for entitlement in [CloudEntitlementState.expired, .revoked] {
            store.applyDebugCloudState(
                authority: .cloud(lineageID: lineage, revision: 2),
                entitlement: entitlement
            )
            XCTAssertFalse(store.isSyncedWithCloud)
            XCTAssertFalse(store.canStartParentMutation)
            XCTAssertEqual(store.parentMutationBlock, .planInactive)
            assertSyncClaimAgreesWithTheWriteGuard(store, "an inactive Cloud plan")
        }
        store.applyDebugCloudState(
            authority: .cloud(lineageID: lineage, revision: 2),
            entitlement: .active(accessUntil: .distantFuture, autoRenewEnabled: true)
        )

        transport.failEverything = true
        await store.refresh()
        await waitUntil("the unreachable read settles") { store.connection == .deviceOffline }
        assertSyncClaimAgreesWithTheWriteGuard(store, "an unreachable authority")

        transport.failEverything = false
        transport.stub("GET", "/v1/cloud/changes", Data(#"{"household":{"lineageId":"#.utf8))
        await store.refresh()
        assertSyncClaimAgreesWithTheWriteGuard(store, "an unreadable answer")

        transport.stub("GET", "/v1/cloud/changes", CloudSliceFixtures.revisionChanges(lineage: lineage, revision: 2))
        await store.refresh()
        XCTAssertTrue(store.canStartParentMutation, "a good read makes the wallet writable again")
        transport.stub("POST", "/v1/wallet/deposits", CloudSliceFixtures.revisionConflictError, status: 409)
        _ = await store.submit(WalletCommand(kind: .deposit, amountCents: 250, idempotencyKey: "conflict-key"))
        await waitUntil("the conflict's own reread settles") { !store.isLoading }
        XCTAssertTrue(store.needsCloudReview)
        assertSyncClaimAgreesWithTheWriteGuard(store, "a wallet waiting to be reviewed")
    }

    /// Every block a parent can land in has to carry its own way out. The
    /// confirmed dead end was a block whose reason was not a pending review:
    /// the Cloud card's `Got it` is shown for a review alone, so nothing on
    /// screen could clear it and only relaunching the app recovered.
    func testEveryBlockedParentStateNamesItsReasonAndOffersAClearThatRecovers() async throws {
        let (cloud, transport, lineage) = try await writableCloud()
        transport.stub("GET", "/v1/cloud/changes", CloudSliceFixtures.revisionChanges(lineage: lineage, revision: 2))
        let store = syncedParentStore(cloud, lineage: lineage)
        await waitUntilFirstReadSettles(store, transport)

        transport.failEverything = true
        await store.refresh()
        await waitUntil("the unreachable read settles") { store.connection == .deviceOffline }
        let unreached = try XCTUnwrap(store.parentMutationBlock)
        XCTAssertEqual(unreached, .authorityUnreached)
        XCTAssertEqual(unreached.recovery, .readLatest, "the parent's own control must be able to lift it")
        XCTAssertFalse(unreached.recoveryActionTitle.isEmpty)

        transport.failEverything = false
        await store.clearParentMutationBlock()
        XCTAssertNil(store.parentMutationBlock, "the block's own control recovers without leaving the screen")
        XCTAssertTrue(store.canStartParentMutation)

        transport.stub("POST", "/v1/wallet/deposits", CloudSliceFixtures.revisionConflictError, status: 409)
        _ = await store.submit(WalletCommand(kind: .deposit, amountCents: 250, idempotencyKey: "review-key"))
        await waitUntil("the conflict's own reread settles") { !store.isLoading }
        XCTAssertEqual(store.parentMutationBlock, .awaitingReview)

        // The 409 named revision 7, so only a wallet at or past it counts as
        // "the latest balance" for this review.
        transport.stub(
            "GET",
            "/v1/cloud/changes",
            CloudSliceFixtures.changes(lineage: lineage, revision: 7, balanceCents: 1_450, entryID: "conflict-winner")
        )
        await store.clearParentMutationBlock()
        await waitUntil("the reviewed balance to land") { store.parentMutationBlock == nil }
        XCTAssertNil(store.parentMutationBlock, "reviewing the latest balance clears the review")
        XCTAssertTrue(store.canStartParentMutation)
        XCTAssertTrue(store.isSyncedWithCloud)
    }

    /// A review may only end against a balance the parent was actually shown.
    /// A recovery whose read never landed leaves the block exactly as it was.
    func testAClearWhoseReadNeverLandedLeavesTheReviewStanding() async throws {
        let (cloud, transport, lineage) = try await writableCloud()
        transport.stub("GET", "/v1/cloud/changes", CloudSliceFixtures.revisionChanges(lineage: lineage, revision: 2))
        let store = syncedParentStore(cloud, lineage: lineage)
        await waitUntilFirstReadSettles(store, transport)

        transport.stub("POST", "/v1/wallet/deposits", CloudSliceFixtures.revisionConflictError, status: 409)
        _ = await store.submit(WalletCommand(kind: .deposit, amountCents: 250, idempotencyKey: "unread-review-key"))
        await waitUntil("the conflict's own reread settles") { !store.isLoading }
        XCTAssertEqual(store.parentMutationBlock, .awaitingReview)

        transport.failEverything = true
        await store.clearParentMutationBlock()

        XCTAssertTrue(store.needsCloudReview, "no read landed, so there is no reviewed balance to accept")
        XCTAssertFalse(store.canStartParentMutation)
        XCTAssertNotNil(store.parentMutationBlock)
    }

    private func assertSyncClaimAgreesWithTheWriteGuard(
        _ store: WalletStore,
        _ state: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(
            store.isSyncedWithCloud,
            store.canStartParentMutation,
            "\(state): a syncing claim and a usable money control must never disagree",
            file: file,
            line: line
        )
        XCTAssertEqual(
            store.parentMutationBlock == nil,
            store.canStartParentMutation,
            "\(state): a blocked control must always have a named reason",
            file: file,
            line: line
        )
    }

    /// An elevated parent on a Cloud device whose plan is active - the state the
    /// captain reported from, and the only one in which the green sync line is
    /// offered at all.
    private func syncedParentStore(
        _ cloud: CloudWalletRepository,
        lineage: UUID
    ) -> WalletStore {
        let store = elevatedStore(repository: cloud, coordinator: nil)
        store.applyDebugCloudState(
            authority: .cloud(lineageID: lineage, revision: 2),
            entitlement: .active(accessUntil: .distantFuture, autoRenewEnabled: true)
        )
        return store
    }

    func testNonUUIDCloudEntryKeepsStableLocalIdentity() throws {
        let lineage = UUID()
        let data = CloudSliceFixtures.changes(
            lineage: lineage,
            revision: 3,
            balanceCents: 1_000,
            entryID: "server-entry-not-a-uuid"
        )
        let replica = try JSONDecoder.cloud.decode(CloudReplica.self, from: data)

        let first = CloudReplicaMapper.snapshot(from: replica, mergingInto: [], fallbackNickname: nil)
        let second = CloudReplicaMapper.snapshot(from: replica, mergingInto: [], fallbackNickname: nil)

        XCTAssertEqual(first.activities.first?.id, second.activities.first?.id)
        XCTAssertEqual(first.activities.first?.remoteID, "server-entry-not-a-uuid")
    }

    // MARK: - Expiry, sign-out, outage

    func testExpiredCloudOffersLocalContinuationWithoutLosingTheReplica() async throws {
        let local = try LocalWalletRepository(directory: directory)
        let lineage = UUID()
        let transport = RoutingTransport()
        transport.stub("GET", "/v1/cloud/bootstrap", CloudSliceFixtures.bootstrap(lineage: lineage))
        transport.stub("GET", "/v1/cloud/context", CloudSliceFixtures.contextExpired(lineage: lineage))
        let cloudClient = client(transport)
        let cloud = CloudWalletRepository(client: cloudClient, replica: local, lineageID: lineage, revision: 2)
        _ = try await cloud.bootstrap()
        let coordinator = CloudCoordinator(client: cloudClient, subscriptions: silentSubscriptionStore(transport))
        await coordinator.refreshContext()
        XCTAssertFalse(coordinator.isCloudActive)

        let store = elevatedStore(repository: cloud, coordinator: coordinator)
        await store.recoverCloudEntitlements()
        XCTAssertTrue(store.canModifyWallet)
        XCTAssertFalse(store.canStartParentMutation)
        XCTAssertEqual(store.snapshot.acceptedBalanceCents, 750, "reads keep working and nothing was deleted")

        transport.failEverything = true
        let offlineContinuation = await store.continueLocallyAfterCloud()
        XCTAssertFalse(offlineContinuation)
        XCTAssertTrue(store.authorityState.isCloudAuthority)
        XCTAssertTrue(local.isCloudAuthority)
        XCTAssertEqual(store.snapshot.acceptedBalanceCents, 750)
        XCTAssertTrue(store.cloudMessage?.contains("needs to catch up with Cloud") == true)

        transport.failEverything = false
        transport.stub("GET", "/v1/cloud/changes", CloudSliceFixtures.revisionChanges(lineage: lineage, revision: 2))
        let currentContinuation = await store.continueLocallyAfterCloud()
        XCTAssertTrue(currentContinuation, "the parent can keep using this device after a current refresh")
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

        transport.failEverything = true
        let offlineSignOut = await store.signOutOfCloudOnThisDevice()
        XCTAssertFalse(offlineSignOut)
        XCTAssertTrue(store.authorityState.isCloudAuthority)
        XCTAssertTrue(local.isCloudAuthority)
        XCTAssertEqual(store.snapshot.acceptedBalanceCents, 750)
        XCTAssertFalse(transport.requests.contains { $0.httpMethod == "DELETE" })

        transport.failEverything = false
        transport.stub("GET", "/v1/cloud/changes", CloudSliceFixtures.revisionChanges(lineage: lineage, revision: 2))
        let currentSignOut = await store.signOutOfCloudOnThisDevice()
        XCTAssertTrue(currentSignOut)
        XCTAssertEqual(store.snapshot.acceptedBalanceCents, 750, "the wallet is still here")
        XCTAssertTrue(store.authorityState.isLocalAuthority)
        XCTAssertEqual(store.cloudEntitlement, .none)
        XCTAssertTrue(transport.requests.contains { $0.httpMethod == "DELETE" && $0.url?.path == "/v1/session/current" })
    }

    /// A Cloud read can still be in flight when the parent signs this device
    /// out of Cloud: `WalletStore` starts unstructured refreshes of its own, so
    /// the hand-off always races one. The replica refuses the superseded read
    /// through its hand-off lease, and that refusal must never reach the parent
    /// as an error - least of all as sign-in copy on a wallet that no longer
    /// needs a session at all.
    func testACloudReadSupersededByTheSignOutNeverShowsTheParentAnError() async throws {
        let local = try LocalWalletRepository(directory: directory)
        let lineage = UUID()
        let transport = RoutingTransport()
        transport.stub("GET", "/v1/cloud/bootstrap", CloudSliceFixtures.bootstrap(lineage: lineage))
        transport.stub("GET", "/v1/cloud/changes", CloudSliceFixtures.revisionChanges(lineage: lineage, revision: 2))
        let cloud = CloudWalletRepository(client: client(transport), replica: local, lineageID: lineage, revision: 2)
        _ = try await cloud.bootstrap()
        let store = elevatedStore(repository: cloud, coordinator: nil)

        // Exactly what a late read observes once the hand-off has committed:
        // the repository is still the Cloud one, but the replica has moved on.
        try cloud.localReplica.continueLocallyAfterCloud()
        await store.refresh()

        XCTAssertNil(store.errorMessage, "a Cloud read the sign-out superseded is not news for the parent")
        XCTAssertFalse(store.sessionExpired, "a signed-out wallet never asks for a parent session")
        XCTAssertEqual(store.snapshot.acceptedBalanceCents, 750, "the wallet is still here")
        XCTAssertFalse(local.isCloudAuthority, "the late read cannot reclaim Cloud authority")
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
        await waitUntil("the newest overlapping Cloud read reports the outage") { store.connection == .deviceOffline }
        XCTAssertEqual(store.connection, .deviceOffline)
        XCTAssertEqual(store.snapshot.acceptedBalanceCents, 750, "the last accepted Cloud state stays readable offline")
        if case .cloudOffline = store.authorityState {} else {
            XCTFail("an offline Cloud wallet is presented as offline, not as local authority: \(store.authorityState)")
        }
        XCTAssertFalse(store.canContinueLocallyAfterCloud)
        let continuedWithoutEntitlement = await store.continueLocallyAfterCloud()
        XCTAssertFalse(continuedWithoutEntitlement, "unknown entitlement must not detach Cloud authority")
        XCTAssertTrue(local.isCloudAuthority)
    }

    func testPersistedCloudAuthorityReconstructsTheCloudRepositoryOnRelaunch() async throws {
        let local = try await localWalletWithHistory()
        let lineage = try XCTUnwrap(local.lineageID)
        try local.markCloudAuthorityConfirmed(lineageID: lineage, revision: 9)
        let transport = RoutingTransport()
        let selected = WalletRepositoryFactory.select(
            local: local,
            legacy: MockWalletRepository(),
            cloudClient: client(transport)
        )

        let cloud = try XCTUnwrap(selected as? CloudWalletRepository)
        XCTAssertEqual(cloud.lineageID, lineage)
        XCTAssertEqual(cloud.revision, 9)
        let store = elevatedStore(repository: cloud, coordinator: CloudCoordinator(client: client(transport), subscriptions: silentSubscriptionStore(transport)))
        XCTAssertEqual(store.cloudSignOutMode, .cloudDevice)
        XCTAssertTrue(store.canSignOutOfCloudOnThisDevice)
        XCTAssertFalse(cloud.hasValidReplica)
        let copy = CloudStatusView.cloudReplicaUnavailableStatusCopy(deviceNoun: "iPad")
        XCTAssertTrue(copy.contains("Reconnect before"))
        XCTAssertFalse(copy.contains("last synced"))
    }

    func testCloudSignInUsesTheStoredOwnerBeforeOfferingPlans() async throws {
        let local = try await localWalletWithHistory()
        let sessions = InMemorySessionStore()
        let transport = RoutingTransport()
        let client = CloudAPIClient(baseURL: Self.baseURL, sessionStore: sessions, transport: transport)
        transport.stub("POST", "/v1/auth/apple", CloudSliceFixtures.authenticated, status: 201)
        let provider = RecordingCloudSignInProvider()
        let coordinator = CloudCoordinator(
            client: client,
            subscriptions: CloudSubscriptionStore(client: client, observeTransactions: false)
        )
        let store = WalletStore(
            repository: local,
            appleSignInProvider: provider,
            initiallySignedIn: true,
            pinStore: InMemoryParentPINStore(pin: "1234"),
            identityStore: InMemoryParentIdentityStore(appleUserID: "synthetic-parent"),
            cloudCoordinator: coordinator
        )
        store.openParentGate()
        for digit in ["1", "2", "3", "4"] { store.appendPINDigit(digit) }

        await store.loadCloudPlans()
        XCTAssertTrue(store.cloudPlans.isEmpty)
        XCTAssertTrue(transport.requests.isEmpty, "no Cloud request is made before explicit authentication")
        await store.signInToCloud()

        XCTAssertEqual(provider.authorizationRequiredAppleUserID, "synthetic-parent")
        XCTAssertEqual(sessions.session?.token, "synthetic-session")
        XCTAssertTrue(transport.requests.contains { $0.url?.path == "/v1/capabilities" })
        XCTAssertTrue(store.cloudPlans.isEmpty, "StoreKit unavailability cannot be replaced by a local grant")
    }

    /// The 2026-08-04 incident regression, end to end at the parent surface: a
    /// signed-in parent whose authenticated capability read returns the
    /// service's real dark answer sees an unavailable card that names account
    /// policy, while the same parent behind an unreachable service sees a
    /// different card that names a failed check - with a retry in both. The
    /// two conditions must never collapse into one indistinguishable state
    /// again, on screen or in the local recovery evidence.
    func testDarkCapabilitiesAndOutageProduceDistinguishableUnavailableCards() async throws {
        let local = try await localWalletWithHistory()
        let transport = RoutingTransport()
        transport.stub("GET", "/v1/capabilities", CloudSliceFixtures.capabilitiesDark)
        transport.stub("GET", "/v1/cloud/context", CloudSliceFixtures.contextNoEntitlement)
        let coordinator = CloudCoordinator(client: client(transport), subscriptions: silentSubscriptionStore(transport))
        let store = elevatedStore(repository: local, coordinator: coordinator)

        await store.loadCloudPlans()

        XCTAssertFalse(store.needsCloudSignIn)
        XCTAssertTrue(store.cloudPlans.isEmpty)
        XCTAssertFalse(store.canOfferCloudPlans)
        XCTAssertEqual(store.cloudEntitlement, .none)
        XCTAssertEqual(store.purchaseAttempt, .productsUnavailable(.notOffered))
        XCTAssertEqual(store.cloudSubscriptionStore?.recoveryEvidence.lastCapabilityRead, .notPermitted)
        XCTAssertNil(store.cloudSubscriptionStore?.recoveryEvidence.lastProductLoad)
        let policyCopy = CloudStatusView.plansUnavailableNoteCopy(for: store.purchaseAttempt, deviceNoun: "iPad")
        XCTAssertTrue(policyCopy.contains("isn't available for this account"), "a policy answer reads as account availability: \(policyCopy)")
        XCTAssertTrue(CloudStatusView.showsPlansRetryControl(for: store.purchaseAttempt))

        // The same parent behind an unreachable service: a different truthful
        // sentence, a different recorded step, and still a retry.
        transport.failEverything = true
        await store.loadCloudPlans()

        XCTAssertEqual(store.purchaseAttempt, .productsUnavailable(.couldNotCheck))
        XCTAssertEqual(store.cloudSubscriptionStore?.recoveryEvidence.lastCapabilityRead, .unreadable)
        let transientCopy = CloudStatusView.plansUnavailableNoteCopy(for: store.purchaseAttempt, deviceNoun: "iPad")
        XCTAssertTrue(transientCopy.contains("couldn't be checked right now"), "a failed check reads as transient: \(transientCopy)")
        XCTAssertNotEqual(policyCopy, transientCopy, "different upstream conditions must not share one sentence")
        XCTAssertTrue(CloudStatusView.showsPlansRetryControl(for: store.purchaseAttempt))

        // The retry re-runs the whole check: once the service answers again,
        // the state and evidence move off the stale failed-check classes.
        transport.failEverything = false
        await store.loadCloudPlans()

        XCTAssertEqual(store.purchaseAttempt, .productsUnavailable(.notOffered))
        XCTAssertEqual(store.cloudSubscriptionStore?.recoveryEvidence.lastCapabilityRead, .notPermitted)
    }

    // Guideline 3.1.2: the purchase surface must link both documents. These
    // are the exact `URL` values the plans card's `Link` controls open, so a
    // wrong host or path here is the same failure a reviewer would hit
    // tapping the link - not a copy of source text.
    func testCloudPlansLegalLinksPointAtTheRequiredDestinations() {
        XCTAssertEqual(CloudStatusView.termsOfUseURL, URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/"))
        XCTAssertEqual(CloudStatusView.privacyPolicyURL, URL(string: "https://eddies-wallet.kunchenguid.com/"))
        XCTAssertTrue(CloudStatusView.autoRenewDisclosure.localizedCaseInsensitiveContains("renew"))
        XCTAssertTrue(CloudStatusView.autoRenewDisclosure.localizedCaseInsensitiveContains("cancel"))
    }

    func testDifferentAppleAccountFailsBeforeCloudSessionOrRequests() async throws {
        let local = try await localWalletWithHistory()
        let sessions = InMemorySessionStore()
        let transport = RoutingTransport()
        let client = CloudAPIClient(baseURL: Self.baseURL, sessionStore: sessions, transport: transport)
        let provider = RecordingCloudSignInProvider(appleUserID: "different-parent")
        let store = WalletStore(
            repository: local,
            appleSignInProvider: provider,
            initiallySignedIn: true,
            pinStore: InMemoryParentPINStore(pin: "1234"),
            identityStore: InMemoryParentIdentityStore(appleUserID: "synthetic-parent"),
            cloudCoordinator: CloudCoordinator(
                client: client,
                subscriptions: CloudSubscriptionStore(client: client, observeTransactions: false)
            )
        )
        store.openParentGate()
        for digit in ["1", "2", "3", "4"] { store.appendPINDigit(digit) }

        await store.signInToCloud()

        XCTAssertEqual(provider.authorizationRequiredAppleUserID, "synthetic-parent")
        XCTAssertNil(sessions.session)
        XCTAssertTrue(transport.requests.isEmpty)
        XCTAssertTrue(store.cloudPlans.isEmpty)
    }

    func testLocalSetupAndForgottenPINRecoveryIgnoreCloudOutage() async throws {
        let local = try LocalWalletRepository(directory: directory)
        let sessions = InMemorySessionStore()
        let transport = RoutingTransport()
        transport.failEverything = true
        let client = CloudAPIClient(baseURL: Self.baseURL, sessionStore: sessions, transport: transport)
        let provider = RecordingCloudSignInProvider()
        let store = WalletStore(
            repository: local,
            appleSignInProvider: provider,
            initiallySignedIn: false,
            pinStore: InMemoryParentPINStore(),
            identityStore: InMemoryParentIdentityStore(),
            cloudCoordinator: CloudCoordinator(
                client: client,
                subscriptions: CloudSubscriptionStore(client: client, observeTransactions: false)
            )
        )

        await store.signInWithApple()
        XCTAssertEqual(store.rootRoute, .setup)
        let didSetUp = await store.setupParent(
            ParentSetup(nickname: "Test Kid"),
            pin: "1234",
            confirmation: "1234"
        )
        XCTAssertTrue(didSetUp)
        guard case .accepted = await store.submit(WalletCommand(kind: .deposit, amountCents: 100)) else {
            return XCTFail("local money actions must work while Cloud is offline")
        }

        store.exitParentArea()
        store.openParentGate()
        store.requestPINRecovery()
        await store.reauthenticateOwningParent()
        XCTAssertEqual(store.gateRoute, .setPIN)
        XCTAssertTrue(store.completeGatePINSetup(pin: "5678", confirmation: "5678"))
        guard case .accepted = await store.submit(WalletCommand(kind: .deposit, amountCents: 50)) else {
            return XCTFail("local money actions must still work after offline PIN recovery")
        }

        XCTAssertNil(sessions.session)
        XCTAssertTrue(transport.requests.isEmpty)
        XCTAssertEqual(provider.signInRequiredAppleUserIDs, [nil, "synthetic-parent"])
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
        XCTAssertThrowsError(
            try local.applyCloudReplica(
                broken,
                merging: false,
                applicationLease: local.cloudApplicationLease
            )
        )
        XCTAssertEqual(local.snapshot().acceptedBalanceCents, 750, "the accepted local history is untouched")
    }

    // MARK: - Restore truthfulness at the parent surface

    /// The observed 0.1.6 incident path end to end: a completed Restore sync
    /// with no usable Cloud transaction must reach the parent as the truthful
    /// App Store/client failure, with no transaction POST and no silent idle.
    func testRestoreSyncSuccessWithZeroTransactionsSurfacesTruthfulClientErrorToParent() async throws {
        let local = try await localWalletWithHistory()
        let transport = RoutingTransport()
        transport.stub("GET", "/v1/cloud/context", CloudSliceFixtures.contextNoEntitlement)
        let apiClient = client(transport)
        let operations = StubCloudStoreKitOperations()
        let subscriptions = CloudSubscriptionStore(client: apiClient, storeKit: operations, observeTransactions: false)
        subscriptions.delayedRescanDelayNanoseconds = 10_000_000
        let coordinator = CloudCoordinator(client: apiClient, subscriptions: subscriptions)
        let store = elevatedStore(repository: local, coordinator: coordinator)

        await store.restoreCloudPurchases()

        XCTAssertEqual(store.purchaseAttempt, .storeClientError)
        XCTAssertEqual(store.cloudEntitlement, .none)
        XCTAssertFalse(transport.requests.contains { $0.url?.path == "/v1/cloud/transactions" }, "no transaction POST may leave the device")
        XCTAssertEqual(operations.syncCallCount, 1)
        XCTAssertEqual(operations.currentEntitlementsCallCount, 2, "immediate sweep plus exactly one delayed rescan")
        XCTAssertEqual(store.cloudSubscriptionStore?.recoveryEvidence.lastSyncOutcome, .returned)
        XCTAssertEqual(store.cloudSubscriptionStore?.recoveryEvidence.deliveryOutcome, .notAttempted)
    }

    /// A verified transaction recovered on the delayed rescan still activates
    /// through the one existing delivery route, and the parent surface adopts
    /// the backend context rather than re-deriving state locally.
    func testRestoreDelayedRescanRecoveryAdoptsTheBackendContextForParent() async throws {
        let local = try await localWalletWithHistory()
        let transport = RoutingTransport()
        transport.stub("POST", "/v1/cloud/transactions", CloudSliceFixtures.contextActiveNoHousehold)
        transport.stub("GET", "/v1/cloud/context", CloudSliceFixtures.contextActiveNoHousehold)
        let apiClient = client(transport)
        let operations = StubCloudStoreKitOperations()
        let subscriptions = CloudSubscriptionStore(client: apiClient, storeKit: operations, observeTransactions: false)
        subscriptions.delayedRescanDelayNanoseconds = 500_000_000
        let coordinator = CloudCoordinator(client: apiClient, subscriptions: subscriptions)
        let store = elevatedStore(repository: local, coordinator: coordinator)

        let restore = Task { await store.restoreCloudPurchases() }
        let deadline = Date().addingTimeInterval(2)
        while operations.currentEntitlementsCallCount == 0 || operations.statusCallCount == 0 {
            if Date() > deadline { return XCTFail("timed out waiting for the immediate sweep") }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        operations.latestOutcome = CloudStoreKitScanOutcome(verified: [
            CloudStoreKitTransaction(productID: CloudProductID.monthly, jwsRepresentation: "synthetic.signed.transaction"),
        ])
        await restore.value

        XCTAssertEqual(store.purchaseAttempt, .verifiedPaid)
        guard case .active = store.cloudEntitlement else {
            return XCTFail("the parent surface adopts the backend-projected entitlement")
        }
        XCTAssertEqual(transport.requests.filter { $0.url?.path == "/v1/cloud/transactions" }.count, 1)
        XCTAssertEqual(store.cloudSubscriptionStore?.recoveryEvidence.surfaces[.latestTransaction]?.phase, .delayed)
    }

    func testIndependentTransactionUpdatePropagatesInactiveStateToParent() async throws {
        let local = try await localWalletWithHistory()
        let transport = RoutingTransport()
        transport.stub("POST", "/v1/cloud/transactions", CloudSliceFixtures.contextWithEntitlement("revoked"))
        let apiClient = client(transport)
        let operations = StubCloudStoreKitOperations()
        let subscriptions = CloudSubscriptionStore(client: apiClient, storeKit: operations, observeTransactions: true)
        let coordinator = CloudCoordinator(client: apiClient, subscriptions: subscriptions)
        let store = elevatedStore(repository: local, coordinator: coordinator)

        await waitUntil("the transaction updates listener subscribes") {
            operations.updateEventsCallCount == 1
        }
        operations.yieldUpdate(.verified(CloudStoreKitTransaction(
            productID: CloudProductID.monthly,
            jwsRepresentation: "synthetic.signed.revoked",
            purchaseDate: Date(timeIntervalSince1970: 200)
        )))
        await waitUntil("the parent adopts the transaction update") {
            store.purchaseAttempt == .entitlementNotActive(.revoked)
        }

        XCTAssertEqual(store.cloudEntitlement, .revoked)
        XCTAssertEqual(transport.requests.filter { $0.url?.path == "/v1/cloud/transactions" }.count, 1)
    }

    func testConcurrentParentAdoptionsCoalesceCloudActivation() async throws {
        let local = try await localWalletWithHistory()
        let lineage = try XCTUnwrap(local.lineageID)
        let transport = RoutingTransport()
        transport.stub("GET", "/v1/cloud/context", CloudSliceFixtures.contextActiveNoHousehold)
        transport.stub("POST", "/v1/cloud/household/import", CloudSliceFixtures.importAccepted(lineage: lineage), status: 201)
        transport.stub("GET", "/v1/cloud/bootstrap", CloudSliceFixtures.bootstrap(lineage: lineage))
        transport.suspend("POST", "/v1/cloud/household/import")
        let apiClient = client(transport)
        let coordinator = CloudCoordinator(client: apiClient, subscriptions: silentSubscriptionStore(transport))
        _ = await coordinator.refreshContext()
        let store = elevatedStore(repository: local, coordinator: coordinator)

        var firstFinished = false
        let first = Task {
            await coordinator.onTransactionUpdate?()
            firstFinished = true
        }
        await transport.waitUntilSuspended()

        var secondFinished = false
        let second = Task {
            await coordinator.onTransactionUpdate?()
            secondFinished = true
        }
        await Task.yield()

        XCTAssertFalse(firstFinished)
        XCTAssertFalse(secondFinished)
        XCTAssertEqual(transport.requests.filter { $0.url?.path == "/v1/cloud/household/import" }.count, 1)

        transport.resumeSuspendedRequest()
        await first.value
        await second.value

        XCTAssertTrue(firstFinished)
        XCTAssertTrue(secondFinished)
        XCTAssertEqual(transport.requests.filter { $0.url?.path == "/v1/cloud/household/import" }.count, 1)
        guard case .cloud(let authorityLineage, _) = store.authorityState else {
            return XCTFail("the coalesced activation becomes Cloud authority")
        }
        XCTAssertEqual(authorityLineage, lineage)
    }

    // MARK: - Optional real loopback boundary

    /// Opt-in proof using the production Cloud client and repository against a
    /// synthetic local-auth backend plus disposable PostgreSQL. Normal test runs
    /// skip it because this frontend repository does not own or start the
    /// separately maintained service. The evidence report records the exact
    /// synthetic setup used by the shipping lane.
    func testSyntheticAppClientToBackendToPostgreSQLWrite() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let rawBaseURL = environment["EW_CLOUD_E2E_BASE_URL"],
              let baseURL = URL(string: rawBaseURL),
              let token = environment["EW_CLOUD_E2E_TOKEN"],
              let rawLineage = environment["EW_CLOUD_E2E_LINEAGE"],
              let lineage = UUID(uuidString: rawLineage),
              let rawRevision = environment["EW_CLOUD_E2E_REVISION"],
              let revision = Int64(rawRevision) else {
            throw XCTSkip("Set the synthetic loopback Cloud E2E environment to run this external boundary proof.")
        }

        let client = CloudAPIClient(
            baseURL: baseURL,
            sessionStore: InMemorySessionStore(session: AuthSession(token: token, expiresAt: .distantFuture)),
            transport: URLSessionTransport()
        )
        let local = try LocalWalletRepository(inMemory: true)
        let cloud = CloudWalletRepository(client: client, replica: local, lineageID: lineage, revision: revision, requiresBootstrap: true)
        let initial = try await cloud.bootstrap()
        let amount = 321
        let expectedBalance = initial.acceptedBalanceCents + amount

        guard case .accepted(let event) = try await cloud.submit(
            WalletCommand(
                kind: .deposit,
                amountCents: amount,
                reason: "synthetic app to PostgreSQL proof",
                idempotencyKey: "synthetic-app-postgres-write"
            )
        ) else {
            return XCTFail("the real loopback boundary must observe the accepted server entry")
        }

        XCTAssertNotNil(event.remoteID)
        XCTAssertEqual(cloud.snapshot().acceptedBalanceCents, expectedBalance)
        XCTAssertEqual(cloud.revision, revision + 1)
        XCTAssertFalse(cloud.hasUnsettledMutation)
    }

    // MARK: - Helpers

    private func client(_ transport: RoutingTransport) -> CloudAPIClient {
        CloudAPIClient(baseURL: Self.baseURL, sessionStore: InMemorySessionStore(session: session), transport: transport)
    }

    private func writableCloud() async throws -> (CloudWalletRepository, RoutingTransport, UUID) {
        let local = try LocalWalletRepository(directory: directory)
        let lineage = UUID()
        let transport = RoutingTransport()
        transport.stub("GET", "/v1/cloud/bootstrap", CloudSliceFixtures.bootstrap(lineage: lineage))
        let cloud = CloudWalletRepository(client: client(transport), replica: local, lineageID: lineage, revision: 2)
        _ = try await cloud.bootstrap()
        XCTAssertTrue(cloud.hasValidReplica)
        return (cloud, transport, lineage)
    }

    /// A subscription store whose StoreKit surfaces are all stubbed empty, so
    /// unit tests never depend on the local StoreKit environment or network.
    private func silentSubscriptionStore(_ transport: RoutingTransport) -> CloudSubscriptionStore {
        CloudSubscriptionStore(client: client(transport), storeKit: StubCloudStoreKitOperations(), observeTransactions: false)
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

    /// The kid home's own store: signed in and never elevated, so what it
    /// publishes is exactly what the child is shown.
    private func kidStore(repository: any WalletRepository) -> WalletStore {
        WalletStore(
            repository: repository,
            appleSignInProvider: SliceSignInProvider(),
            initiallySignedIn: true,
            pinStore: InMemoryParentPINStore(pin: "1234"),
            identityStore: InMemoryParentIdentityStore(appleUserID: "synthetic-parent"),
            cloudCoordinator: nil
        )
    }

    /// The kid home's own status derivation, driven from published state.
    private func kidStatusMessage(_ store: WalletStore) -> String? {
        KidCopy.statusBanner(
            sessionExpired: store.sessionExpired,
            connection: store.connection,
            hasError: store.errorMessage != nil,
            lastUpdated: store.snapshot.lastUpdated
        )
    }

    /// Waits out the read `WalletStore.init` starts, so a test's own reads are
    /// the only ones left in flight. Waiting on the spinner alone would race
    /// that read's start; a recorded request proves it began.
    private func waitUntilFirstReadSettles(_ store: WalletStore, _ transport: RoutingTransport) async {
        await waitUntil("the store's first Cloud read to settle") {
            transport.requests.contains { $0.url?.path == "/v1/cloud/changes" } && !store.isLoading
        }
        XCTAssertNil(store.errorMessage, "the first read is expected to succeed before the race begins")
    }

    private func waitUntil(_ description: String, condition: @escaping @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(2)
        while !condition() {
            if Date() > deadline {
                XCTFail("timed out waiting for \(description)")
                return
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

@MainActor
final class CloudSubscriptionStoreTests: XCTestCase {
    private let session = AuthSession(token: "synthetic-session", expiresAt: .distantFuture)
    private let accountToken = UUID()

    func testPurchaseStoreKitThrowRecoversVerifiedCurrentEntitlementAndDeliversIt() async {
        let transport = RoutingTransport()
        transport.stub("POST", "/v1/cloud/transactions", CloudSliceFixtures.contextActiveNoHousehold)
        let operations = StubCloudStoreKitOperations()
        operations.purchaseResult = .failure(StubCloudStoreKitError.purchaseFailed)
        operations.entitlementOutcome = CloudStoreKitScanOutcome(verified: [transaction()])
        let store = makeStore(transport: transport, operations: operations)

        await store.purchase(productID: CloudProductID.monthly, accountToken: accountToken)

        XCTAssertEqual(store.state, .verifiedPaid)
        XCTAssertEqual(operations.purchaseCallCount, 1)
        XCTAssertEqual(operations.currentEntitlementsCallCount, 1)
        XCTAssertEqual(transport.requests.filter { $0.url?.path == "/v1/cloud/transactions" }.count, 1)
    }

    func testUnknownPurchaseResultRecoversVerifiedCurrentEntitlement() async {
        let transport = RoutingTransport()
        transport.stub("POST", "/v1/cloud/transactions", CloudSliceFixtures.contextActiveNoHousehold)
        let operations = StubCloudStoreKitOperations()
        operations.purchaseResult = .success(.unknown)
        operations.entitlementOutcome = CloudStoreKitScanOutcome(verified: [transaction()])
        let store = makeStore(transport: transport, operations: operations)

        await store.purchase(productID: CloudProductID.monthly, accountToken: accountToken)

        XCTAssertEqual(store.state, .verifiedPaid)
        XCTAssertEqual(operations.currentEntitlementsCallCount, 1)
    }

    func testRestoreStoreKitErrorRecoversVerifiedCurrentEntitlement() async {
        let transport = RoutingTransport()
        transport.stub("POST", "/v1/cloud/transactions", CloudSliceFixtures.contextActiveNoHousehold)
        let operations = StubCloudStoreKitOperations()
        operations.syncError = StubCloudStoreKitError.syncFailed
        operations.entitlementOutcome = CloudStoreKitScanOutcome(verified: [transaction()])
        let store = makeStore(transport: transport, operations: operations)

        await store.restorePurchases()

        XCTAssertEqual(store.state, .verifiedPaid)
        XCTAssertEqual(operations.syncCallCount, 1)
        XCTAssertEqual(operations.currentEntitlementsCallCount, 1)
    }

    func testStoreKitFailureWithoutCurrentEntitlementUsesClientError() async {
        let transport = RoutingTransport()
        let operations = StubCloudStoreKitOperations()
        operations.purchaseResult = .failure(StubCloudStoreKitError.purchaseFailed)
        let store = makeStore(transport: transport, operations: operations)

        await store.purchase(productID: CloudProductID.monthly, accountToken: accountToken)

        XCTAssertEqual(store.state, .storeClientError)
        XCTAssertFalse(transport.requests.contains { $0.url?.path == "/v1/cloud/transactions" })
    }

    func testBackendFourHundredRemainsServerRejected() async {
        let transport = RoutingTransport()
        transport.stub(
            "POST",
            "/v1/cloud/transactions",
            Data("""
            {"error":{"code":"STORE_TRANSACTION_REJECTED","message":"Rejected by service"}}
            """.utf8),
            status: 403
        )
        let operations = StubCloudStoreKitOperations()
        operations.purchaseResult = .success(.success(transaction()))
        let store = makeStore(transport: transport, operations: operations)

        await store.purchase(productID: CloudProductID.monthly, accountToken: accountToken)

        XCTAssertEqual(store.state, .serverRejected(correlationID: nil))
    }

    func testConcurrentRecoveryWaitsForSingleDeliveryToComplete() async {
        let transport = RoutingTransport()
        transport.stub("POST", "/v1/cloud/transactions", CloudSliceFixtures.contextActiveNoHousehold)
        transport.suspend("POST", "/v1/cloud/transactions")
        let operations = StubCloudStoreKitOperations()
        operations.entitlementOutcome = CloudStoreKitScanOutcome(verified: [transaction()])
        let store = makeStore(transport: transport, operations: operations)

        let firstRecovery = Task { await store.recoverCurrentEntitlements() }
        await transport.waitUntilSuspended()

        var concurrentRecoveryFinished = false
        let concurrentRecovery = Task {
            let recovered = await store.recoverCurrentEntitlements()
            concurrentRecoveryFinished = true
            return recovered
        }
        await Task.yield()

        XCTAssertFalse(concurrentRecoveryFinished)
        XCTAssertEqual(transport.requests.filter { $0.url?.path == "/v1/cloud/transactions" }.count, 1)

        transport.resumeSuspendedRequest()
        let initialRecovery = await firstRecovery.value
        XCTAssertTrue(initialRecovery)
        let coalescedRecovery = await concurrentRecovery.value
        XCTAssertTrue(coalescedRecovery)
        XCTAssertTrue(concurrentRecoveryFinished)
        let completedRecovery = await store.recoverCurrentEntitlements()
        XCTAssertTrue(completedRecovery)
        XCTAssertEqual(transport.requests.filter { $0.url?.path == "/v1/cloud/transactions" }.count, 1)
    }

    // MARK: - Truthful restore after a successful sync

    /// The exact 0.1.6 incident branch: sync returns, nothing usable is in
    /// the store, and the state must not stay silently idle.
    func testRestoreSyncSuccessWithZeroUsableTransactionsEndsWithTruthfulClientError() async {
        let transport = RoutingTransport()
        let operations = StubCloudStoreKitOperations()
        let store = makeStore(transport: transport, operations: operations)
        store.delayedRescanDelayNanoseconds = 10_000_000

        await store.restorePurchases()

        XCTAssertEqual(store.state, .storeClientError, "a completed sync with no usable Cloud transaction is a truthful App Store/client failure, never silent idle")
        XCTAssertEqual(operations.syncCallCount, 1, "sync stays behind the explicit Restore action only")
        XCTAssertEqual(operations.currentEntitlementsCallCount, 2, "the immediate sweep plus exactly one delayed rescan")
        XCTAssertEqual(operations.latestCallCount, 2)
        XCTAssertEqual(operations.historyCallCount, 2)
        XCTAssertEqual(operations.statusCallCount, 2)
        XCTAssertFalse(transport.requests.contains { $0.url?.path == "/v1/cloud/transactions" }, "nothing usable was found, so no transaction POST may leave the device")
        XCTAssertEqual(store.recoveryEvidence.lastSyncOutcome, .returned)
        XCTAssertEqual(store.recoveryEvidence.deliveryOutcome, .notAttempted)
        XCTAssertEqual(store.recoveryEvidence.surfaces[.currentEntitlements]?.phase, .delayed)
        XCTAssertEqual(store.recoveryEvidence.surfaces[.currentEntitlements]?.verifiedCloud, 0)
        XCTAssertEqual(store.recoveryEvidence.surfaces[.subscriptionStatus]?.phase, .delayed)
    }

    func testRestoreFindsTransactionThroughLatestTransactionSurface() async {
        let transport = RoutingTransport()
        transport.stub("POST", "/v1/cloud/transactions", CloudSliceFixtures.contextActiveNoHousehold)
        let operations = StubCloudStoreKitOperations()
        operations.latestOutcome = CloudStoreKitScanOutcome(verified: [transaction()])
        let store = makeStore(transport: transport, operations: operations)

        await store.restorePurchases()

        XCTAssertEqual(store.state, .verifiedPaid)
        XCTAssertEqual(transport.requests.filter { $0.url?.path == "/v1/cloud/transactions" }.count, 1)
        XCTAssertEqual(operations.historyCallCount, 0, "the chain stops at the first usable surface")
        XCTAssertEqual(operations.statusCallCount, 0)
        XCTAssertEqual(store.recoveryEvidence.surfaces[.latestTransaction]?.verifiedCloud, 1)
        XCTAssertEqual(store.recoveryEvidence.surfaces[.latestTransaction]?.phase, .immediate)
        XCTAssertEqual(store.recoveryEvidence.deliveryOutcome, .active)
        guard case .active = store.lastVerifiedContext?.entitlementState else {
            return XCTFail("the backend context is adopted, never re-derived locally")
        }
    }

    func testRecoveryDeliversNewestVerifiedCloudCandidate() async throws {
        let transport = RoutingTransport()
        transport.stub("POST", "/v1/cloud/transactions", CloudSliceFixtures.contextActiveNoHousehold)
        let operations = StubCloudStoreKitOperations()
        operations.latestOutcome = CloudStoreKitScanOutcome(verified: [
            transaction(
                productID: CloudProductID.monthly,
                jwsRepresentation: "synthetic.signed.older",
                purchaseDate: Date(timeIntervalSince1970: 100)
            ),
            transaction(
                productID: CloudProductID.annual,
                jwsRepresentation: "synthetic.signed.newer",
                purchaseDate: Date(timeIntervalSince1970: 200)
            ),
        ])
        let store = makeStore(transport: transport, operations: operations)

        await store.restorePurchases()

        let posts = transport.requests.filter { $0.url?.path == "/v1/cloud/transactions" }
        XCTAssertEqual(posts.count, 1)
        let body = try XCTUnwrap(posts.first?.httpBody).jsonObject()
        XCTAssertEqual(body["signedTransaction"] as? String, "synthetic.signed.newer")
    }

    func testRestoreFindsCloudTransactionThroughHistoryAndFiltersNonCloud() async throws {
        let transport = RoutingTransport()
        transport.stub("POST", "/v1/cloud/transactions", CloudSliceFixtures.contextActiveNoHousehold)
        let operations = StubCloudStoreKitOperations()
        operations.historyOutcome = CloudStoreKitScanOutcome(verified: [nonCloudTransaction(), transaction()])
        let store = makeStore(transport: transport, operations: operations)

        await store.restorePurchases()

        XCTAssertEqual(store.state, .verifiedPaid)
        let posts = transport.requests.filter { $0.url?.path == "/v1/cloud/transactions" }
        XCTAssertEqual(posts.count, 1, "history delivers only the configured Cloud transaction")
        let body = try XCTUnwrap(posts.first?.httpBody).jsonObject()
        XCTAssertEqual(body["signedTransaction"] as? String, "synthetic.signed.transaction")
        XCTAssertEqual(store.recoveryEvidence.surfaces[.transactionHistory]?.verifiedCloud, 1, "non-Cloud history entries are filtered out before delivery")
        XCTAssertEqual(store.recoveryEvidence.surfaces[.transactionHistory]?.phase, .immediate)
    }

    func testRestoreFindsTransactionThroughSubscriptionStatusSurface() async {
        let transport = RoutingTransport()
        transport.stub("POST", "/v1/cloud/transactions", CloudSliceFixtures.contextActiveNoHousehold)
        let operations = StubCloudStoreKitOperations()
        operations.statusOutcome = CloudStoreKitScanOutcome(verified: [transaction()])
        let store = makeStore(transport: transport, operations: operations)

        await store.restorePurchases()

        XCTAssertEqual(store.state, .verifiedPaid)
        XCTAssertEqual(transport.requests.filter { $0.url?.path == "/v1/cloud/transactions" }.count, 1)
        XCTAssertEqual(store.recoveryEvidence.surfaces[.subscriptionStatus]?.verifiedCloud, 1)
        XCTAssertEqual(store.recoveryEvidence.surfaces[.subscriptionStatus]?.phase, .immediate)
        XCTAssertEqual(store.recoveryEvidence.deliveryOutcome, .active)
    }

    func testRestoreUnverifiedOnlyResultsAreCountedAndNeverDelivered() async {
        let transport = RoutingTransport()
        let operations = StubCloudStoreKitOperations()
        operations.entitlementOutcome = CloudStoreKitScanOutcome(verified: [], unverifiedCount: 2)
        operations.statusOutcome = CloudStoreKitScanOutcome(verified: [], unverifiedCount: 1)
        let store = makeStore(transport: transport, operations: operations)
        store.delayedRescanDelayNanoseconds = 10_000_000

        await store.restorePurchases()

        XCTAssertEqual(store.state, .storeClientError, "unverified results are not usable, so the bounded sweep ends in the truthful client failure")
        XCTAssertFalse(transport.requests.contains { $0.url?.path == "/v1/cloud/transactions" }, "unverified transactions are never delivered")
        XCTAssertEqual(store.recoveryEvidence.surfaces[.currentEntitlements]?.unverified, 2)
        XCTAssertEqual(store.recoveryEvidence.surfaces[.subscriptionStatus]?.unverified, 1)
        XCTAssertEqual(store.recoveryEvidence.deliveryOutcome, .notAttempted)
    }

    func testDuplicateTransactionAcrossSurfacesAndScansDeliversOnce() async {
        let transport = RoutingTransport()
        transport.stub("POST", "/v1/cloud/transactions", CloudSliceFixtures.contextActiveNoHousehold)
        let operations = StubCloudStoreKitOperations()
        let shared = transaction()
        operations.entitlementOutcome = CloudStoreKitScanOutcome(verified: [shared])
        operations.latestOutcome = CloudStoreKitScanOutcome(verified: [shared])
        operations.historyOutcome = CloudStoreKitScanOutcome(verified: [shared])
        operations.statusOutcome = CloudStoreKitScanOutcome(verified: [shared])
        let store = makeStore(transport: transport, operations: operations)
        store.delayedRescanDelayNanoseconds = 10_000_000

        let recovered = await store.recoverCurrentEntitlements()
        XCTAssertTrue(recovered)
        await store.restorePurchases()

        XCTAssertEqual(
            transport.requests.filter { $0.url?.path == "/v1/cloud/transactions" }.count,
            1,
            "the same signed transaction sighted by several surfaces and sweeps is delivered exactly once"
        )
        XCTAssertEqual(store.state, .verifiedPaid)
        XCTAssertEqual(operations.syncCallCount, 1)
    }

    // MARK: - Bounded delayed rescan

    func testDelayedRescanFindsLateTransaction() async {
        let transport = RoutingTransport()
        transport.stub("POST", "/v1/cloud/transactions", CloudSliceFixtures.contextActiveNoHousehold)
        let operations = StubCloudStoreKitOperations()
        let store = makeStore(transport: transport, operations: operations)
        store.delayedRescanDelayNanoseconds = 500_000_000

        let restore = Task { await store.restorePurchases() }
        await waitUntil("the immediate sweep finishes") {
            operations.currentEntitlementsCallCount == 1 && operations.statusCallCount == 1
        }
        operations.latestOutcome = CloudStoreKitScanOutcome(verified: [transaction()])
        await restore.value

        XCTAssertEqual(store.state, .verifiedPaid, "the bounded delayed rescan delivered the late transaction")
        XCTAssertEqual(transport.requests.filter { $0.url?.path == "/v1/cloud/transactions" }.count, 1)
        XCTAssertEqual(operations.currentEntitlementsCallCount, 2, "exactly one delayed rescan, then stop")
        XCTAssertEqual(store.recoveryEvidence.surfaces[.latestTransaction]?.phase, .delayed)
        XCTAssertEqual(store.recoveryEvidence.deliveryOutcome, .active)
        guard case .active = store.lastVerifiedContext?.entitlementState else {
            return XCTFail("the backend context is adopted, never re-derived locally")
        }
    }

    func testRestoreEmptyDelayedRescanDoesNotClobberConcurrentUpdateDelivery() async {
        let transport = RoutingTransport()
        transport.stub("POST", "/v1/cloud/transactions", CloudSliceFixtures.contextActiveNoHousehold)
        let operations = StubCloudStoreKitOperations()
        let store = makeStore(transport: transport, operations: operations, observeTransactions: true)
        store.delayedRescanDelayNanoseconds = 500_000_000

        await waitUntil("the updates listener subscribes") {
            operations.updateEventsCallCount == 1
        }
        let restore = Task { await store.restorePurchases() }
        await waitUntil("the immediate restore sweep finishes") {
            operations.currentEntitlementsCallCount >= 2 && operations.statusCallCount >= 2
        }
        operations.yieldUpdate(.verified(transaction()))
        await waitUntil("the update transaction activates Cloud") {
            store.state == .verifiedPaid
        }
        await restore.value

        XCTAssertEqual(store.state, .verifiedPaid)
        XCTAssertEqual(transport.requests.filter { $0.url?.path == "/v1/cloud/transactions" }.count, 1)
        XCTAssertEqual(operations.currentEntitlementsCallCount, 3, "passive, immediate, and exactly one delayed sweep")
    }

    func testRestoreEmptyDelayedRescanDoesNotClobberPreexistingUpdateDelivery() async {
        let transport = RoutingTransport()
        transport.stub("POST", "/v1/cloud/transactions", CloudSliceFixtures.contextActiveNoHousehold)
        transport.suspend("POST", "/v1/cloud/transactions")
        let operations = StubCloudStoreKitOperations()
        let store = makeStore(transport: transport, operations: operations, observeTransactions: true)
        store.delayedRescanDelayNanoseconds = 500_000_000

        await waitUntil("the updates listener subscribes") {
            operations.updateEventsCallCount == 1
        }
        operations.yieldUpdate(.verified(transaction()))
        await transport.waitUntilSuspended()

        var restoreFinished = false
        let restore = Task {
            await store.restorePurchases()
            restoreFinished = true
        }
        await waitUntil("the immediate restore sweep finishes") {
            operations.syncCallCount == 1 && operations.currentEntitlementsCallCount >= 2 && operations.statusCallCount >= 2
        }
        await waitUntil("the delayed restore sweep finishes") {
            operations.currentEntitlementsCallCount >= 3 && operations.statusCallCount >= 3
        }
        await Task.yield()
        XCTAssertFalse(restoreFinished, "Restore waits for the pre-existing delivery to settle")

        transport.resumeSuspendedRequest()
        await restore.value

        XCTAssertTrue(restoreFinished)
        XCTAssertEqual(store.state, .verifiedPaid)
        XCTAssertEqual(transport.requests.filter { $0.url?.path == "/v1/cloud/transactions" }.count, 1)
        XCTAssertEqual(operations.currentEntitlementsCallCount, 3, "passive, immediate, and exactly one delayed sweep")
    }

    func testRestoreCancelledDuringDelayedRescanStopsCleanly() async {
        let transport = RoutingTransport()
        let operations = StubCloudStoreKitOperations()
        let store = makeStore(transport: transport, operations: operations)
        store.delayedRescanDelayNanoseconds = 30_000_000_000

        let restore = Task { await store.restorePurchases() }
        await waitUntil("the immediate sweep finishes") {
            operations.currentEntitlementsCallCount == 1 && operations.statusCallCount == 1
        }
        restore.cancel()
        await restore.value

        XCTAssertEqual(store.state, .idle, "a cancelled restore claims nothing either way")
        XCTAssertEqual(operations.currentEntitlementsCallCount, 1, "the delayed rescan never ran")
        XCTAssertFalse(transport.requests.contains { $0.url?.path == "/v1/cloud/transactions" })
        XCTAssertEqual(store.recoveryEvidence.lastSyncOutcome, .returned)
    }

    // MARK: - Independent transaction updates

    func testTransactionUpdatesSubscribeIndependentlyWhileUnfinishedStaysOpen() async {
        let transport = RoutingTransport()
        transport.stub("POST", "/v1/cloud/transactions", CloudSliceFixtures.contextActiveNoHousehold)
        let operations = StubCloudStoreKitOperations()
        let store = makeStore(transport: transport, operations: operations, observeTransactions: true)

        await waitUntil("both listeners subscribe") {
            operations.unfinishedEventsCallCount == 1 && operations.updateEventsCallCount == 1
        }
        XCTAssertEqual(operations.updateEventsCallCount, 1, "updates subscribe even though the unfinished sequence never terminates")

        // A repeated start must not add listeners.
        store.startObservingIfAuthenticated()
        XCTAssertEqual(operations.unfinishedEventsCallCount, 1)
        XCTAssertEqual(operations.updateEventsCallCount, 1)

        // An unverified sighting is counted and never delivered.
        operations.yieldUpdate(.unverified)
        await waitUntil("the unverified sighting is counted") {
            store.recoveryEvidence.surfaces[.transactionUpdates]?.unverified == 1
        }
        XCTAssertFalse(transport.requests.contains { $0.url?.path == "/v1/cloud/transactions" })

        // A verified update still delivers through the existing route while
        // the unfinished sequence remains open.
        operations.yieldUpdate(.verified(transaction()))
        await waitUntil("the update is delivered") {
            store.state == .verifiedPaid
        }
        XCTAssertEqual(transport.requests.filter { $0.url?.path == "/v1/cloud/transactions" }.count, 1)
        XCTAssertEqual(store.recoveryEvidence.surfaces[.transactionUpdates]?.verifiedCloud, 1)
    }

    // MARK: - Truthful non-active entitlement rendering

    func testDeliveredNonActiveEntitlementRendersItsRealState() async {
        let cases: [(String, CloudEntitlementState)] = [
            ("expired", .expired),
            ("refunded", .refunded),
            ("revoked", .revoked),
            ("billing_retry", .billingRetry),
        ]
        for (wireState, expected) in cases {
            let transport = RoutingTransport()
            transport.stub("POST", "/v1/cloud/transactions", CloudSliceFixtures.contextWithEntitlement(wireState))
            let operations = StubCloudStoreKitOperations()
            let finishRecorder = FinishRecorder()
            operations.purchaseResult = .success(.success(transaction(finish: { finishRecorder.finish() })))
            let store = makeStore(transport: transport, operations: operations)

            await store.purchase(productID: CloudProductID.monthly, accountToken: accountToken)

            XCTAssertEqual(store.state, .entitlementNotActive(expected), "\(wireState) renders its real state, not a generic server rejection")
            XCTAssertEqual(store.recoveryEvidence.deliveryOutcome, .inactive)
            XCTAssertEqual(finishRecorder.finishedCount, 0, "a non-granting projection never finishes the transaction")
        }
    }

    func testDeliveredActiveEntitlementFinishesTheTransaction() async {
        let transport = RoutingTransport()
        transport.stub("POST", "/v1/cloud/transactions", CloudSliceFixtures.contextActiveNoHousehold)
        let operations = StubCloudStoreKitOperations()
        let finishRecorder = FinishRecorder()
        operations.purchaseResult = .success(.success(transaction(finish: { finishRecorder.finish() })))
        let store = makeStore(transport: transport, operations: operations)

        await store.purchase(productID: CloudProductID.monthly, accountToken: accountToken)

        XCTAssertEqual(store.state, .verifiedPaid)
        XCTAssertEqual(finishRecorder.finishedCount, 1, "finishing stays tied to a granting backend projection")
        XCTAssertEqual(store.recoveryEvidence.deliveryOutcome, .active)
    }

    // MARK: - Distinguishable plan-availability outcomes

    /// The formerly collapsed conditions behind one `.productsUnavailable`:
    /// the service's deliberate "no", an unreadable capability answer, and a
    /// failed App Store product query must stay distinguishable through both
    /// the attempt state and the local recovery evidence.
    func testCapabilityNotPermittedIsRecordedAsPolicyAndNeverAsksTheStore() async {
        let transport = RoutingTransport()
        transport.stub("GET", "/v1/capabilities", CloudSliceFixtures.capabilitiesDark)
        let operations = StubCloudStoreKitOperations()
        let store = makeStore(transport: transport, operations: operations)

        await store.loadProducts()

        XCTAssertEqual(store.state, .productsUnavailable(.notOffered), "a deliberate service answer is policy, not an outage")
        XCTAssertTrue(store.products.isEmpty)
        XCTAssertEqual(store.recoveryEvidence.lastCapabilityRead, .notPermitted)
        XCTAssertNil(store.recoveryEvidence.lastProductLoad, "the App Store is never asked after the service said no")
        XCTAssertEqual(operations.productsCallCount, 0)
    }

    func testUnreadableCapabilityAnswerIsRecordedAsFailedCheck() async {
        let transport = RoutingTransport()
        transport.failEverything = true
        let operations = StubCloudStoreKitOperations()
        let store = makeStore(transport: transport, operations: operations)

        await store.loadProducts()

        XCTAssertEqual(store.state, .productsUnavailable(.couldNotCheck), "an unreadable answer is unknown availability, never a settled no")
        XCTAssertEqual(store.recoveryEvidence.lastCapabilityRead, .unreadable)
        XCTAssertNil(store.recoveryEvidence.lastProductLoad)
        XCTAssertEqual(operations.productsCallCount, 0)
    }

    func testPermittedCapabilityWithEmptyStoreAnswerRecordsTheProductLoadStep() async {
        let transport = RoutingTransport()
        transport.stub("GET", "/v1/capabilities", CloudSliceFixtures.capabilitiesReady)
        let operations = StubCloudStoreKitOperations()
        let store = makeStore(transport: transport, operations: operations)

        await store.loadProducts()

        XCTAssertEqual(store.state, .productsUnavailable(.couldNotCheck))
        XCTAssertEqual(store.recoveryEvidence.lastCapabilityRead, .permitted)
        XCTAssertEqual(store.recoveryEvidence.lastProductLoad, .storeReturnedNone, "the evidence names the step that failed, not a collapsed state")
        XCTAssertEqual(operations.productsCallCount, 1)
    }

    func testPermittedCapabilityWithThrowingStoreRecordsNetworkFailure() async {
        let transport = RoutingTransport()
        transport.stub("GET", "/v1/capabilities", CloudSliceFixtures.capabilitiesReady)
        let operations = StubCloudStoreKitOperations()
        operations.productsResult = .failure(StubCloudStoreKitError.productsFailed)
        let store = makeStore(transport: transport, operations: operations)

        await store.loadProducts()

        XCTAssertEqual(store.state, .productsUnavailable(.couldNotCheck))
        XCTAssertEqual(store.recoveryEvidence.lastCapabilityRead, .permitted)
        XCTAssertEqual(store.recoveryEvidence.lastProductLoad, .networkFailure)
    }

    func testProductLoadOutcomeClassifiesEveryStoreAnswer() {
        XCTAssertEqual(CloudSubscriptionStore.productLoadOutcome(forLoadedIDs: []), .storeReturnedNone)
        XCTAssertEqual(CloudSubscriptionStore.productLoadOutcome(forLoadedIDs: [CloudProductID.monthly]), .productSetMismatch)
        XCTAssertEqual(CloudSubscriptionStore.productLoadOutcome(forLoadedIDs: [CloudProductID.monthly, CloudProductID.monthly]), .productSetMismatch, "a duplicate is not the two distinct plans")
        XCTAssertEqual(
            CloudSubscriptionStore.productLoadOutcome(forLoadedIDs: [CloudProductID.monthly, CloudProductID.annual, "com.example.unrelated"]),
            .productSetMismatch
        )
        XCTAssertEqual(CloudSubscriptionStore.productLoadOutcome(forLoadedIDs: [CloudProductID.monthly, CloudProductID.annual]), .loaded)
        XCTAssertEqual(CloudSubscriptionStore.productLoadOutcome(forLoadedIDs: [CloudProductID.annual, CloudProductID.monthly]), .loaded, "order never matters")
    }

    func testRetryRunsAFreshCheckAndReclassifiesBothSteps() async {
        let transport = RoutingTransport()
        transport.failEverything = true
        let operations = StubCloudStoreKitOperations()
        let store = makeStore(transport: transport, operations: operations)

        await store.loadProducts()
        XCTAssertEqual(store.recoveryEvidence.lastCapabilityRead, .unreadable)

        // The service recovers between the failed check and the retry; the
        // rerun must reclassify the capability step and record the product
        // step it now reaches, leaving nothing from the stale check behind.
        transport.failEverything = false
        transport.stub("GET", "/v1/capabilities", CloudSliceFixtures.capabilitiesReady)
        await store.loadProducts()

        XCTAssertEqual(store.recoveryEvidence.lastCapabilityRead, .permitted)
        XCTAssertEqual(store.recoveryEvidence.lastProductLoad, .storeReturnedNone)
        XCTAssertEqual(store.state, .productsUnavailable(.couldNotCheck))
        XCTAssertEqual(operations.productsCallCount, 1)
    }

    func testConcurrentRetryKeepsOnlyTheLatestAvailabilityCheck() async {
        let transport = RoutingTransport()
        transport.stub("GET", "/v1/capabilities", CloudSliceFixtures.capabilitiesReady)
        let operations = StubCloudStoreKitOperations()
        operations.suspendNextProducts()
        let store = makeStore(transport: transport, operations: operations)

        let firstCheck = Task { await store.loadProducts() }
        await operations.waitUntilProductsSuspended()

        transport.failEverything = true
        await store.loadProducts()

        XCTAssertEqual(store.state, .productsUnavailable(.couldNotCheck))
        XCTAssertEqual(store.recoveryEvidence.lastCapabilityRead, .unreadable)
        XCTAssertNil(store.recoveryEvidence.lastProductLoad)

        transport.failEverything = false
        operations.resumeProducts()
        await firstCheck.value

        XCTAssertEqual(store.state, .productsUnavailable(.couldNotCheck))
        XCTAssertEqual(store.recoveryEvidence.lastCapabilityRead, .unreadable)
        XCTAssertNil(store.recoveryEvidence.lastProductLoad)
        XCTAssertTrue(store.products.isEmpty)
    }

    private func transaction(
        productID: String = CloudProductID.monthly,
        jwsRepresentation: String = "synthetic.signed.transaction",
        purchaseDate: Date = .distantPast,
        finish: @escaping () async -> Void = {}
    ) -> CloudStoreKitTransaction {
        CloudStoreKitTransaction(
            productID: productID,
            jwsRepresentation: jwsRepresentation,
            purchaseDate: purchaseDate,
            finish: finish
        )
    }

    private func nonCloudTransaction() -> CloudStoreKitTransaction {
        CloudStoreKitTransaction(productID: "com.example.unrelated", jwsRepresentation: "synthetic.signed.unrelated")
    }

    private func waitUntil(_ description: String, condition: @escaping @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(2)
        while !condition() {
            if Date() > deadline {
                XCTFail("timed out waiting for \(description)")
                return
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func makeStore(
        transport: RoutingTransport,
        operations: StubCloudStoreKitOperations,
        observeTransactions: Bool = false
    ) -> CloudSubscriptionStore {
        let client = CloudAPIClient(
            baseURL: URL(string: "https://api.example.test")!,
            sessionStore: InMemorySessionStore(session: session),
            transport: transport
        )
        return CloudSubscriptionStore(client: client, storeKit: operations, observeTransactions: observeTransactions)
    }
}

/// The local evidence surface can only ever carry aggregate counts, outcome
/// classes, the scan phase, and the build context. These
/// tests prove that shape for both the serialization and the Debug-only
/// readout content.
final class CloudRecoveryEvidenceTests: XCTestCase {
    func testSerializationContainsOnlyAggregateCountsClassesAndBuildContext() throws {
        var evidence = CloudRecoveryEvidence(buildContext: "0.1.7 (9)")
        evidence.recordScan(surface: .currentEntitlements, phase: .immediate, verifiedCloud: 1, unverified: 2)
        evidence.recordScan(surface: .subscriptionStatus, phase: .delayed, verifiedCloud: 0, unverified: 0)
        evidence.recordStreamSighting(surface: .transactionUpdates, verified: true)
        evidence.recordStreamSighting(surface: .unfinished, verified: false)
        evidence.recordSync(.returned)
        evidence.recordCapabilityRead(.notPermitted)
        evidence.recordCapabilityRead(.permitted)
        evidence.recordProductLoad(.productSetMismatch)
        evidence.recordDelivery(.network)

        let data = try JSONEncoder().encode(evidence)
        let json = String(decoding: data, as: UTF8.self)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var leaves: [String] = []
        flattenJSON(object, into: &leaves)
        XCTAssertFalse(leaves.isEmpty)

        // Every leaf must be a count, one of
        // the fixed structural or class words, or the build context.
        var vocabulary: Set<String> = [
            "surfaces", "lastSyncOutcome", "lastCapabilityRead", "lastProductLoad", "deliveryOutcome", "buildContext",
            "verifiedCloud", "unverified", "phase",
            "0.1.7 (9)",
        ]
        vocabulary.formUnion(CloudRecoveryEvidence.Surface.allCases.map(\.rawValue))
        vocabulary.formUnion(["passive", "immediate", "delayed", "returned", "threw",
                              "notAttempted", "active", "inactive", "pending", "rejected", "network",
                              "permitted", "notPermitted", "unreadable",
                              "loaded", "storeReturnedNone", "productSetMismatch", "networkFailure"])
        for leaf in leaves where !vocabulary.contains(leaf) && Double(leaf) == nil {
            XCTFail("the evidence serialization may only carry counts, class words, and the build context; found '\(leaf)'")
        }

        // Belt and braces: nothing shaped like a signed payload, identifier,
        // or account value can appear, because the model has no field that
        // could hold one.
        for forbidden in ["eyJ", "signedTransaction", "jws", "transactionId", "originalTransactionId",
                          "appAccountToken", "receipt", "correlationId", "session"] {
            XCTAssertFalse(json.contains(forbidden), "evidence must never contain \(forbidden)")
        }
    }

    /// The readout the Release build renders is derived entirely from the
    /// model above, so its rows carry the same safe shape.
    func testDisplayRowsRenderOnlySafeAggregateContent() {
        var evidence = CloudRecoveryEvidence(buildContext: "0.1.7 (9)")
        evidence.recordScan(surface: .currentEntitlements, phase: .immediate, verifiedCloud: 0, unverified: 0)
        evidence.recordScan(surface: .latestTransaction, phase: .delayed, verifiedCloud: 1, unverified: 0)
        evidence.recordSync(.threw)
        evidence.recordCapabilityRead(.notPermitted)
        evidence.recordDelivery(.inactive)

        let rows = evidence.displayRows
        XCTAssertEqual(
            rows.map(\.id),
            ["build", "capabilityRead", "productLoad", "sync", "currentEntitlements", "latestTransaction",
             "transactionHistory", "subscriptionStatus", "unfinished", "transactionUpdates", "delivery"]
        )
        XCTAssertEqual(rows.first { $0.id == "build" }?.value, "0.1.7 (9)")
        XCTAssertEqual(rows.first { $0.id == "capabilityRead" }?.value, "not permitted for this account")
        XCTAssertEqual(rows.first { $0.id == "productLoad" }?.value, "not run", "a step that never ran says so instead of implying a scan")
        XCTAssertEqual(rows.first { $0.id == "sync" }?.value, "threw")
        XCTAssertEqual(rows.first { $0.id == "currentEntitlements" }?.value, "empty")
        XCTAssertEqual(rows.first { $0.id == "currentEntitlements" }?.detail, "just after Restore")
        XCTAssertEqual(rows.first { $0.id == "latestTransaction" }?.value, "1 verified")
        XCTAssertEqual(rows.first { $0.id == "latestTransaction" }?.detail, "delayed rescan")
        XCTAssertEqual(rows.first { $0.id == "transactionHistory" }?.value, "not scanned")
        XCTAssertEqual(rows.first { $0.id == "unfinished" }?.value, "not scanned")
        XCTAssertEqual(rows.first { $0.id == "delivery" }?.value, "plan not active")

        // No rendered row may contain anything shaped like a signed payload,
        // an identifier, an account value, or an error message.
        let rowText = rows.flatMap { [$0.title, $0.value, $0.detail ?? ""] }.joined(separator: "\n")
        for forbidden in ["eyJ", "signedTransaction", "jws", "transactionId", "appAccountToken",
                          "receipt", "correlationId", "Error"] {
            XCTAssertFalse(rowText.contains(forbidden), "the readout must never render \(forbidden)")
        }
    }

    /// The two availability rows always describe one coherent check: a new
    /// capability read starts a fresh check, so a product-load outcome from an
    /// earlier attempt can never sit next to a newer capability outcome.
    func testANewCapabilityReadClearsTheEarlierProductLoadStep() {
        var evidence = CloudRecoveryEvidence(buildContext: "0.1.7 (9)")
        evidence.recordCapabilityRead(.permitted)
        evidence.recordProductLoad(.storeReturnedNone)
        evidence.recordCapabilityRead(.unreadable)

        XCTAssertEqual(evidence.lastCapabilityRead, .unreadable)
        XCTAssertNil(evidence.lastProductLoad)
        XCTAssertEqual(evidence.displayRows.first { $0.id == "productLoad" }?.value, "not run")
    }

    private func flattenJSON(_ value: Any, into leaves: inout [String]) {
        switch value {
        case let dictionary as [String: Any]:
            for (key, child) in dictionary {
                leaves.append(key)
                flattenJSON(child, into: &leaves)
            }
        case let array as [Any]:
            for child in array { flattenJSON(child, into: &leaves) }
        case let string as String:
            leaves.append(string)
        case let number as NSNumber:
            leaves.append(number.stringValue)
        default:
            break
        }
    }
}

@MainActor
private final class FinishRecorder {
    private(set) var finishedCount = 0
    func finish() { finishedCount += 1 }
}

@MainActor
final class StubCloudStoreKitOperations: CloudStoreKitOperations {
    /// Tests cannot construct StoreKit `Product` values, so a successful stub
    /// answer is always the empty set: exactly what a store that resolves
    /// neither Cloud product returns.
    var productsResult: Result<[Product], Error> = .success([])
    var purchaseResult: Result<CloudStoreKitPurchaseResult, Error> = .failure(StubCloudStoreKitError.purchaseFailed)
    var entitlementOutcome = CloudStoreKitScanOutcome()
    var latestOutcome = CloudStoreKitScanOutcome()
    var historyOutcome = CloudStoreKitScanOutcome()
    var statusOutcome = CloudStoreKitScanOutcome()
    var syncError: Error?
    private(set) var productsCallCount = 0
    private(set) var purchaseCallCount = 0
    private(set) var currentEntitlementsCallCount = 0
    private(set) var latestCallCount = 0
    private(set) var historyCallCount = 0
    private(set) var statusCallCount = 0
    private(set) var syncCallCount = 0
    private(set) var unfinishedEventsCallCount = 0
    private(set) var updateEventsCallCount = 0
    /// Never yields and never terminates: the unfinished sequence can stay
    /// open forever, which is exactly what the updates-independence tests need.
    private let unfinishedStream: AsyncStream<CloudStoreKitStreamEvent>
    private let updatesStream: AsyncStream<CloudStoreKitStreamEvent>
    private var updatesContinuation: AsyncStream<CloudStoreKitStreamEvent>.Continuation?
    private var shouldSuspendProducts = false
    private var productsContinuation: CheckedContinuation<Void, Never>?
    private var productsSuspensionObserver: CheckedContinuation<Void, Never>?

    init() {
        unfinishedStream = AsyncStream { _ in }
        var continuation: AsyncStream<CloudStoreKitStreamEvent>.Continuation?
        updatesStream = AsyncStream { continuation = $0 }
        updatesContinuation = continuation
    }

    func products(for _: Set<String>) async throws -> [Product] {
        productsCallCount += 1
        if shouldSuspendProducts {
            shouldSuspendProducts = false
            await withCheckedContinuation { continuation in
                productsContinuation = continuation
                productsSuspensionObserver?.resume()
                productsSuspensionObserver = nil
            }
        }
        return try productsResult.get()
    }

    func suspendNextProducts() {
        shouldSuspendProducts = true
    }

    func waitUntilProductsSuspended() async {
        if productsContinuation != nil { return }
        await withCheckedContinuation { productsSuspensionObserver = $0 }
    }

    func resumeProducts() {
        productsContinuation?.resume()
        productsContinuation = nil
    }

    func purchase(productID _: String, product _: Product?, accountToken _: UUID) async throws -> CloudStoreKitPurchaseResult {
        purchaseCallCount += 1
        return try purchaseResult.get()
    }

    func currentEntitlements() async -> CloudStoreKitScanOutcome {
        currentEntitlementsCallCount += 1
        return entitlementOutcome
    }

    func latestTransactions() async -> CloudStoreKitScanOutcome {
        latestCallCount += 1
        return latestOutcome
    }

    func transactionHistory() async -> CloudStoreKitScanOutcome {
        historyCallCount += 1
        return historyOutcome
    }

    func subscriptionStatusTransactions() async -> CloudStoreKitScanOutcome {
        statusCallCount += 1
        return statusOutcome
    }

    func unfinishedEvents() -> AsyncStream<CloudStoreKitStreamEvent> {
        unfinishedEventsCallCount += 1
        return unfinishedStream
    }

    func updateEvents() -> AsyncStream<CloudStoreKitStreamEvent> {
        updateEventsCallCount += 1
        return updatesStream
    }

    func sync() async throws {
        syncCallCount += 1
        if let syncError { throw syncError }
    }

    func yieldUpdate(_ event: CloudStoreKitStreamEvent) {
        updatesContinuation?.yield(event)
    }
}

enum StubCloudStoreKitError: Error {
    case purchaseFailed
    case syncFailed
    case productsFailed
}

// MARK: - Fixtures and stubs

enum CloudSliceFixtures {
    static let authenticated = Data("""
    {"token":"synthetic-session","expiresAt":"2099-01-01T00:00:00Z",
     "parent":{"provider":"apple","subject":"synthetic-parent","email":null}}
    """.utf8)
    /// The verbatim production answer observed in the 2026-08-04 incident: the
    /// service is reachable and healthy, and activation is deliberately not
    /// permitted for the asking parent.
    static let capabilitiesDark = Data("""
    {"cloudActivationAvailable":false,"cloudServiceAvailable":true,
     "products":["com.kunchenguid.eddieswallet.cloud.monthly","com.kunchenguid.eddieswallet.cloud.annual"]}
    """.utf8)
    static let capabilitiesReady = Data("""
    {"cloudActivationAvailable":true,"cloudServiceAvailable":true,
     "products":["com.kunchenguid.eddieswallet.cloud.monthly","com.kunchenguid.eddieswallet.cloud.annual"]}
    """.utf8)
    static let contextNoEntitlement = Data("""
    {"storeAccountToken":"11111111-1111-4111-8111-111111111111","entitlement":null,"household":null}
    """.utf8)

    /// A verified delivery whose backend projection does not grant Cloud.
    static func contextWithEntitlement(_ state: String) -> Data {
        Data("""
        {"storeAccountToken":"11111111-1111-4111-8111-111111111111",
         "entitlement":{"state":"\(state)","accessUntil":"2026-01-01T00:00:00.000Z","active":false},"household":null}
        """.utf8)
    }
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
    static let commandInProgressError = Data("""
    {"error":{"code":"COMMAND_IN_PROGRESS","message":"The command is still being processed. Retry it."}}
    """.utf8)
    static let conflictError = Data("""
    {"error":{"code":"CLOUD_HOUSEHOLD_CONFLICT","message":"A different Cloud household already belongs to this parent."}}
    """.utf8)
    static let allowanceDue = Data("""
    {"allowanceRule":{"id":"a-1","amountCents":500,"cadence":"weekly","weekday":5,
     "startDate":"2026-07-01","endDate":null,"active":true,
     "nextOccurrenceId":"o-7","nextDueDate":"2026-07-29"}}
    """.utf8)
    static let allowanceNotDue = Data("""
    {"allowanceRule":{"id":"a-1","amountCents":500,"cadence":"weekly","weekday":5,
     "startDate":"2026-07-01","endDate":null,"active":true,
     "nextOccurrenceId":null,"nextDueDate":null}}
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

    static func depositAccepted(revision: Int64, entryID: String = "e-9") -> Data {
        Data("""
        {"entry":{"id":"\(entryID)","type":"deposit","amountCents":250},"wallet":{"id":"w-1","balanceCents":1000},"revision":\(revision)}
        """.utf8)
    }

    static func revisionAccepted(revision: Int64) -> Data {
        Data("{\"revision\":\(revision)}".utf8)
    }

    static func profileAccepted(revision: Int64) -> Data {
        Data("{\"family\":{\"revision\":\(revision)}}".utf8)
    }

    static func revisionChanges(lineage: UUID, revision: Int64) -> Data {
        Data("""
        {"household":{"lineageId":"\(lineage.uuidString.lowercased())","authority":"cloud","revision":\(revision)},
         "family":{"id":"f-1","name":"Test Kid's family"},
         "child":{"id":"c-1","nickname":"Test Kid","avatarUrl":null},
         "wallet":{"id":"w-1","balanceCents":750},
         "entries":[],"loans":[],"allowanceRule":null}
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

    static func zeroBalanceBootstrap(lineage: UUID) -> Data {
        Data("""
        {"household":{"lineageId":"\(lineage.uuidString.lowercased())","authority":"cloud","revision":2},
         "family":{"id":"f-1","name":"Test Kid's family"},
         "child":{"id":"c-1","nickname":"Test Kid","avatarUrl":null},
         "wallet":{"id":"w-1","balanceCents":0},
         "entries":[],"loans":[],"allowanceRule":null,"nextCursor":null}
        """.utf8)
    }

    static func bootstrapWithAllowance(lineage: UUID) -> Data {
        let source = String(decoding: bootstrap(lineage: lineage), as: UTF8.self)
        return Data(source.replacingOccurrences(
            of: "\"allowanceRule\":null",
            with: "\"allowanceRule\":{\"id\":\"a-1\",\"amountCents\":500,\"cadence\":\"weekly\",\"weekday\":5,\"startDate\":\"2026-07-01\",\"endDate\":null,\"active\":true}"
        ).utf8)
    }

    static func allowanceChanges(lineage: UUID, revision: Int64) -> Data {
        Data("""
        {"household":{"lineageId":"\(lineage.uuidString.lowercased())","authority":"cloud","revision":\(revision)},
         "family":{"id":"f-1","name":"Test Kid's family"},
         "child":{"id":"c-1","nickname":"Test Kid","avatarUrl":null},
         "wallet":{"id":"w-1","balanceCents":1250},
         "entries":[{"id":"e-9","type":"allowance","direction":"credit","amountCents":500,"balanceBeforeCents":750,"balanceAfterCents":1250,"reason":null,"loanId":null,"recordedAt":"2026-07-29T10:00:00.000Z","acceptedRevision":\(revision)}],
         "loans":[],"allowanceRule":{"id":"a-1","amountCents":500,"cadence":"weekly","weekday":5,"startDate":"2026-07-01","endDate":null,"active":true}}
        """.utf8)
    }

    static func allowanceRuleChanges(lineage: UUID, revision: Int64) -> Data {
        Data("""
        {"household":{"lineageId":"\(lineage.uuidString.lowercased())","authority":"cloud","revision":\(revision)},
         "family":{"id":"f-1","name":"Test Kid's family"},
         "child":{"id":"c-1","nickname":"Test Kid","avatarUrl":null},
         "wallet":{"id":"w-1","balanceCents":750},
         "entries":[],"loans":[],
         "allowanceRule":{"id":"a-2","amountCents":600,"cadence":"weekly","weekday":2,"startDate":"2027-01-15","endDate":null,"active":true}}
        """.utf8)
    }

    static func changes(
        lineage: UUID,
        revision: Int64,
        balanceCents: Int,
        entryID: String = "e-9",
        balanceBeforeCents: Int = 750
    ) -> Data {
        Data("""
        {"household":{"lineageId":"\(lineage.uuidString.lowercased())","authority":"cloud","revision":\(revision)},
         "family":{"id":"f-1","name":"Test Kid's family"},
         "child":{"id":"c-1","nickname":"Test Kid","avatarUrl":null},
         "wallet":{"id":"w-1","balanceCents":\(balanceCents)},
         "entries":[{"id":"\(entryID)","type":"deposit","direction":"credit","amountCents":\(balanceCents - balanceBeforeCents),"balanceBeforeCents":\(balanceBeforeCents),"balanceAfterCents":\(balanceCents),"reason":"another device","loanId":null,"recordedAt":"2026-07-26T10:00:00.000Z","acceptedRevision":\(revision)}],
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
///
/// `HTTPTransport.data(for:)` is nonisolated, so the app reaches a transport
/// from whichever cooperative thread runs the calling task - including the
/// unstructured refreshes `WalletStore` starts, which overlap the test body's
/// own calls. `URLSessionTransport` is safe under that concurrency and every
/// double has to be too: unsynchronised stored properties corrupt their own
/// buffers and kill the test host with SIGSEGV instead of failing an
/// assertion. All state therefore lives in one lock-guarded value.
final class RoutingTransport: HTTPTransport, @unchecked Sendable {
    private struct Stub {
        let statusCode: Int
        let body: Data
        let headers: [String: String]
    }

    private struct State {
        var requests: [URLRequest] = []
        var committedMutationKeys: Set<String> = []
        var failEverything = false
        var stubs: [String: [Stub]] = [:]
        var droppedResponseKeys: Set<String> = []
        var timedOutKeys: Set<String> = []
        var timedOutAfterSuspensionKeys: Set<String> = []
        /// One entry per request still to be held, consumed in arrival order,
        /// so a test can put two overlapping reads in flight at once.
        var suspendedKeys: [String] = []
        /// Held requests in arrival order; `resumeSuspendedRequest` releases
        /// the oldest, which is what lets a test choose completion order.
        var suspendedRequests: [CheckedContinuation<Void, Never>] = []
        var suspensionObservers: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    }

    private let lock = NSLock()
    private var state = State()

    private func withState<T>(_ body: (inout State) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&state)
    }

    var requests: [URLRequest] { withState { $0.requests } }
    var committedMutationKeys: Set<String> { withState { $0.committedMutationKeys } }
    var committedMutationCount: Int { withState { $0.committedMutationKeys.count } }
    var failEverything: Bool {
        get { withState { $0.failEverything } }
        set { withState { $0.failEverything = newValue } }
    }

    func stub(_ method: String, _ path: String, _ body: Data, status: Int = 200, headers: [String: String] = [:]) {
        withState { $0.stubs["\(method) \(path)"] = [Stub(statusCode: status, body: body, headers: headers)] }
    }

    func enqueue(_ method: String, _ path: String, _ body: Data, status: Int = 200, headers: [String: String] = [:]) {
        withState { $0.stubs["\(method) \(path)", default: []].append(Stub(statusCode: status, body: body, headers: headers)) }
    }

    /// Simulates a response disappearing after the service handled the exact
    /// request. The same stub remains available for an idempotent replay.
    func dropNextResponse(_ method: String, _ path: String) {
        _ = withState { $0.droppedResponseKeys.insert("\(method) \(path)") }
    }

    func timeOutNextResponse(_ method: String, _ path: String) {
        _ = withState { $0.timedOutKeys.insert("\(method) \(path)") }
    }

    func timeOutSuspendedResponse(_ method: String, _ path: String) {
        _ = withState { $0.timedOutAfterSuspensionKeys.insert("\(method) \(path)") }
    }

    /// Holds one matching request. Calling it twice holds the next two, in the
    /// order they arrive.
    func suspend(_ method: String, _ path: String) {
        withState { $0.suspendedKeys.append("\(method) \(path)") }
    }

    /// Waits until at least `count` requests are held, so a test can establish
    /// which overlapping read arrived first before releasing either.
    func waitUntilSuspended(count: Int = 1) async {
        await withCheckedContinuation { continuation in
            let alreadySuspended = withState { state -> Bool in
                if state.suspendedRequests.count >= count { return true }
                state.suspensionObservers.append((count: count, continuation: continuation))
                return false
            }
            if alreadySuspended { continuation.resume() }
        }
    }

    /// Releases the oldest held request. Any request still expected but not yet
    /// arrived stops being held, exactly as the single-suspension form did.
    func resumeSuspendedRequest() {
        let suspended: CheckedContinuation<Void, Never>? = withState { state in
            guard !state.suspendedRequests.isEmpty else {
                state.suspendedKeys = []
                return nil
            }
            if state.suspendedRequests.count == 1 { state.suspendedKeys = [] }
            return state.suspendedRequests.removeFirst()
        }
        suspended?.resume()
    }

    /// The whole routing decision is taken under one lock so a concurrent
    /// caller can never observe or interleave a half-updated stub queue.
    private enum Decision {
        case failure(URLError)
        case unstubbed
        case respond(Stub, suspending: Bool)
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let key = "\(request.httpMethod ?? "GET") \(request.url?.path ?? "")"
        let decision: Decision = withState { state in
            state.requests.append(request)
            if state.failEverything { return .failure(URLError(.notConnectedToInternet)) }
            if state.droppedResponseKeys.remove(key) != nil {
                if let stub = state.stubs[key]?.first {
                    Self.recordCommit(for: request, statusCode: stub.statusCode, in: &state)
                }
                return .failure(URLError(.networkConnectionLost))
            }
            if state.timedOutKeys.remove(key) != nil {
                return .failure(URLError(.timedOut))
            }
            guard var queued = state.stubs[key], let stub = queued.first else {
                return .unstubbed
            }
            if queued.count > 1 {
                queued.removeFirst()
                state.stubs[key] = queued
            }
            let suspending = state.suspendedKeys.firstIndex(of: key).map { index in
                state.suspendedKeys.remove(at: index)
            } != nil
            return .respond(stub, suspending: suspending)
        }

        switch decision {
        case .failure(let error):
            throw error
        case .unstubbed:
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 501, httpVersion: nil, headerFields: nil)!)
        case .respond(let stub, let suspending):
            if suspending {
                await withCheckedContinuation { continuation in
                    let observers: [CheckedContinuation<Void, Never>] = withState { state in
                        state.suspendedRequests.append(continuation)
                        let held = state.suspendedRequests.count
                        let ready = state.suspensionObservers.filter { $0.count <= held }
                        state.suspensionObservers.removeAll { $0.count <= held }
                        return ready.map(\.continuation)
                    }
                    observers.forEach { $0.resume() }
                }
                if withState({ $0.timedOutAfterSuspensionKeys.remove(key) != nil }) {
                    throw URLError(.timedOut)
                }
                // What `URLSession` reports for a request whose surrounding
                // task was cancelled while it was in flight - the exact end a
                // pull-to-refresh gives its own read when SwiftUI ends it.
                if Task.isCancelled { throw URLError(.cancelled) }
            }
            withState { Self.recordCommit(for: request, statusCode: stub.statusCode, in: &$0) }
            return (stub.body, HTTPURLResponse(url: request.url!, statusCode: stub.statusCode, httpVersion: nil, headerFields: stub.headers)!)
        }
    }

    private static func recordCommit(for request: URLRequest, statusCode: Int, in state: inout State) {
        guard (200..<300).contains(statusCode),
              let key = request.value(forHTTPHeaderField: "Idempotency-Key") else { return }
        state.committedMutationKeys.insert(key)
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

@MainActor
final class RecordingCloudSignInProvider: AppleSignInProviding, AppleIdentityAuthorizing {
    private let appleUserID: String
    private(set) var signInRequiredAppleUserIDs: [String?] = []
    private(set) var authorizationRequiredAppleUserID: String?

    init(appleUserID: String = "synthetic-parent") {
        self.appleUserID = appleUserID
    }

    func signIn(requiredAppleUserID: String?) async throws -> AppleSignInOutcome {
        signInRequiredAppleUserIDs.append(requiredAppleUserID)
        if let requiredAppleUserID, requiredAppleUserID != appleUserID {
            throw WalletAPIError.identityMismatch
        }
        return AppleSignInOutcome(appleUserID: appleUserID)
    }

    func authorizeAppleIdentity(requiredAppleUserID: String?) async throws -> AppleIdentity {
        authorizationRequiredAppleUserID = requiredAppleUserID
        if let requiredAppleUserID, requiredAppleUserID != appleUserID {
            throw WalletAPIError.identityMismatch
        }
        return AppleIdentity(
            appleUserID: appleUserID,
            identityToken: "synthetic.identity.token",
            signedNonce: "synthetic-signed-nonce"
        )
    }
}

private enum CloudSlicePersistenceError: Error {
    case failed
}

private final class CloudSliceFailingPersistence: LocalWalletPersisting {
    var payload: Data?
    var failNextSave = false
    var failOnSaveNumber: Int?
    var failOnSaveNumbers: Set<Int> = []
    private(set) var saveCount = 0

    func load() throws -> Data? {
        payload
    }

    func save(_ payload: Data) throws {
        saveCount += 1
        if failNextSave || failOnSaveNumber == saveCount || failOnSaveNumbers.remove(saveCount) != nil {
            failNextSave = false
            failOnSaveNumber = nil
            throw CloudSlicePersistenceError.failed
        }
        self.payload = payload
    }

    func erase() throws {
        payload = nil
    }
}

private extension Data {
    func jsonObject() -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: self)) as? [String: Any] ?? [:]
    }
}
