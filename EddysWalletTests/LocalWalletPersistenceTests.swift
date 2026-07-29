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

    func testFailedEraseKeepsWalletInMemory() async throws {
        let persistence = ControllableLocalWalletPersistence()
        let repository = try LocalWalletRepository(persistence: persistence)
        _ = try await repository.setup(ParentSetup(nickname: "Test Kid"))
        persistence.eraseError = TestPersistenceError.failed

        XCTAssertThrowsError(try repository.clearSession())
        XCTAssertTrue(repository.hasConfiguredKid)
        XCTAssertEqual(repository.snapshot().configuredChildNickname, "Test Kid")
    }
}

private enum TestPersistenceError: Error {
    case failed
}

private final class ControllableLocalWalletPersistence: LocalWalletPersisting {
    var payload: Data?
    var saveError: Error?
    var eraseError: Error?
    private(set) var saveCount = 0

    init(payload: Data? = nil) {
        self.payload = payload
    }

    func load() throws -> Data? {
        payload
    }

    func save(_ payload: Data) throws {
        if let saveError { throw saveError }
        saveCount += 1
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
