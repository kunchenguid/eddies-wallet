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

    private func enterParentArea(_ store: WalletStore) {
        store.openParentGate()
        for digit in "1234" {
            store.appendPINDigit(String(digit))
        }
        XCTAssertEqual(store.elevation, .active)
    }
}

@MainActor
private final class AccountDeletionRecorder: AccountDeletionPerforming {
    private let result: Result<AccountDeletionResult, WalletAPIError>
    private let onDelete: (() -> Void)?
    private(set) var idempotencyKeys: [String] = []

    init(
        result: Result<AccountDeletionResult, WalletAPIError> = .success(.deleted),
        onDelete: (() -> Void)? = nil
    ) {
        self.result = result
        self.onDelete = onDelete
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

    func load() throws -> Data? { payload }
    func save(_ payload: Data) throws { self.payload = payload }
    func erase() throws { payload = nil }
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
