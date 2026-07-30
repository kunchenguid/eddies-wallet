import Foundation
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
        guard case .pending(let waiting) = try await cloud.submit(command) else {
            return XCTFail("a lost response is unresolved, not rejected")
        }
        XCTAssertEqual(waiting.syncState, .pending)
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

        guard case .acceptedAwaitingReplica(let event) = try await cloud.submit(
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

        guard case .acceptedAwaitingReplica(let event) = try await cloud.submit(
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
        } catch {
            XCTAssertEqual(error as? WalletAPIError, .cloudEntitlementRequired)
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

        guard case .pending(let waiting) = try await cloud.submit(
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

        guard case .pending(let event) = try await cloud.submit(
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
        XCTAssertFalse(store.isOffline)
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
        XCTAssertFalse(store.isOffline)
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
        } catch {
            XCTAssertEqual(error as? WalletAPIError, .cloudMutationAwaitingReconciliation)
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

    func testReversedRefreshCompletionCannotRegressReplicaOrRevision() async throws {
        let (cloud, transport, lineage) = try await writableCloud()
        transport.enqueue(
            "GET",
            "/v1/cloud/changes",
            CloudSliceFixtures.changes(lineage: lineage, revision: 3, balanceCents: 1_000, entryID: "older-entry")
        )
        transport.enqueue(
            "GET",
            "/v1/cloud/changes",
            CloudSliceFixtures.changes(lineage: lineage, revision: 4, balanceCents: 1_200, entryID: "newer-entry")
        )
        transport.suspend("GET", "/v1/cloud/changes")

        let older = Task { try await cloud.refresh(for: .parent) }
        await transport.waitUntilSuspended()
        _ = try await cloud.refresh(for: .parent)
        transport.resumeSuspendedRequest()

        do {
            _ = try await older.value
            XCTFail("the older response must lose the application generation race")
        } catch {
            XCTAssertEqual(error as? WalletAPIError, .cancelled)
        }
        XCTAssertEqual(cloud.revision, 4)
        XCTAssertEqual(cloud.snapshot().acceptedBalanceCents, 1_200)
        XCTAssertEqual(cloud.localReplica.cloudRevision, 4)
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

        XCTAssertTrue(store.isOffline)
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
        XCTAssertTrue(store.isOffline)
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
    static let authenticated = Data("""
    {"token":"synthetic-session","expiresAt":"2099-01-01T00:00:00Z",
     "parent":{"provider":"apple","subject":"synthetic-parent","email":null}}
    """.utf8)
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
        var suspendedKey: String?
        var suspendedRequestContinuation: CheckedContinuation<Void, Never>?
        var suspensionObservedContinuation: CheckedContinuation<Void, Never>?
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

    func suspend(_ method: String, _ path: String) {
        withState { $0.suspendedKey = "\(method) \(path)" }
    }

    func waitUntilSuspended() async {
        await withCheckedContinuation { continuation in
            let alreadySuspended = withState { state -> Bool in
                if state.suspendedRequestContinuation != nil { return true }
                state.suspensionObservedContinuation = continuation
                return false
            }
            if alreadySuspended { continuation.resume() }
        }
    }

    func resumeSuspendedRequest() {
        let suspended: CheckedContinuation<Void, Never>? = withState { state in
            state.suspendedKey = nil
            let suspended = state.suspendedRequestContinuation
            state.suspendedRequestContinuation = nil
            return suspended
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
            let suspending = key == state.suspendedKey
            if suspending { state.suspendedKey = nil }
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
                    let observer: CheckedContinuation<Void, Never>? = withState { state in
                        state.suspendedRequestContinuation = continuation
                        let observer = state.suspensionObservedContinuation
                        state.suspensionObservedContinuation = nil
                        return observer
                    }
                    observer?.resume()
                }
                if withState({ $0.timedOutAfterSuspensionKeys.remove(key) != nil }) {
                    throw URLError(.timedOut)
                }
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
