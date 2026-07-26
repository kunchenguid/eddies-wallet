import AuthenticationServices
import XCTest
@testable import EddysWallet

@MainActor
final class WalletTests: XCTestCase {
    func testMissingNicknameUsesNeutralFallbacksAndSetupStartsBlank() {
        XCTAssertTrue(SetupView.initialNickname.isEmpty)
        XCTAssertNil(ChildProfileCopy.configuredNickname(from: "   "))
        XCTAssertEqual(ChildProfileCopy.walletTitle(nickname: nil), "Your wallet")
        XCTAssertEqual(ChildProfileCopy.roleTitle(nickname: nil), "Child's view")
        XCTAssertEqual(ChildProfileCopy.childReference(nickname: nil), "your child")
        XCTAssertEqual(ChildProfileCopy.walletReference(nickname: nil), "your child's wallet")
    }

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

    func testAppleSignInTimeoutCleansUpAndLeavesRetryableStoreState() async {
        let controller = TestAppleAuthorizationController()
        let coordinator = AppleSignInCoordinator(
            authenticator: TestParentAuthenticator(),
            timeoutNanoseconds: 20_000_000,
            controllerFactory: { _ in controller }
        )
        let store = WalletStore(
            repository: MockWalletRepository(),
            appleSignInCoordinator: coordinator,
            initiallySignedIn: false
        )

        await store.signInWithApple()

        XCTAssertFalse(store.isSigningIn)
        XCTAssertEqual(store.errorMessage, WalletAPIError.timedOut.localizedDescription)
        XCTAssertEqual(controller.performCount, 1)

        do {
            _ = try await coordinator.signIn()
            XCTFail("A timed-out authorization must fail")
        } catch let error as WalletAPIError {
            XCTAssertEqual(error, .timedOut)
        } catch {
            XCTFail("Unexpected retry error: \(error)")
        }
        XCTAssertEqual(controller.performCount, 2)
    }

    func testAppleSignInCancellationCleansUpContinuation() async {
        let controller = TestAppleAuthorizationController()
        let coordinator = AppleSignInCoordinator(
            authenticator: TestParentAuthenticator(),
            timeoutNanoseconds: 1_000_000_000,
            controllerFactory: { _ in controller }
        )
        let task = Task { @MainActor () throws -> AuthSession in
            try await coordinator.signIn()
        }
        while controller.performCount == 0 {
            await Task.yield()
        }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Cancellation must finish the authorization continuation")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected cancellation error: \(error)")
        }

        let retryTask = Task { @MainActor () throws -> AuthSession in
            try await coordinator.signIn()
        }
        while controller.performCount < 2 {
            await Task.yield()
        }
        retryTask.cancel()
        do {
            _ = try await retryTask.value
            XCTFail("A cancelled retry must fail")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected retry error: \(error)")
        }
        XCTAssertEqual(controller.performCount, 2)
    }

    func testAppleAuthorizationErrorCleansUpAndDoesNotExposeAppleErrorData() async {
        let controller = TestAppleAuthorizationController()
        let coordinator = AppleSignInCoordinator(
            authenticator: TestParentAuthenticator(),
            timeoutNanoseconds: 1_000_000_000,
            controllerFactory: { _ in controller }
        )
        let task = Task { @MainActor () throws -> AuthSession in
            try await coordinator.signIn()
        }
        while controller.performCount == 0 {
            await Task.yield()
        }

        coordinator.authorizationControllerDidCompleteWithError(
            ASAuthorizationError(.failed),
            controllerID: controller.identifier
        )

        do {
            _ = try await task.value
            XCTFail("An authorization error must fail the sign-in")
        } catch let error as WalletAPIError {
            XCTAssertEqual(error, .network("Apple Sign In could not be completed. Please try again."))
        } catch {
            XCTFail("Unexpected authorization error: \(error)")
        }

        do {
            _ = try await coordinator.signIn()
            XCTFail("An authorization error must clean up the active attempt")
        } catch let error as WalletAPIError {
            XCTAssertEqual(error, .timedOut)
        } catch {
            XCTFail("Unexpected retry error: \(error)")
        }
    }

    func testAppleAuthorizationCancellationCleansUpContinuation() async {
        let controller = TestAppleAuthorizationController()
        let coordinator = AppleSignInCoordinator(
            authenticator: TestParentAuthenticator(),
            timeoutNanoseconds: 1_000_000_000,
            controllerFactory: { _ in controller }
        )
        let task = Task { @MainActor () throws -> AuthSession in
            try await coordinator.signIn()
        }
        while controller.performCount == 0 {
            await Task.yield()
        }

        coordinator.authorizationControllerDidCompleteWithError(
            ASAuthorizationError(.canceled),
            controllerID: controller.identifier
        )

        do {
            _ = try await task.value
            XCTFail("Apple cancellation must fail the sign-in")
        } catch let error as WalletAPIError {
            XCTAssertEqual(error, .cancelled)
        } catch {
            XCTFail("Unexpected Apple cancellation error: \(error)")
        }

        let retryTask = Task { @MainActor () throws -> AuthSession in
            try await coordinator.signIn()
        }
        while controller.performCount < 2 {
            await Task.yield()
        }
        retryTask.cancel()
        do {
            _ = try await retryTask.value
            XCTFail("The retry must remain cancellable")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected retry error: \(error)")
        }
    }

    func testStaleAuthorizationCallbackCannotCompleteANewAttempt() async {
        let firstController = TestAppleAuthorizationController()
        let secondController = TestAppleAuthorizationController()
        var controllers = [firstController, secondController]
        let coordinator = AppleSignInCoordinator(
            authenticator: TestParentAuthenticator(),
            timeoutNanoseconds: 1_000_000_000,
            controllerFactory: { _ in controllers.removeFirst() }
        )

        let firstTask = Task { @MainActor () throws -> AuthSession in
            try await coordinator.signIn()
        }
        while firstController.performCount == 0 {
            await Task.yield()
        }
        firstTask.cancel()
        do {
            _ = try await firstTask.value
            XCTFail("The first attempt should be cancelled")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected first-attempt error: \(error)")
        }

        let secondTask = Task { @MainActor () throws -> AuthSession in
            try await coordinator.signIn()
        }
        while secondController.performCount == 0 {
            await Task.yield()
        }
        coordinator.authorizationControllerDidCompleteWithError(
            ASAuthorizationError(.failed),
            controllerID: firstController.identifier
        )
        secondTask.cancel()

        do {
            _ = try await secondTask.value
            XCTFail("A stale callback must not complete the new attempt")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected second-attempt error: \(error)")
        }
    }
}

@MainActor
private final class TestParentAuthenticator: ParentAuthenticator {
    func authenticateApple(identityToken: String, nonce: String) async throws -> AuthSession {
        AuthSession(token: "test-session", expiresAt: Date(timeIntervalSince1970: 4_000_000_000))
    }
}

@MainActor
private final class TestAppleAuthorizationController: AppleAuthorizationController {
    private let token = NSObject()
    private(set) var performCount = 0

    var identifier: ObjectIdentifier { ObjectIdentifier(token) }

    func configure(
        delegate: ASAuthorizationControllerDelegate,
        presentationContextProvider: ASAuthorizationControllerPresentationContextProviding
    ) {}

    func performRequests() {
        performCount += 1
    }
}
