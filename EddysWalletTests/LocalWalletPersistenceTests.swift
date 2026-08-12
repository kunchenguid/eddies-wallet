import XCTest
@testable import EddysWallet

@MainActor
final class LocalWalletPersistenceTests: XCTestCase {
    func testFreeLocalWalletRecordsEveryCoreMoneyFlowWithoutNetwork() async throws {
        let repository = try LocalWalletRepository(inMemory: true)
        _ = try await repository.setup(ParentSetup(nickname: "Test Kid"))
        _ = try await repository.setAllowance(AllowanceRuleCommand(amountCents: 500, weekday: 1, startDate: .now))
        _ = try await repository.submit(WalletCommand(kind: .deposit, amountCents: 1_000))
        _ = try await repository.submit(WalletCommand(kind: .withdrawal, amountCents: 200))
        _ = try await repository.submit(WalletCommand(kind: .loan, amountCents: 400, reason: "Practice"))
        let repayment = try await repository.submit(WalletCommand(kind: .repayment, amountCents: 100))

        guard case .accepted(let event) = repayment else { return XCTFail("Local repayment should be recorded") }
        XCTAssertEqual(event.syncState, .recorded)
        XCTAssertEqual(repository.snapshot().acceptedBalanceCents, 1_100)
        XCTAssertEqual(repository.snapshot().loan?.remainingCents, 300)
        XCTAssertEqual(repository.snapshot().allowance?.amountCents, 500)
        XCTAssertFalse(repository.snapshot().isStale)
        XCTAssertTrue(repository.snapshot().pendingEvents.isEmpty)
    }

    func testLocalMissedAllowanceRecordAllSettlesOnlyPastWeeksAndLeavesTodayForTheSinglePath() async throws {
        let repository = try LocalWalletRepository(inMemory: true)
        _ = try await repository.setup(ParentSetup(nickname: "Test Kid"))
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let firstMissed = try XCTUnwrap(calendar.date(byAdding: .day, value: -21, to: today))
        _ = try await repository.setAllowance(
            AllowanceRuleCommand(amountCents: 500, weekday: calendar.component(.weekday, from: firstMissed) - 1, startDate: firstMissed)
        )
        let store = WalletStore(
            repository: repository,
            initiallySignedIn: true,
            pinStore: InMemoryParentPINStore(pin: "1234"),
            identityStore: InMemoryParentIdentityStore(appleUserID: "owner")
        )
        store.openParentGate()
        for digit in ["1", "2", "3", "4"] { store.appendPINDigit(digit) }

        XCTAssertEqual(store.missedAllowancePayouts.count, 3)
        XCTAssertEqual(store.missedAllowancePayouts.totalCents, 1_500)
        XCTAssertEqual(store.missedAllowancePayouts.occurrences.map(\.dueDate), [
            firstMissed,
            try XCTUnwrap(calendar.date(byAdding: .day, value: 7, to: firstMissed)),
            try XCTUnwrap(calendar.date(byAdding: .day, value: 14, to: firstMissed)),
        ])
        XCTAssertEqual(
            calendar.startOfDay(for: try XCTUnwrap(store.snapshot.allowance?.nextCurrentOrFuturePayout(calendar: calendar))),
            today
        )

        let outcome = await store.recordAllMissedAllowance()
        XCTAssertEqual(outcome, .recorded(count: 3, totalCents: 1_500))
        XCTAssertEqual(store.snapshot.acceptedBalanceCents, 1_500)
        XCTAssertEqual(store.snapshot.activities.filter { $0.type == .allowance }.count, 3)
        XCTAssertEqual(calendar.startOfDay(for: try XCTUnwrap(store.snapshot.allowance?.nextDate)), today)
        XCTAssertTrue(store.missedAllowancePayouts.isEmpty)

        let noOpBalance = store.snapshot.acceptedBalanceCents
        let noOp = await store.recordAllMissedAllowance()
        XCTAssertEqual(noOp, .noMissed)
        XCTAssertEqual(store.snapshot.acceptedBalanceCents, noOpBalance)
    }

    func testInterruptedLocalRecordAllKeepsAcceptedPrefixAndResumesWithoutDuplicates() async throws {
        let persistence = ControllableLocalWalletPersistence()
        let repository = try LocalWalletRepository(persistence: persistence)
        _ = try await repository.setup(ParentSetup(nickname: "Test Kid"))
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let firstMissed = try XCTUnwrap(calendar.date(byAdding: .day, value: -21, to: today))
        _ = try await repository.setAllowance(
            AllowanceRuleCommand(amountCents: 500, weekday: calendar.component(.weekday, from: firstMissed) - 1, startDate: firstMissed)
        )
        let store = WalletStore(
            repository: repository,
            initiallySignedIn: true,
            pinStore: InMemoryParentPINStore(pin: "1234"),
            identityStore: InMemoryParentIdentityStore(appleUserID: "owner")
        )
        store.openParentGate()
        for digit in ["1", "2", "3", "4"] { store.appendPINDigit(digit) }
        persistence.failOnNextSaveNumber = persistence.saveCount + 2

        let interrupted = await store.recordAllMissedAllowance()
        guard case .partial(let recordedCount, let recordedTotalCents, let remaining) = interrupted else {
            return XCTFail("a failed second save must leave a partial settlement")
        }
        XCTAssertEqual(recordedCount, 1)
        XCTAssertEqual(recordedTotalCents, 500)
        XCTAssertEqual(remaining.count, 2)
        XCTAssertEqual(store.snapshot.acceptedBalanceCents, 500)
        XCTAssertEqual(store.snapshot.activities.filter { $0.type == .allowance }.count, 1)
        XCTAssertEqual(store.missedAllowancePayouts.count, 2)

        let resumed = await store.recordAllMissedAllowance()
        XCTAssertEqual(resumed, .recorded(count: 2, totalCents: 1_000))
        XCTAssertEqual(store.snapshot.acceptedBalanceCents, 1_500)
        XCTAssertEqual(store.snapshot.activities.filter { $0.type == .allowance }.count, 3)
        XCTAssertTrue(store.missedAllowancePayouts.isEmpty)
    }

    func testLocalRejectedDebitNeverChangesAcceptedBalance() async throws {
        let repository = try LocalWalletRepository(inMemory: true)
        _ = try await repository.setup(ParentSetup(nickname: "Test Kid"))
        let result = try await repository.submit(WalletCommand(kind: .withdrawal, amountCents: 1))
        guard case .rejected = result else { return XCTFail("Overdraft should be rejected") }
        XCTAssertEqual(repository.snapshot().acceptedBalanceCents, 0)
    }

    func testFailedSaveDoesNotPublishCandidateState() async throws {
        let persistence = ControllableLocalWalletPersistence()
        let repository = try LocalWalletRepository(persistence: persistence)
        _ = try await repository.setup(ParentSetup(nickname: "Test Kid"))
        persistence.saveError = TestPersistenceError.failed

        await XCTAssertThrowsErrorAsync {
            _ = try await repository.submit(WalletCommand(kind: .deposit, amountCents: 500))
        }

        XCTAssertEqual(repository.snapshot().acceptedBalanceCents, 0)
        XCTAssertTrue(repository.snapshot().activities.isEmpty)
    }

    func testCorruptPersistedWalletIsConfiguredAndCannotBeReplaced() async throws {
        let persistence = ControllableLocalWalletPersistence(payload: Data("not-json".utf8))
        let repository = try LocalWalletRepository(persistence: persistence)

        XCTAssertTrue(repository.hasConfiguredKid)
        XCTAssertTrue(repository.isReadOnly)
        await XCTAssertThrowsErrorAsync {
            _ = try await repository.setup(ParentSetup(nickname: "Replacement"))
        }
        XCTAssertEqual(persistence.saveCount, 0)
    }

    func testCorruptPersistedWalletRoutesToRecoveryInsteadOfZeroBalance() throws {
        let persistence = ControllableLocalWalletPersistence(payload: Data("not-json".utf8))
        let repository = try LocalWalletRepository(persistence: persistence)
        let store = WalletStore(
            repository: repository,
            pinStore: InMemoryParentPINStore(pin: "1234"),
            identityStore: InMemoryParentIdentityStore(appleUserID: "owner")
        )

        XCTAssertEqual(store.rootRoute, .recovery)
        XCTAssertEqual(store.recoveryState, .historyUnavailable)
        XCTAssertEqual(store.authorityState, .localRecovery(.historyUnavailable))
    }

    func testFailedEraseKeepsWalletInMemory() async throws {
        let persistence = ControllableLocalWalletPersistence()
        let repository = try LocalWalletRepository(persistence: persistence)
        _ = try await repository.setup(ParentSetup(nickname: "Test Kid"))
        persistence.eraseError = TestPersistenceError.failed

        XCTAssertThrowsError(try repository.clearSession())
        XCTAssertTrue(repository.hasConfiguredKid)
        XCTAssertEqual(repository.snapshot().configuredChildNickname, "Test Kid")
    }

    func testLegacyInputsSelectCompatibilityRepository() throws {
        let legacySnapshot = WalletSnapshot.fixture()
        let local = try LocalWalletRepository(inMemory: true, legacySnapshot: legacySnapshot, hasLegacyMarker: true)
        let compatibility = MockWalletRepository(snapshot: legacySnapshot)

        let selected = WalletRepositoryFactory.select(local: local, legacy: compatibility)

        XCTAssertTrue(selected === compatibility)
        XCTAssertTrue(local.hasLegacyInputs)
    }

    func testLocalAggregateTakesPrecedenceOverLegacyCompatibility() async throws {
        let persistence = ControllableLocalWalletPersistence()
        let original = try LocalWalletRepository(persistence: persistence)
        _ = try await original.setup(ParentSetup(nickname: "Test Kid"))
        let local = try LocalWalletRepository(persistence: persistence, legacySnapshot: WalletSnapshot.fixture(), hasLegacyMarker: true)
        let compatibility = MockWalletRepository()

        let selected = WalletRepositoryFactory.select(local: local, legacy: compatibility)

        XCTAssertTrue(selected === local)
        XCTAssertFalse(local.hasLegacyInputs)
    }

    func testLocalPersistenceOpenFailureRoutesToRecovery() {
        let selected = WalletRepositoryFactory.makeDefault(
            localProvider: { throw TestPersistenceError.failed },
            legacyProvider: { MockWalletRepository() }
        )
        let store = WalletStore(
            repository: selected,
            pinStore: InMemoryParentPINStore(pin: "1234"),
            identityStore: InMemoryParentIdentityStore(appleUserID: "owner")
        )

        XCTAssertTrue(selected is LocalWalletRecoveryRepository)
        XCTAssertEqual(store.rootRoute, .recovery)
        XCTAssertEqual(store.recoveryState, .storageUnavailable)
    }
}

private enum TestPersistenceError: Error {
    case failed
}

private final class ControllableLocalWalletPersistence: LocalWalletPersisting {
    var payload: Data?
    var saveError: Error?
    var eraseError: Error?
    var failOnNextSaveNumber: Int?
    private(set) var saveCount = 0

    init(payload: Data? = nil) {
        self.payload = payload
    }

    func load() throws -> Data? {
        payload
    }

    func save(_ payload: Data) throws {
        if let saveError { throw saveError }
        let nextSaveNumber = saveCount + 1
        if failOnNextSaveNumber == nextSaveNumber {
            failOnNextSaveNumber = nil
            throw TestPersistenceError.failed
        }
        saveCount = nextSaveNumber
        self.payload = payload
    }

    func erase() throws {
        if let eraseError { throw eraseError }
        payload = nil
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected an error", file: file, line: line)
    } catch {}
}
