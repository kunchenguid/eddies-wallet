import Foundation
import XCTest
@testable import EddysWallet

/// Behavioral coverage for the client half of account deletion. Every service
/// response and wallet is synthetic: these tests never contact Apple or the
/// production service.
@MainActor
final class AccountDeletionTests: XCTestCase {
    func testDeletionSendsTheServerCommandOnlyAfterConfirmedLocalErase() async throws {
        let repository = MockWalletRepository(snapshot: .fixture())
        let service = AccountDeletionRecorder(onDelete: {
            XCTAssertFalse(repository.hasConfiguredKid, "the local wallet must be erased before DELETE")
        })
        let pending = InMemoryPendingCommandStore(commands: [
            WalletCommand(kind: .deposit, amountCents: 100, idempotencyKey: "11111111-1111-4111-8111-111111111111")
        ])
        let cache = TestSnapshotCache(snapshot: .fixture())
        let configured = InMemoryConfiguredKidStore(isConfigured: true)
        let pinStore = InMemoryParentPINStore(pin: "1234")
        let identityStore = InMemoryParentIdentityStore(appleUserID: "synthetic-parent")
        let store = WalletStore(
            repository: repository,
            initiallySignedIn: true,
            pinStore: pinStore,
            identityStore: identityStore,
            accountDeletionService: service,
            accountDeletionPendingStore: pending,
            accountDeletionSnapshotCache: cache,
            accountDeletionConfiguredKidStore: configured
        )
        enterParentArea(store)

        let outcome = await store.deleteAccount(idempotencyKey: "22222222-2222-4222-8222-222222222222")

        XCTAssertEqual(outcome, .deleted)
        XCTAssertEqual(service.idempotencyKeys, ["22222222-2222-4222-8222-222222222222"])
        XCTAssertFalse(repository.hasConfiguredKid)
        XCTAssertTrue(pending.load().isEmpty)
        XCTAssertNil(cache.load())
        XCTAssertFalse(configured.isConfigured)
        XCTAssertNil(pinStore.pin)
        XCTAssertNil(identityStore.appleUserID)
        XCTAssertFalse(store.isSignedIn)
        XCTAssertTrue(store.hasDeletedAccount)
        XCTAssertEqual(store.elevation, .active, "the terminal billing reminder stays visible until Done")

        store.finishAccountDeletion()
        XCTAssertEqual(store.rootRoute, .welcome)
        XCTAssertEqual(store.elevation, .none)
    }

    func testServerFailureAfterLocalEraseIsIncompleteAndNeverReexposesTheWallet() async throws {
        let repository = MockWalletRepository(snapshot: .fixture())
        let service = AccountDeletionRecorder(result: .failure(.network("The network is unavailable.")))
        let pinStore = InMemoryParentPINStore(pin: "1234")
        let identityStore = InMemoryParentIdentityStore(appleUserID: "synthetic-parent")
        let store = WalletStore(
            repository: repository,
            initiallySignedIn: true,
            pinStore: pinStore,
            identityStore: identityStore,
            accountDeletionService: service,
            accountDeletionPendingStore: InMemoryPendingCommandStore(),
            accountDeletionSnapshotCache: TestSnapshotCache(snapshot: .fixture()),
            accountDeletionConfiguredKidStore: InMemoryConfiguredKidStore(isConfigured: true)
        )
        enterParentArea(store)

        let outcome = await store.deleteAccount(idempotencyKey: "22222222-2222-4222-8222-222222222222")

        XCTAssertEqual(outcome, .incomplete("This \(DeviceCopy.deviceNoun)'s copy of the wallet is removed. We could not confirm your account was removed from the service."))
        XCTAssertFalse(repository.hasConfiguredKid)
        XCTAssertNil(pinStore.pin)
        XCTAssertEqual(identityStore.appleUserID, "synthetic-parent", "credentials remain for the retry")
        XCTAssertFalse(store.isSignedIn)
        XCTAssertFalse(store.hasDeletedAccount)
    }

    func testFinishLaterClearsIncompletePresentationAndRetainsOwnerIdentity() async {
        let repository = MockWalletRepository(snapshot: .fixture())
        let identityStore = InMemoryParentIdentityStore(appleUserID: "synthetic-parent")
        let store = WalletStore(
            repository: repository,
            initiallySignedIn: true,
            pinStore: InMemoryParentPINStore(pin: "1234"),
            identityStore: identityStore,
            accountDeletionService: AccountDeletionRecorder(result: .failure(.network("synthetic timeout"))),
            accountDeletionPendingStore: InMemoryPendingCommandStore(),
            accountDeletionSnapshotCache: TestSnapshotCache(snapshot: .fixture()),
            accountDeletionConfiguredKidStore: InMemoryConfiguredKidStore(isConfigured: true)
        )
        enterParentArea(store)

        let outcome = await store.deleteAccount(idempotencyKey: "22222222-2222-4222-8222-222222222222")
        guard case .incomplete = outcome else { return XCTFail("the unconfirmed request must be incomplete") }

        store.finishAccountDeletionLater()

        XCTAssertNil(store.accountDeletionPresentation)
        XCTAssertEqual(store.rootRoute, .welcome)
        XCTAssertEqual(store.elevation, .none)
        XCTAssertEqual(identityStore.appleUserID, "synthetic-parent")
        XCTAssertFalse(store.hasDeletedAccount)
    }

    func testDefiniteServerDeletionErasesTheCloudReplicaInsteadOfHandingItOffLocally() async throws {
        let replicaPersistence = TestLocalPersistence()
        let replica = try LocalWalletRepository(persistence: replicaPersistence)
        _ = try await replica.setup(ParentSetup(nickname: "Eddie"))
        let session = InMemorySessionStore(session: AuthSession(token: "synthetic-session", expiresAt: .distantFuture))
        let client = CloudAPIClient(
            baseURL: URL(string: "https://api.example.test")!,
            sessionStore: session,
            transport: StubTransport(responses: [])
        )
        let cloud = CloudWalletRepository(client: client, replica: replica, lineageID: UUID(), revision: 1)
        let store = WalletStore(
            repository: cloud,
            initiallySignedIn: true,
            pinStore: InMemoryParentPINStore(pin: "1234"),
            identityStore: InMemoryParentIdentityStore(appleUserID: "synthetic-parent"),
            localReplicaProvider: {
                throw WalletAPIError.invalidResponse("must not open a replacement after erase")
            },
            accountDeletionService: AccountDeletionRecorder(),
            accountDeletionPendingStore: InMemoryPendingCommandStore(),
            accountDeletionSnapshotCache: TestSnapshotCache(),
            accountDeletionConfiguredKidStore: InMemoryConfiguredKidStore()
        )
        enterParentArea(store)

        let outcome = await store.deleteAccount(idempotencyKey: "22222222-2222-4222-8222-222222222222")

        XCTAssertEqual(outcome, .deleted)
        XCTAssertFalse(replica.hasConfiguredKid, "the Cloud replica must be erased, never converted to a local wallet")
        XCTAssertFalse(client.hasSession, "the account's service session must not survive deletion")
        XCTAssertEqual(store.authorityState, .unconfigured)
    }

    func testLegacyDeletionKeepsTheSharedSessionUntilDeleteIsSent() async throws {
        let sessionStore = InMemorySessionStore(session: AuthSession(token: "synthetic-session", expiresAt: .distantFuture))
        let repository = APIWalletRepository(
            baseURL: URL(string: "https://api.example.test")!,
            sessionStore: sessionStore,
            transport: StubTransport(responses: []),
            cache: TestSnapshotCache(snapshot: .fixture()),
            configuredKidStore: InMemoryConfiguredKidStore(isConfigured: true),
            pendingStore: InMemoryPendingCommandStore()
        )
        let service = AccountDeletionRecorder(onDelete: {
            XCTAssertTrue(repository.isAuthenticated)
            XCTAssertFalse(repository.hasConfiguredKid)
        })
        let store = WalletStore(
            repository: repository,
            initiallySignedIn: true,
            pinStore: InMemoryParentPINStore(pin: "1234"),
            identityStore: InMemoryParentIdentityStore(appleUserID: "synthetic-parent"),
            accountDeletionService: service,
            accountDeletionPendingStore: InMemoryPendingCommandStore(),
            accountDeletionSnapshotCache: TestSnapshotCache(snapshot: .fixture()),
            accountDeletionConfiguredKidStore: InMemoryConfiguredKidStore(isConfigured: true)
        )
        enterParentArea(store)

        let outcome = await store.deleteAccount(idempotencyKey: "22222222-2222-4222-8222-222222222222")

        XCTAssertEqual(outcome, .deleted)
        XCTAssertFalse(repository.isAuthenticated, "the legacy credential is cleared only after DELETE returns")
    }

    func testPINRemovalFailureRefusesWithoutErasingWalletOrSendingDelete() async {
        let repository = MockWalletRepository(snapshot: .fixture())
        let service = AccountDeletionRecorder()
        let pending = InMemoryPendingCommandStore(commands: [
            WalletCommand(kind: .deposit, amountCents: 100)
        ])
        let cache = TestSnapshotCache(snapshot: .fixture())
        let configured = InMemoryConfiguredKidStore(isConfigured: true)
        let store = WalletStore(
            repository: repository,
            initiallySignedIn: true,
            pinStore: FailingClearParentPINStore(),
            identityStore: InMemoryParentIdentityStore(appleUserID: "synthetic-parent"),
            accountDeletionService: service,
            accountDeletionPendingStore: pending,
            accountDeletionSnapshotCache: cache,
            accountDeletionConfiguredKidStore: configured
        )
        enterParentArea(store)

        let outcome = await store.deleteAccount(idempotencyKey: "22222222-2222-4222-8222-222222222222")

        guard case .refused = outcome else { return XCTFail("pre-erase cleanup failure must refuse deletion") }
        XCTAssertTrue(repository.hasConfiguredKid)
        XCTAssertTrue(pending.load().isEmpty)
        XCTAssertNil(cache.load())
        XCTAssertFalse(configured.isConfigured)
        XCTAssertTrue(service.idempotencyKeys.isEmpty)
    }

    func testCoreDataEraseFailureRefusesAndSendsNoDelete() async throws {
        let persistence = TestLocalPersistence()
        let repository = try LocalWalletRepository(persistence: persistence)
        _ = try await repository.setup(ParentSetup(nickname: "Eddie"))
        persistence.eraseError = .invalidResponse("synthetic final save failure")
        let pending = InMemoryPendingCommandStore(commands: [WalletCommand(kind: .deposit, amountCents: 100)])
        let cache = TestSnapshotCache(snapshot: .fixture())
        let configured = InMemoryConfiguredKidStore(isConfigured: true)
        let pinStore = InMemoryParentPINStore(pin: "1234")
        let service = AccountDeletionRecorder()
        let store = WalletStore(
            repository: repository,
            initiallySignedIn: true,
            pinStore: pinStore,
            identityStore: InMemoryParentIdentityStore(appleUserID: "synthetic-parent"),
            accountDeletionService: service,
            accountDeletionPendingStore: pending,
            accountDeletionSnapshotCache: cache,
            accountDeletionConfiguredKidStore: configured
        )
        enterParentArea(store)

        let outcome = await store.deleteAccount(idempotencyKey: "22222222-2222-4222-8222-222222222222")

        guard case .refused = outcome else { return XCTFail("a failed final erase must refuse before DELETE") }
        XCTAssertTrue(repository.hasConfiguredKid)
        XCTAssertEqual(store.rootRoute, .kidHome)
        XCTAssertEqual(store.snapshot, repository.childSnapshot())
        XCTAssertTrue(pending.load().isEmpty)
        XCTAssertNil(cache.load())
        XCTAssertFalse(configured.isConfigured)
        XCTAssertNil(pinStore.pin)
        XCTAssertTrue(service.idempotencyKeys.isEmpty)
    }

    func testCleanupFlushFailureKeepsAuthoritativeWalletAndDoesNotSendDelete() async throws {
        let persistence = TestLocalPersistence()
        let repository = try LocalWalletRepository(persistence: persistence)
        _ = try await repository.setup(ParentSetup(nickname: "Eddie"))
        let pending = InMemoryPendingCommandStore(commands: [WalletCommand(kind: .deposit, amountCents: 100)])
        let cache = TestSnapshotCache(snapshot: .fixture())
        let configured = InMemoryConfiguredKidStore(isConfigured: true)
        let pinStore = InMemoryParentPINStore(pin: "1234")
        let service = AccountDeletionRecorder()
        var flushCount = 0
        let store = WalletStore(
            repository: repository,
            initiallySignedIn: true,
            pinStore: pinStore,
            identityStore: InMemoryParentIdentityStore(appleUserID: "synthetic-parent"),
            accountDeletionService: service,
            accountDeletionPendingStore: pending,
            accountDeletionSnapshotCache: cache,
            accountDeletionConfiguredKidStore: configured,
            accountDeletionFlush: {
                flushCount += 1
                return false
            }
        )
        enterParentArea(store)

        let outcome = await store.deleteAccount(idempotencyKey: "22222222-2222-4222-8222-222222222222")

        guard case .refused = outcome else { return XCTFail("unconfirmed cleanup must refuse before final erase") }
        XCTAssertTrue(repository.hasConfiguredKid)
        XCTAssertTrue(pending.load().isEmpty)
        XCTAssertNil(cache.load())
        XCTAssertFalse(configured.isConfigured)
        XCTAssertNil(pinStore.pin)
        XCTAssertEqual(flushCount, 1)
        XCTAssertTrue(service.idempotencyKeys.isEmpty)
        XCTAssertEqual(store.snapshot.acceptedBalanceCents, 0)
        XCTAssertNil(store.snapshot.childNickname)
        XCTAssertTrue(store.snapshot.activities.isEmpty)
    }

    func testPreflightFailurePreservesWalletWithoutPersistingDeletionState() async {
        let suiteName = "\(AppleAppIdentity.testBundleIdentifier).account-deletion-preflight.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else { return XCTFail("test defaults unavailable") }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let pending = UserDefaultsPendingCommandStore(defaults: defaults)
        let cache = UserDefaultsWalletSnapshotCache(defaults: defaults)
        let configured = UserDefaultsConfiguredKidStore(defaults: defaults)
        let command = WalletCommand(kind: .deposit, amountCents: 100)
        pending.save([command])
        cache.save(.fixture())
        configured.markConfigured()
        let persistedKeys = Set(defaults.persistentDomain(forName: suiteName)?.keys.map { $0 } ?? [])
        let repository = MockWalletRepository(snapshot: .fixture())
        let pinStore = InMemoryParentPINStore(pin: "1234")
        let service = AccountDeletionRecorder(preflightResult: .failure(.network("synthetic offline")))
        let store = WalletStore(
            repository: repository,
            initiallySignedIn: true,
            pinStore: pinStore,
            identityStore: InMemoryParentIdentityStore(appleUserID: "synthetic-parent"),
            accountDeletionService: service,
            accountDeletionPendingStore: pending,
            accountDeletionSnapshotCache: cache,
            accountDeletionConfiguredKidStore: configured
        )
        enterParentArea(store)

        let outcome = await store.deleteAccount(idempotencyKey: "22222222-2222-4222-8222-222222222222")

        guard case .refused = outcome else { return XCTFail("unreachable preflight must refuse before local erase") }
        XCTAssertTrue(repository.hasConfiguredKid)
        XCTAssertEqual(pending.load(), [command])
        XCTAssertNotNil(cache.load())
        XCTAssertTrue(configured.isConfigured)
        XCTAssertEqual(pinStore.pin, "1234")
        XCTAssertEqual(Set(defaults.persistentDomain(forName: suiteName)?.keys.map { $0 } ?? []), persistedKeys)
        XCTAssertEqual(service.preflightCount, 1)
        XCTAssertTrue(service.idempotencyKeys.isEmpty)
    }

    func testCredentialRemovalFailureYieldsIncompleteAfterServerSuccess() async {
        let sessionStore = FailingClearSessionStore()
        let repository = APIWalletRepository(
            baseURL: URL(string: "https://api.example.test")!,
            sessionStore: sessionStore,
            transport: StubTransport(responses: []),
            cache: TestSnapshotCache(snapshot: .fixture()),
            configuredKidStore: InMemoryConfiguredKidStore(isConfigured: true),
            pendingStore: InMemoryPendingCommandStore()
        )
        let identityStore = InMemoryParentIdentityStore(appleUserID: "synthetic-parent")
        let service = AccountDeletionRecorder()
        let store = WalletStore(
            repository: repository,
            initiallySignedIn: true,
            pinStore: InMemoryParentPINStore(pin: "1234"),
            identityStore: identityStore,
            accountDeletionService: service,
            accountDeletionPendingStore: InMemoryPendingCommandStore(),
            accountDeletionSnapshotCache: TestSnapshotCache(snapshot: .fixture()),
            accountDeletionConfiguredKidStore: InMemoryConfiguredKidStore(isConfigured: true)
        )
        enterParentArea(store)

        let outcome = await store.deleteAccount(idempotencyKey: "22222222-2222-4222-8222-222222222222")

        guard case .incomplete(let message) = outcome else { return XCTFail("credential cleanup failure must not report success") }
        XCTAssertTrue(message.contains("credential cleanup"))
        XCTAssertEqual(service.idempotencyKeys.count, 1)
        XCTAssertNotNil(sessionStore.session)
        XCTAssertEqual(identityStore.appleUserID, "synthetic-parent")
        XCTAssertFalse(store.hasDeletedAccount)
        XCTAssertEqual(store.accountDeletionPresentation, .incomplete(idempotencyKey: "22222222-2222-4222-8222-222222222222"))

        sessionStore.allowsClear = true
        let retry = await store.retryAccountDeletion(idempotencyKey: "22222222-2222-4222-8222-222222222222")

        XCTAssertEqual(retry, .deleted)
        XCTAssertEqual(service.idempotencyKeys.count, 1, "credential-only retry must not replay DELETE")
        XCTAssertNil(sessionStore.session)
        XCTAssertNil(identityStore.appleUserID)
    }

    func testIdentityRemovalFailureYieldsIncompleteWithNoWalletAfterRelaunch() async throws {
        let persistence = TestLocalPersistence()
        let repository = try LocalWalletRepository(persistence: persistence)
        _ = try await repository.setup(ParentSetup(nickname: "Eddie"))
        let identityStore = FailingClearIdentityStore()
        let service = AccountDeletionRecorder()
        let store = WalletStore(
            repository: repository,
            initiallySignedIn: true,
            pinStore: InMemoryParentPINStore(pin: "1234"),
            identityStore: identityStore,
            accountDeletionService: service,
            accountDeletionPendingStore: InMemoryPendingCommandStore(),
            accountDeletionSnapshotCache: TestSnapshotCache(snapshot: .fixture()),
            accountDeletionConfiguredKidStore: InMemoryConfiguredKidStore(isConfigured: true)
        )
        enterParentArea(store)

        let outcome = await store.deleteAccount(idempotencyKey: "22222222-2222-4222-8222-222222222222")

        guard case .incomplete = outcome else { return XCTFail("identity cleanup failure must not report success") }
        XCTAssertEqual(service.idempotencyKeys.count, 1)
        XCTAssertEqual(identityStore.appleUserID, "synthetic-parent")
        XCTAssertFalse(store.hasDeletedAccount)
        XCTAssertFalse(repository.hasConfiguredKid)

        let relaunchedRepository = try LocalWalletRepository(persistence: persistence)
        XCTAssertFalse(relaunchedRepository.hasConfiguredKid)
        XCTAssertNil(relaunchedRepository.childSnapshot().childNickname)
    }

    func testSignOutFinalEraseFailureKeepsWalletAvailable() async throws {
        let persistence = TestLocalPersistence()
        let repository = try LocalWalletRepository(persistence: persistence)
        _ = try await repository.setup(ParentSetup(nickname: "Eddie"))
        persistence.eraseError = .invalidResponse("synthetic final save failure")
        let pending = InMemoryPendingCommandStore(commands: [WalletCommand(kind: .deposit, amountCents: 100)])
        let cache = TestSnapshotCache(snapshot: .fixture())
        let configured = InMemoryConfiguredKidStore(isConfigured: true)
        let pinStore = InMemoryParentPINStore(pin: "1234")
        let store = WalletStore(
            repository: repository,
            initiallySignedIn: true,
            pinStore: pinStore,
            identityStore: InMemoryParentIdentityStore(appleUserID: "synthetic-parent"),
            accountDeletionPendingStore: pending,
            accountDeletionSnapshotCache: cache,
            accountDeletionConfiguredKidStore: configured
        )
        enterParentArea(store)

        store.signOut()

        XCTAssertTrue(repository.hasConfiguredKid)
        XCTAssertTrue(pending.load().isEmpty)
        XCTAssertNil(cache.load())
        XCTAssertFalse(configured.isConfigured)
        XCTAssertNil(pinStore.pin)
        XCTAssertTrue(store.isSignedIn)
        XCTAssertEqual(store.rootRoute, .kidHome)
        XCTAssertEqual(store.snapshot, repository.childSnapshot())
        XCTAssertNotNil(store.errorMessage)
    }

    func testSignOutCleanupFailureStopsBeforeAuthoritativeWalletErase() async throws {
        let persistence = TestLocalPersistence()
        let repository = try LocalWalletRepository(persistence: persistence)
        _ = try await repository.setup(ParentSetup(nickname: "Eddie"))
        let pending = InMemoryPendingCommandStore(commands: [WalletCommand(kind: .deposit, amountCents: 100)])
        let cache = TestSnapshotCache(snapshot: .fixture())
        let configured = InMemoryConfiguredKidStore(isConfigured: true)
        let pinStore = InMemoryParentPINStore(pin: "1234")
        let store = WalletStore(
            repository: repository,
            initiallySignedIn: true,
            pinStore: pinStore,
            identityStore: InMemoryParentIdentityStore(appleUserID: "synthetic-parent"),
            accountDeletionPendingStore: pending,
            accountDeletionSnapshotCache: cache,
            accountDeletionConfiguredKidStore: configured,
            accountDeletionFlush: { false }
        )
        enterParentArea(store)

        store.signOut()

        XCTAssertTrue(repository.hasConfiguredKid)
        XCTAssertTrue(store.isSignedIn)
        XCTAssertTrue(pending.load().isEmpty)
        XCTAssertNil(cache.load())
        XCTAssertFalse(configured.isConfigured)
        XCTAssertNil(pinStore.pin)
        XCTAssertNotNil(store.errorMessage)
    }

    func testFinalRenewingEntitlementRequiresAcknowledgementBeforeLocalErase() async {
        let transport = StubTransport(responses: [
            .init(statusCode: 200, body: CloudContractFixtures.contextActive)
        ])
        let client = CloudAPIClient(
            baseURL: URL(string: "https://api.example.test")!,
            sessionStore: InMemorySessionStore(session: AuthSession(token: "synthetic-session", expiresAt: .distantFuture)),
            transport: transport
        )
        let repository = MockWalletRepository(snapshot: .fixture())
        let pinStore = InMemoryParentPINStore(pin: "1234")
        let store = WalletStore(
            repository: repository,
            initiallySignedIn: true,
            pinStore: pinStore,
            identityStore: InMemoryParentIdentityStore(appleUserID: "synthetic-parent"),
            cloudCoordinator: CloudCoordinator(client: client),
            accountDeletionPendingStore: InMemoryPendingCommandStore(),
            accountDeletionSnapshotCache: TestSnapshotCache(snapshot: .fixture()),
            accountDeletionConfiguredKidStore: InMemoryConfiguredKidStore(isConfigured: true)
        )
        enterParentArea(store)

        let outcome = await store.deleteAccount(
            idempotencyKey: "22222222-2222-4222-8222-222222222222",
            acknowledgedBillingRisk: false
        )

        guard case .refused(let message) = outcome else { return XCTFail("renewing billing must require acknowledgement") }
        XCTAssertTrue(message.contains("acknowledge"))
        XCTAssertTrue(repository.hasConfiguredKid)
        XCTAssertEqual(pinStore.pin, "1234")
        XCTAssertFalse(transport.requests.contains { $0.httpMethod == "DELETE" })
    }

    func testBackgroundedDeletionKeepsProgressAndIncompleteRetryPresentation() async {
        let repository = MockWalletRepository(snapshot: .fixture())
        let service = SuspendedAccountDeletionRecorder()
        let store = WalletStore(
            repository: repository,
            initiallySignedIn: true,
            pinStore: InMemoryParentPINStore(pin: "1234"),
            identityStore: InMemoryParentIdentityStore(appleUserID: "synthetic-parent"),
            accountDeletionService: service,
            accountDeletionPendingStore: InMemoryPendingCommandStore(),
            accountDeletionSnapshotCache: TestSnapshotCache(snapshot: .fixture()),
            accountDeletionConfiguredKidStore: InMemoryConfiguredKidStore(isConfigured: true)
        )
        enterParentArea(store)
        let key = "22222222-2222-4222-8222-222222222222"

        let deletion = Task { await store.deleteAccount(idempotencyKey: key) }
        await service.waitUntilStarted()
        store.handleAppBackgrounded()

        XCTAssertEqual(store.elevation, .none)
        XCTAssertEqual(store.accountDeletionPresentation, .deleting(idempotencyKey: key))
        service.resume(with: .failure(.network("synthetic timeout")))

        guard case .incomplete = await deletion.value else { return XCTFail("the unconfirmed request must stay retryable") }
        XCTAssertEqual(store.accountDeletionPresentation, .incomplete(idempotencyKey: key))
        store.handleAppForegrounded()
        XCTAssertEqual(store.accountDeletionPresentation, .incomplete(idempotencyKey: key))
    }

    func testTransactionUpdateCannotReactivateCloudDuringDeletion() async throws {
        let persistence = TestLocalPersistence()
        let repository = try LocalWalletRepository(persistence: persistence)
        _ = try await repository.setup(ParentSetup(nickname: "Eddie"))
        let transport = StubTransport(responses: [
            .init(statusCode: 200, body: CloudContractFixtures.contextActive)
        ])
        let client = CloudAPIClient(
            baseURL: URL(string: "https://api.example.test")!,
            sessionStore: InMemorySessionStore(session: AuthSession(token: "synthetic-session", expiresAt: .distantFuture)),
            transport: transport
        )
        let coordinator = CloudCoordinator(
            client: client,
            subscriptions: CloudSubscriptionStore(client: client, observeTransactions: false)
        )
        _ = await coordinator.refreshContext()
        let service = SuspendedAccountDeletionRecorder()
        let store = WalletStore(
            repository: repository,
            initiallySignedIn: true,
            pinStore: InMemoryParentPINStore(pin: "1234"),
            identityStore: InMemoryParentIdentityStore(appleUserID: "synthetic-parent"),
            cloudCoordinator: coordinator,
            accountDeletionService: service,
            accountDeletionPendingStore: InMemoryPendingCommandStore(),
            accountDeletionSnapshotCache: TestSnapshotCache(snapshot: .fixture()),
            accountDeletionConfiguredKidStore: InMemoryConfiguredKidStore(isConfigured: true)
        )
        enterParentArea(store)
        let key = "22222222-2222-4222-8222-222222222222"

        let deletion = Task {
            await store.deleteAccount(idempotencyKey: key, acknowledgedBillingRisk: true)
        }
        await service.waitUntilStarted()
        XCTAssertFalse(repository.hasConfiguredKid)
        let requestCountAfterErase = transport.requests.count

        await coordinator.onTransactionUpdate?()

        XCTAssertEqual(transport.requests.count, requestCountAfterErase)
        XCTAssertFalse(repository.hasConfiguredKid)
        XCTAssertEqual(store.authorityState, .unconfigured)
        service.resume(with: .success(.deleted))
        let outcome = await deletion.value
        XCTAssertEqual(outcome, .deleted)
        XCTAssertFalse(repository.hasConfiguredKid)
    }

    func testIncompleteDeletionRenewsSessionAndReusesItsIdempotencyKey() async throws {
        let transport = StubTransport(responses: [
            .init(statusCode: 200, body: CloudContractFixtures.contextNoEntitlement),
            .init(statusCode: 401, body: Data()),
            .init(statusCode: 201, body: CloudContractFixtures.authenticated),
            .init(statusCode: 200, body: Data("{\"status\":\"already-deleted\"}".utf8))
        ])
        let sessionStore = InMemorySessionStore(session: AuthSession(token: "expired-by-server", expiresAt: .distantFuture))
        let client = CloudAPIClient(
            baseURL: URL(string: "https://api.example.test")!,
            sessionStore: sessionStore,
            transport: transport
        )
        let coordinator = CloudCoordinator(client: client)
        let store = WalletStore(
            repository: MockWalletRepository(snapshot: .fixture()),
            appleSignInProvider: RetryingAppleSignInProvider(),
            initiallySignedIn: true,
            pinStore: InMemoryParentPINStore(pin: "1234"),
            identityStore: InMemoryParentIdentityStore(appleUserID: "synthetic-parent"),
            cloudCoordinator: coordinator,
            accountDeletionPendingStore: InMemoryPendingCommandStore(),
            accountDeletionSnapshotCache: TestSnapshotCache(snapshot: .fixture()),
            accountDeletionConfiguredKidStore: InMemoryConfiguredKidStore(isConfigured: true)
        )
        enterParentArea(store)
        let key = "22222222-2222-4222-8222-222222222222"

        let first = await store.deleteAccount(idempotencyKey: key)
        let retry = await store.retryAccountDeletion(idempotencyKey: key)

        guard case .incomplete = first else { return XCTFail("401 must remain incomplete") }
        XCTAssertEqual(retry, .deleted)
        let deletes = transport.requests.filter { $0.httpMethod == "DELETE" && $0.url?.path == "/v1/account" }
        XCTAssertEqual(deletes.count, 2)
        XCTAssertEqual(Set(deletes.compactMap { $0.value(forHTTPHeaderField: "Idempotency-Key") }), Set([key]))
        XCTAssertTrue(transport.requests.contains { $0.httpMethod == "POST" && $0.url?.path == "/v1/auth/apple" })
    }

    func testSignOutClearsLegacySurfacesAndConfirmsFlushBeforeWalletErase() {
        let repository = MockWalletRepository(snapshot: .fixture())
        let pending = InMemoryPendingCommandStore(commands: [WalletCommand(kind: .deposit, amountCents: 100)])
        let cache = TestSnapshotCache(snapshot: .fixture())
        let configured = InMemoryConfiguredKidStore(isConfigured: true)
        var flushedAfterCleanup = false
        let store = WalletStore(
            repository: repository,
            initiallySignedIn: true,
            pinStore: InMemoryParentPINStore(pin: "1234"),
            identityStore: InMemoryParentIdentityStore(appleUserID: "synthetic-parent"),
            accountDeletionPendingStore: pending,
            accountDeletionSnapshotCache: cache,
            accountDeletionConfiguredKidStore: configured,
            accountDeletionFlush: {
                flushedAfterCleanup = pending.load().isEmpty && cache.load() == nil && !configured.isConfigured
                XCTAssertTrue(repository.hasConfiguredKid, "shared cleanup must flush before the wallet erase")
                return flushedAfterCleanup
            }
        )
        enterParentArea(store)

        store.signOut()

        XCTAssertTrue(flushedAfterCleanup)
        XCTAssertFalse(repository.hasConfiguredKid)
    }

    func testBillingNoticeAndConfirmationGateFollowRenewalState() {
        let renewing = AccountDeletionBillingNotice(entitlement: .active(accessUntil: .distantFuture, autoRenewEnabled: true))
        XCTAssertTrue(renewing.requiresAcknowledgement)
        XCTAssertFalse(renewing.allowsDeletion(typedConfirmationIsValid: true, acknowledged: false))
        XCTAssertTrue(renewing.allowsDeletion(typedConfirmationIsValid: true, acknowledged: true))

        let nonrenewing = AccountDeletionBillingNotice(entitlement: .active(accessUntil: .distantFuture, autoRenewEnabled: false))
        XCTAssertFalse(nonrenewing.requiresAcknowledgement)
        XCTAssertNotNil(nonrenewing.warning)
        XCTAssertTrue(nonrenewing.allowsDeletion(typedConfirmationIsValid: true, acknowledged: false))

        for entitlement in [CloudEntitlementState.none, .expired, .refunded, .revoked] {
            let notice = AccountDeletionBillingNotice(entitlement: entitlement)
            XCTAssertNil(notice.warning)
            XCTAssertFalse(notice.requiresAcknowledgement)
        }

        let unknown = AccountDeletionBillingNotice(entitlement: nil)
        XCTAssertTrue(unknown.requiresAcknowledgement)
    }

    private func enterParentArea(_ store: WalletStore) {
        store.openParentGate()
        for digit in "1234" {
            store.appendPINDigit(String(digit))
        }
        XCTAssertEqual(store.elevation, .active)
    }
}

@MainActor
private final class FailingClearParentPINStore: ParentPINStore {
    var pin: String? = "1234"
    func save(pin: String) throws { self.pin = pin }
    func clear() throws { throw WalletAPIError.invalidResponse("synthetic keychain failure") }
}

@MainActor
private final class FailingClearIdentityStore: ParentIdentityStore {
    private(set) var appleUserID: String? = "synthetic-parent"

    func save(appleUserID: String) throws {
        self.appleUserID = appleUserID
    }

    func clear() {}
}

@MainActor
private final class RetryingAppleSignInProvider: AppleSignInProviding, AppleIdentityAuthorizing {
    func signIn(requiredAppleUserID: String?) async throws -> AppleSignInOutcome {
        AppleSignInOutcome(appleUserID: requiredAppleUserID ?? "synthetic-parent")
    }

    func authorizeAppleIdentity(requiredAppleUserID: String?) async throws -> AppleIdentity {
        AppleIdentity(
            appleUserID: requiredAppleUserID ?? "synthetic-parent",
            identityToken: "fresh.synthetic.token",
            signedNonce: "fresh-synthetic-nonce"
        )
    }
}

@MainActor
private final class AccountDeletionRecorder: AccountDeletionPerforming {
    private let preflightResult: Result<Void, WalletAPIError>
    private let result: Result<AccountDeletionResult, WalletAPIError>
    private let onDelete: (() -> Void)?
    private(set) var preflightCount = 0
    private(set) var idempotencyKeys: [String] = []

    init(
        preflightResult: Result<Void, WalletAPIError> = .success(()),
        result: Result<AccountDeletionResult, WalletAPIError> = .success(.deleted),
        onDelete: (() -> Void)? = nil
    ) {
        self.preflightResult = preflightResult
        self.result = result
        self.onDelete = onDelete
    }

    func preflightAccountDeletion() async throws {
        preflightCount += 1
        try preflightResult.get()
    }

    func deleteAccount(idempotencyKey: String) async throws -> AccountDeletionResult {
        idempotencyKeys.append(idempotencyKey)
        onDelete?()
        return try result.get()
    }
}

@MainActor
private final class TestLocalPersistence: LocalWalletPersisting {
    private var payload: Data?
    var eraseError: WalletAPIError?

    func load() throws -> Data? { payload }
    func save(_ payload: Data) throws { self.payload = payload }
    func erase() throws {
        if let eraseError { throw eraseError }
        payload = nil
    }
}

@MainActor
private final class SuspendedAccountDeletionRecorder: AccountDeletionPerforming {
    private var started = false
    private var result: Result<AccountDeletionResult, WalletAPIError>?

    func preflightAccountDeletion() async throws {}

    func deleteAccount(idempotencyKey: String) async throws -> AccountDeletionResult {
        started = true
        while result == nil { await Task.yield() }
        return try result!.get()
    }

    func waitUntilStarted() async {
        while !started { await Task.yield() }
    }

    func resume(with result: Result<AccountDeletionResult, WalletAPIError>) {
        self.result = result
    }
}

@MainActor
private final class TestSnapshotCache: WalletSnapshotCache {
    private var snapshot: WalletSnapshot?

    init(snapshot: WalletSnapshot? = nil) {
        self.snapshot = snapshot
    }

    func load() -> WalletSnapshot? { snapshot }
    func save(_ snapshot: WalletSnapshot) { self.snapshot = snapshot }
    func clear() { snapshot = nil }
}

@MainActor
private final class FailingClearSessionStore: SessionStore {
    private(set) var session: AuthSession? = AuthSession(token: "synthetic-session", expiresAt: .distantFuture)
    var allowsClear = false

    func save(_ session: AuthSession) throws {
        self.session = session
    }

    func clear() {
        if allowsClear {
            session = nil
        }
    }
}
