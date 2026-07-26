import XCTest
@testable import EddysWallet

@MainActor
final class WalletTests: XCTestCase {
    func testParentModeRequiresPINWhenSwitchingFromChild() {
        let store = WalletStore(repository: MockWalletRepository(snapshot: .fixture(now: Date(timeIntervalSince1970: 1_700_000_000))))
        store.switchRole(to: .child)
        XCTAssertEqual(store.role, .child)

        store.switchRole(to: .parent)
        XCTAssertTrue(store.isShowingPinGate)
        XCTAssertEqual(store.role, .child)

        for digit in "1111" { store.appendPINDigit(String(digit)) }
        XCTAssertTrue(store.pinError)
        XCTAssertEqual(store.role, .child)

        for digit in "1234" { store.appendPINDigit(String(digit)) }
        XCTAssertEqual(store.role, .parent)
        XCTAssertFalse(store.isShowingPinGate)
    }

    func testParentPINMustBeConfirmedBeforeParentMode() {
        let pinStore = InMemoryParentPINStore()
        let store = WalletStore(
            repository: MockWalletRepository(snapshot: .fixture()),
            initiallySignedIn: true,
            pinStore: pinStore
        )
        XCTAssertTrue(store.needsPINSetup)
        XCTAssertFalse(store.setParentPIN("1234", confirmation: "1235"))
        XCTAssertTrue(store.needsPINSetup)
        XCTAssertTrue(store.setParentPIN("1234", confirmation: "1234"))
        XCTAssertFalse(store.needsPINSetup)
        XCTAssertEqual(pinStore.pin, "1234")
    }

    func testChildModeCannotSubmitParentMoneyCommand() async {
        let store = WalletStore(repository: MockWalletRepository(snapshot: .fixture()))
        let originalBalance = store.snapshot.acceptedBalanceCents
        store.switchRole(to: .child)

        let result = await store.submit(WalletCommand(kind: .deposit, amountCents: 1_000))
        guard case .rejected(let event) = result else {
            return XCTFail("Child mode must reject money commands")
        }
        XCTAssertEqual(event.syncState, .rejected)
        XCTAssertEqual(event.rejectionReason, "Only parent mode can record virtual money events.")
        XCTAssertEqual(store.snapshot.acceptedBalanceCents, originalBalance)
    }

    func testMoneyDisplayAlwaysUsesUSAndTwoDecimals() {
        XCTAssertEqual(Money(cents: 2_400).display, "US$24.00")
        XCTAssertEqual(Money(cents: 5).display, "US$0.05")
        XCTAssertEqual(Money.parse("24")?.cents, 2_400)
        XCTAssertEqual(Money.parse("24.5")?.cents, 2_450)
        XCTAssertNil(Money.parse("0.00"))
        XCTAssertNil(Money.parse("24.999"))
    }

    func testPendingAndRejectedUseFixedVocabulary() {
        XCTAssertEqual(SyncState.recorded.label, "Recorded")
        XCTAssertEqual(SyncState.pending.label, "Waiting to sync")
        XCTAssertEqual(SyncState.rejected.label, "Not recorded")
        XCTAssertEqual(SyncState.draft.label, "Draft on this iPad")

        let fixture = WalletSnapshot.fixture()
        XCTAssertTrue(fixture.pendingEvents.contains { $0.syncState == .pending })
        XCTAssertTrue(fixture.pendingEvents.contains { $0.syncState == .rejected })
    }

    func testRejectedWithdrawalDoesNotChangeAcceptedBalance() async {
        let repository = MockWalletRepository(snapshot: .fixture())
        let before = repository.snapshot().acceptedBalanceCents
        let result = try! await repository.submit(WalletCommand(kind: .withdrawal, amountCents: before + 1))

        guard case .rejected(let event) = result else {
            return XCTFail("Overdraft must be rejected")
        }
        XCTAssertEqual(event.syncState, .rejected)
        XCTAssertEqual(repository.snapshot().acceptedBalanceCents, before)
    }

    func testLoanAndPartialRepaymentUseExactMinorUnits() async {
        let base = WalletSnapshot(
            acceptedBalanceCents: 1_000,
            activities: [],
            loan: nil,
            allowance: nil,
            pendingEvents: [],
            lastUpdated: .now,
            isStale: false
        )
        let repository = MockWalletRepository(snapshot: base)
        _ = try! await repository.submit(WalletCommand(kind: .loan, amountCents: 1_000, reason: "Bike helmet"))
        XCTAssertEqual(repository.snapshot().acceptedBalanceCents, 2_000)
        XCTAssertEqual(repository.snapshot().loan?.remainingCents, 1_000)

        _ = try! await repository.submit(WalletCommand(kind: .repayment, amountCents: 250))
        XCTAssertEqual(repository.snapshot().acceptedBalanceCents, 1_750)
        XCTAssertEqual(repository.snapshot().loan?.remainingCents, 750)
    }
}
