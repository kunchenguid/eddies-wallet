import Foundation
import XCTest
@testable import EddysWallet

/// End-to-end behaviour of the guarded Cloud slice against synthetic backend
/// responses: activation upload, replica bootstrap, read-only Cloud authority,
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
        XCTAssertFalse(cloud.supportsRuntimeMutations)
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
        XCTAssertFalse(relaunchedCloud.supportsRuntimeMutations)
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
        XCTAssertFalse(store.canModifyWallet)
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
            XCTFail("confirmed Cloud authority must remain read-only")
        } catch {
            XCTAssertEqual(error as? WalletAPIError, .cloudRuntimeWritesUnavailable)
        }

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

    func testCloudAuthorityExposesReadsButNoRuntimeMutations() async throws {
        let local = try LocalWalletRepository(directory: directory)
        let lineage = UUID()
        let transport = RoutingTransport()
        transport.stub("GET", "/v1/cloud/bootstrap", CloudSliceFixtures.bootstrap(lineage: lineage))
        let cloud = CloudWalletRepository(client: client(transport), replica: local, lineageID: lineage, revision: 2)
        _ = try await cloud.bootstrap()
        let store = elevatedStore(repository: cloud, coordinator: nil)

        XCTAssertFalse(cloud.supportsRuntimeMutations)
        XCTAssertFalse(store.canModifyWallet)
        XCTAssertEqual(cloud.snapshot().acceptedBalanceCents, 750)

        do {
            _ = try await cloud.submit(WalletCommand(kind: .deposit, amountCents: 250))
            XCTFail("Cloud money writes must be unavailable")
        } catch {
            XCTAssertEqual(error as? WalletAPIError, .cloudRuntimeWritesUnavailable)
        }
        do {
            _ = try await cloud.setAllowance(AllowanceRuleCommand(amountCents: 500, weekday: 1, startDate: .now))
            XCTFail("Cloud allowance writes must be unavailable")
        } catch {
            XCTAssertEqual(error as? WalletAPIError, .cloudRuntimeWritesUnavailable)
        }
        do {
            _ = try await cloud.updateChildProfile(ChildProfileUpdate(nickname: "New name"))
            XCTFail("Cloud profile writes must be unavailable")
        } catch {
            XCTAssertEqual(error as? WalletAPIError, .cloudRuntimeWritesUnavailable)
        }
        XCTAssertFalse(transport.requests.contains { request in
            request.httpMethod != "GET" && request.url?.path != "/v1/cloud/household/import"
        })
        XCTAssertTrue(local.isCloudAuthority)
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
        XCTAssertFalse(store.canModifyWallet)
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
final class RoutingTransport: HTTPTransport, @unchecked Sendable {
    private struct Stub {
        let statusCode: Int
        let body: Data
    }

    private(set) var requests: [URLRequest] = []
    var failEverything = false
    private var stubs: [String: Stub] = [:]
    private var suspendedKey: String?
    private var suspendedRequestContinuation: CheckedContinuation<Void, Never>?
    private var suspensionObservedContinuation: CheckedContinuation<Void, Never>?

    func stub(_ method: String, _ path: String, _ body: Data, status: Int = 200) {
        stubs["\(method) \(path)"] = Stub(statusCode: status, body: body)
    }

    func suspend(_ method: String, _ path: String) {
        suspendedKey = "\(method) \(path)"
    }

    func waitUntilSuspended() async {
        if suspendedRequestContinuation != nil {
            return
        }
        await withCheckedContinuation { continuation in
            suspensionObservedContinuation = continuation
        }
    }

    func resumeSuspendedRequest() {
        suspendedKey = nil
        suspendedRequestContinuation?.resume()
        suspendedRequestContinuation = nil
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        if failEverything { throw URLError(.notConnectedToInternet) }
        let key = "\(request.httpMethod ?? "GET") \(request.url?.path ?? "")"
        if key == suspendedKey {
            await withCheckedContinuation { continuation in
                suspendedRequestContinuation = continuation
                suspensionObservedContinuation?.resume()
                suspensionObservedContinuation = nil
            }
        }
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

    func load() throws -> Data? {
        payload
    }

    func save(_ payload: Data) throws {
        if failNextSave {
            failNextSave = false
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
