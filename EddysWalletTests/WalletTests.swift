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

    // MARK: - Kid-first resting state (report criteria 1, 2)

    func testConfiguredStoreRestsUnelevatedOnTheKidHome() {
        let store = makeConfiguredStore()
        XCTAssertEqual(store.elevation, .none)
        XCTAssertEqual(store.viewRole, .child)
        XCTAssertFalse(store.isElevated)
    }

    func testElevationIsNeverPersistedAcrossStoreLifetimes() {
        let repository = MockWalletRepository(snapshot: .fixture())
        let pinStore = InMemoryParentPINStore(pin: "1234")
        let identityStore = InMemoryParentIdentityStore(appleUserID: "owner-1")
        let first = WalletStore(repository: repository, initiallySignedIn: true, pinStore: pinStore, identityStore: identityStore)
        first.openParentGate()
        enterPIN("1234", into: first)
        XCTAssertEqual(first.elevation, .active)

        let second = WalletStore(repository: repository, initiallySignedIn: true, pinStore: pinStore, identityStore: identityStore)
        XCTAssertEqual(second.elevation, .none, "A new launch must always rest on the kid home")
    }

    func testBackgroundingDropsElevationFromGateAndParentArea() {
        let store = makeConfiguredStore()
        store.openParentGate()
        XCTAssertEqual(store.elevation, .gate)
        store.handleAppBackgrounded()
        XCTAssertEqual(store.elevation, .none)

        store.openParentGate()
        enterPIN("1234", into: store)
        XCTAssertEqual(store.elevation, .active)
        store.handleAppBackgrounded()
        XCTAssertEqual(store.elevation, .none)
        XCTAssertEqual(store.gateRoute, .pinEntry)
        XCTAssertTrue(store.pin.isEmpty)
    }

    // MARK: - Parent gate (report criterion 3)

    func testDoorThenCorrectPINElevatesAndDoneReturns() {
        let store = makeConfiguredStore()
        store.openParentGate()
        XCTAssertEqual(store.elevation, .gate)
        XCTAssertEqual(store.gateRoute, .pinEntry)

        enterPIN("1111", into: store)
        XCTAssertTrue(store.pinError)
        XCTAssertEqual(store.elevation, .gate, "A wrong PIN must not elevate")

        enterPIN("1234", into: store)
        XCTAssertEqual(store.elevation, .active)
        XCTAssertEqual(store.viewRole, .parent)

        store.exitParentArea()
        XCTAssertEqual(store.elevation, .none)
        XCTAssertEqual(store.viewRole, .child)
    }

    func testGateCancelReturnsToKidHomeAndClearsEntry() {
        let store = makeConfiguredStore()
        store.openParentGate()
        store.appendPINDigit("1")
        store.appendPINDigit("2")
        store.cancelParentGate()
        XCTAssertEqual(store.elevation, .none)
        XCTAssertTrue(store.pin.isEmpty)
        XCTAssertFalse(store.pinError)
    }

    func testRepeatedWrongPINsStartCooldownAndIgnoreDigits() {
        let store = makeConfiguredStore(policy: ParentGatePolicy(maxAttempts: 5, cooldownSeconds: 60))
        store.openParentGate()
        for _ in 0..<5 {
            enterPIN("9999", into: store)
        }
        XCTAssertTrue(store.isCoolingDown)
        XCTAssertGreaterThan(store.cooldownSecondsRemaining, 0)
        XCTAssertEqual(store.attemptsRemaining, 0)

        store.appendPINDigit("1")
        XCTAssertTrue(store.pin.isEmpty, "The keypad must ignore digits during the cooldown")

        // The cooldown survives closing and reopening the gate.
        store.cancelParentGate()
        store.openParentGate()
        XCTAssertTrue(store.isCoolingDown)
    }

    func testCooldownExpiryAllowsANewAttempt() async throws {
        let store = makeConfiguredStore(policy: ParentGatePolicy(maxAttempts: 2, cooldownSeconds: 0.2))
        store.openParentGate()
        enterPIN("1111", into: store)
        enterPIN("2222", into: store)
        XCTAssertTrue(store.isCoolingDown)

        try await Task.sleep(nanoseconds: 400_000_000)
        enterPIN("1234", into: store)
        XCTAssertEqual(store.elevation, .active, "After the cooldown the correct PIN must work again")
    }

    // MARK: - Parent-only reachability (report criteria 3, 4)

    func testMoneyCommandsAreRejectedOutsideTheParentArea() async {
        let store = makeConfiguredStore()
        let originalBalance = store.snapshot.acceptedBalanceCents

        let result = await store.submit(WalletCommand(kind: .deposit, amountCents: 1_000))
        guard case .rejected(let event) = result else {
            return XCTFail("An un-elevated session must reject money commands")
        }
        XCTAssertEqual(event.syncState, .rejected)
        XCTAssertEqual(event.rejectionReason, "Only a parent in the Parent area can record virtual money events.")
        XCTAssertEqual(store.snapshot.acceptedBalanceCents, originalBalance)
    }

    func testMoneyCommandsAreAcceptedInsideTheParentArea() async {
        let store = makeConfiguredStore()
        store.openParentGate()
        enterPIN("1234", into: store)
        let before = store.snapshot.acceptedBalanceCents

        let result = await store.submit(WalletCommand(kind: .deposit, amountCents: 500))
        guard case .accepted = result else {
            return XCTFail("The elevated parent must be able to record a deposit")
        }
        XCTAssertEqual(store.snapshot.acceptedBalanceCents, before + 500)
    }

    func testSignOutIsIgnoredOutsideParentAreaAndClearsEverythingInside() {
        let pinStore = InMemoryParentPINStore(pin: "1234")
        let identityStore = InMemoryParentIdentityStore(appleUserID: "owner-1")
        let store = makeConfiguredStore(pinStore: pinStore, identityStore: identityStore)

        store.signOut()
        XCTAssertTrue(store.isSignedIn, "Sign-out must be unreachable outside the Parent area")
        XCTAssertEqual(pinStore.pin, "1234")

        store.openParentGate()
        enterPIN("1234", into: store)
        store.signOut()
        XCTAssertFalse(store.isSignedIn)
        XCTAssertNil(pinStore.pin)
        XCTAssertNil(identityStore.appleUserID)
        XCTAssertEqual(store.snapshot.acceptedBalanceCents, 0)
        XCTAssertEqual(store.elevation, .none)
    }

    func testChangeParentPINRequiresParentAreaAndCurrentPIN() {
        let pinStore = InMemoryParentPINStore(pin: "1234")
        let store = makeConfiguredStore(pinStore: pinStore)

        XCTAssertNotNil(store.changeParentPIN(current: "1234", new: "2468", confirmation: "2468"), "PIN change must require the Parent area")

        store.openParentGate()
        enterPIN("1234", into: store)
        XCTAssertNotNil(store.changeParentPIN(current: "0000", new: "2468", confirmation: "2468"))
        XCTAssertEqual(pinStore.pin, "1234")
        XCTAssertNil(store.changeParentPIN(current: "1234", new: "2468", confirmation: "2468"))
        XCTAssertEqual(pinStore.pin, "2468")
    }

    // MARK: - Forgotten-PIN recovery (captain decision)

    func testMissingPINRoutesToOwningParentReauthNotOpenSetup() {
        let store = makeConfiguredStore(pin: nil)
        store.openParentGate()
        XCTAssertEqual(store.gateRoute, .reauth(.missingPIN))
        XCTAssertFalse(store.completeGatePINSetup(pin: "2468", confirmation: "2468"), "PIN setup must be unreachable before owning-parent re-authentication")
        XCTAssertEqual(store.elevation, .gate)
    }

    func testRecoveryWithOwningParentAllowsNewPINAndKeepsFamilyData() async {
        let provider = FakeAppleSignInProvider(appleUserID: "owner-1")
        let pinStore = InMemoryParentPINStore(pin: "1234")
        let store = makeConfiguredStore(pinStore: pinStore, provider: provider)
        let balanceBefore = store.snapshot.acceptedBalanceCents

        store.openParentGate()
        store.requestPINRecovery()
        XCTAssertEqual(store.gateRoute, .reauth(.forgotPIN))

        await store.reauthenticateOwningParent()
        XCTAssertEqual(provider.lastRequiredAppleUserID, "owner-1", "Recovery must demand the owning parent's Apple user")
        XCTAssertEqual(store.gateRoute, .setPIN)

        XCTAssertTrue(store.completeGatePINSetup(pin: "2468", confirmation: "2468"))
        XCTAssertEqual(store.elevation, .active)
        XCTAssertEqual(pinStore.pin, "2468")
        XCTAssertEqual(store.snapshot.acceptedBalanceCents, balanceBefore, "Recovery must not touch family data")
        XCTAssertTrue(store.isSignedIn, "Recovery must not require full sign-out or re-setup")
    }

    func testRecoveryRefusesAnyOtherAppleAccount() async {
        let provider = FakeAppleSignInProvider(appleUserID: "intruder", failsIdentityCheck: true)
        let pinStore = InMemoryParentPINStore(pin: "1234")
        let store = makeConfiguredStore(pinStore: pinStore, provider: provider)

        store.openParentGate()
        store.requestPINRecovery()
        await store.reauthenticateOwningParent()

        XCTAssertEqual(store.gateRoute, .reauth(.forgotPIN), "A mismatched account must stay at re-authentication")
        XCTAssertEqual(store.gateErrorMessage, WalletAPIError.identityMismatch.localizedDescription)
        XCTAssertEqual(store.elevation, .gate)
        XCTAssertEqual(pinStore.pin, "1234", "A mismatched account must not change the PIN")
        XCTAssertFalse(store.completeGatePINSetup(pin: "0000", confirmation: "0000"))
    }

    func testRecoveryReauthResultAfterBackgroundingDoesNotResumeParentFlow() async {
        let provider = FakeAppleSignInProvider(appleUserID: "owner-1")
        provider.beforeReturning = { store in
            store?.handleAppBackgrounded()
        }
        let store = makeConfiguredStore(pin: nil, provider: provider)
        provider.store = store

        store.openParentGate()
        XCTAssertEqual(store.gateRoute, .reauth(.missingPIN))
        await store.reauthenticateOwningParent()

        XCTAssertEqual(store.elevation, .none, "A re-auth that finishes after backgrounding must not resume the gate")
        XCTAssertEqual(store.gateRoute, .pinEntry)
    }

    // MARK: - Session expiry and offline honesty (report criteria 5, 8)

    func testExpiredSessionKeepsCachedKidSnapshotAndRoutesDoorToReauth() async {
        let repository = FailingRefreshRepository(snapshot: .fixture(), error: .unauthorized)
        let store = makeConfiguredStore(repository: repository)
        let cachedBalance = store.snapshot.acceptedBalanceCents

        await store.refresh()

        XCTAssertTrue(store.sessionExpired)
        XCTAssertTrue(store.isSignedIn, "Session expiry must not dump the kid to the Welcome screen")
        XCTAssertEqual(store.elevation, .none)
        XCTAssertEqual(store.snapshot.acceptedBalanceCents, cachedBalance)

        store.openParentGate()
        XCTAssertEqual(store.gateRoute, .reauth(.sessionExpired))
    }

    func testExpiredSessionDuringParentAreaDropsElevation() async {
        let repository = FailingRefreshRepository(snapshot: .fixture(), error: nil)
        let store = makeConfiguredStore(repository: repository)
        store.openParentGate()
        enterPIN("1234", into: store)
        XCTAssertEqual(store.elevation, .active)

        repository.error = .unauthorized
        await store.refresh()

        XCTAssertEqual(store.elevation, .none, "A 401 during an elevated session must drop elevation")
        XCTAssertTrue(store.sessionExpired)
    }

    func testOfflineRefreshKeepsSnapshotAndSetsKidOfflineState() async {
        let repository = FailingRefreshRepository(
            snapshot: .fixture(),
            error: .network("The network is unavailable. The accepted balance was not changed.")
        )
        let store = makeConfiguredStore(repository: repository)
        let cachedBalance = store.snapshot.acceptedBalanceCents

        await store.refresh()

        XCTAssertTrue(store.isOffline)
        XCTAssertEqual(store.snapshot.acceptedBalanceCents, cachedBalance)
        XCTAssertNotNil(store.errorMessage, "Parent surfaces keep the precise message")
    }

    func testKidCopyNeverUsesParentOrTechnicalVocabulary() {
        let banner = KidCopy.offlineBanner(lastUpdated: Date(timeIntervalSince1970: 1_700_000_000))
        for copy in [banner, KidCopy.sessionBanner, KidCopy.emptyWalletTitle, KidCopy.emptyWalletMessage] {
            for term in ["accepted balance", "sync", "session", "network"] {
                XCTAssertFalse(copy.localizedCaseInsensitiveContains(term), "Kid copy must not contain '\(term)': \(copy)")
            }
        }
        XCTAssertTrue(banner.hasPrefix("You're offline"))
    }

    // MARK: - Setup handoff (report criteria 6, 9)

    func testSetupCompletionEntersParentAreaWithFirstActionsHandoff() async {
        let store = makeConfiguredStore(pin: nil)
        let setup = ParentSetup(nickname: "Eddie", lessonAgeBand: "school-age")

        let created = await store.setupParent(setup, pin: "1234", confirmation: "1234")

        XCTAssertTrue(created)
        XCTAssertEqual(store.elevation, .active, "Setup completion must land in the Parent area")
        XCTAssertTrue(store.showsFirstActionsHandoff)

        store.exitParentArea()
        XCTAssertEqual(store.elevation, .none)
        XCTAssertFalse(store.showsFirstActionsHandoff, "The handoff spotlight is transient")
    }

    func testSetupRejectsUnconfirmedPIN() async {
        let store = makeConfiguredStore(pin: nil)
        let setup = ParentSetup(nickname: "Eddie", lessonAgeBand: "school-age")
        let created = await store.setupParent(setup, pin: "1234", confirmation: "1235")
        XCTAssertFalse(created)
        XCTAssertEqual(store.elevation, .none)
    }

    // MARK: - Money and honesty invariants (unchanged behavior)

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

    // MARK: - Apple Sign In coordinator (unchanged flows plus identity check)

    func testAppleSignInTimeoutCleansUpAndLeavesRetryableStoreState() async {
        let controller = TestAppleAuthorizationController()
        let coordinator = AppleSignInCoordinator(
            authenticator: TestParentAuthenticator(),
            timeoutNanoseconds: 20_000_000,
            controllerFactory: { _ in controller }
        )
        controller.onCancel = {
            coordinator.authorizationControllerDidCompleteWithError(
                ASAuthorizationError(.failed),
                controllerID: controller.identifier
            )
        }
        let store = WalletStore(
            repository: MockWalletRepository(),
            appleSignInProvider: coordinator,
            initiallySignedIn: false
        )

        await store.signInWithApple()

        XCTAssertFalse(store.isSigningIn)
        XCTAssertEqual(store.errorMessage, WalletAPIError.timedOut.localizedDescription)
        XCTAssertEqual(controller.performCount, 1)
        XCTAssertEqual(controller.cancelCount, 1)

        do {
            _ = try await coordinator.signIn(requiredAppleUserID: nil)
            XCTFail("A timed-out authorization must fail")
        } catch let error as WalletAPIError {
            XCTAssertEqual(error, .timedOut)
        } catch {
            XCTFail("Unexpected retry error: \(error)")
        }
        XCTAssertEqual(controller.performCount, 2)
        XCTAssertEqual(controller.cancelCount, 2)
    }

    func testAppleSignInCancellationCleansUpContinuation() async {
        let controller = TestAppleAuthorizationController()
        let coordinator = AppleSignInCoordinator(
            authenticator: TestParentAuthenticator(),
            timeoutNanoseconds: 1_000_000_000,
            controllerFactory: { _ in controller }
        )
        let task = Task { @MainActor () throws -> AppleSignInOutcome in
            try await coordinator.signIn(requiredAppleUserID: nil)
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
        XCTAssertEqual(controller.cancelCount, 1)

        let retryTask = Task { @MainActor () throws -> AppleSignInOutcome in
            try await coordinator.signIn(requiredAppleUserID: nil)
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
        XCTAssertEqual(controller.cancelCount, 2)
    }

    func testAppleAuthorizationErrorCleansUpAndDoesNotExposeAppleErrorData() async {
        let controller = TestAppleAuthorizationController()
        let coordinator = AppleSignInCoordinator(
            authenticator: TestParentAuthenticator(),
            timeoutNanoseconds: 1_000_000_000,
            controllerFactory: { _ in controller }
        )
        let task = Task { @MainActor () throws -> AppleSignInOutcome in
            try await coordinator.signIn(requiredAppleUserID: nil)
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
        XCTAssertEqual(controller.cancelCount, 0)

        do {
            _ = try await coordinator.signIn(requiredAppleUserID: nil)
            XCTFail("An authorization error must clean up the active attempt")
        } catch let error as WalletAPIError {
            XCTAssertEqual(error, .timedOut)
        } catch {
            XCTFail("Unexpected retry error: \(error)")
        }
        XCTAssertEqual(controller.cancelCount, 1)
    }

    func testAppleAuthorizationCancellationCleansUpContinuation() async {
        let controller = TestAppleAuthorizationController()
        let coordinator = AppleSignInCoordinator(
            authenticator: TestParentAuthenticator(),
            timeoutNanoseconds: 1_000_000_000,
            controllerFactory: { _ in controller }
        )
        let task = Task { @MainActor () throws -> AppleSignInOutcome in
            try await coordinator.signIn(requiredAppleUserID: nil)
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

        let retryTask = Task { @MainActor () throws -> AppleSignInOutcome in
            try await coordinator.signIn(requiredAppleUserID: nil)
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
        XCTAssertEqual(controller.cancelCount, 1)
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

        let firstTask = Task { @MainActor () throws -> AppleSignInOutcome in
            try await coordinator.signIn(requiredAppleUserID: nil)
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

        let secondTask = Task { @MainActor () throws -> AppleSignInOutcome in
            try await coordinator.signIn(requiredAppleUserID: nil)
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
        XCTAssertEqual(firstController.cancelCount, 1)
        XCTAssertEqual(secondController.cancelCount, 1)
    }

    // MARK: - Helpers

    private func makeConfiguredStore(
        pin: String? = "1234",
        repository: (any WalletRepository)? = nil,
        pinStore: InMemoryParentPINStore? = nil,
        identityStore: InMemoryParentIdentityStore? = nil,
        provider: FakeAppleSignInProvider? = nil,
        policy: ParentGatePolicy = .standard
    ) -> WalletStore {
        WalletStore(
            repository: repository ?? MockWalletRepository(snapshot: .fixture()),
            appleSignInProvider: provider,
            initiallySignedIn: true,
            pinStore: pinStore ?? InMemoryParentPINStore(pin: pin),
            identityStore: identityStore ?? InMemoryParentIdentityStore(appleUserID: "owner-1"),
            gatePolicy: policy
        )
    }

    private func enterPIN(_ pin: String, into store: WalletStore) {
        for digit in pin {
            store.appendPINDigit(String(digit))
        }
    }
}

@MainActor
private final class FakeAppleSignInProvider: AppleSignInProviding {
    private let appleUserID: String
    private let failsIdentityCheck: Bool
    private(set) var lastRequiredAppleUserID: String??
    weak var store: WalletStore?
    var beforeReturning: ((WalletStore?) -> Void)?

    init(appleUserID: String, failsIdentityCheck: Bool = false) {
        self.appleUserID = appleUserID
        self.failsIdentityCheck = failsIdentityCheck
    }

    func signIn(requiredAppleUserID: String?) async throws -> AppleSignInOutcome {
        lastRequiredAppleUserID = requiredAppleUserID
        if failsIdentityCheck || (requiredAppleUserID != nil && requiredAppleUserID != appleUserID) {
            throw WalletAPIError.identityMismatch
        }
        beforeReturning?(store)
        return AppleSignInOutcome(
            session: AuthSession(token: "fake-session", expiresAt: Date(timeIntervalSince1970: 4_000_000_000)),
            appleUserID: appleUserID
        )
    }
}

@MainActor
private final class FailingRefreshRepository: WalletRepository {
    private let inner: MockWalletRepository
    var error: WalletAPIError?

    init(snapshot: WalletSnapshot, error: WalletAPIError?) {
        self.inner = MockWalletRepository(snapshot: snapshot)
        self.error = error
    }

    var isAuthenticated: Bool { true }
    func snapshot() -> WalletSnapshot { inner.snapshot() }
    func refresh(for role: UserRole) async throws -> WalletSnapshot {
        if let error { throw error }
        return try await inner.refresh(for: role)
    }
    func activity(limit: Int) async throws -> [WalletEvent] { try await inner.activity(limit: limit) }
    func activityDetail(remoteID: String) async throws -> WalletEvent { try await inner.activityDetail(remoteID: remoteID) }
    func loanDetail(remoteID: String) async throws -> LoanDetail { try await inner.loanDetail(remoteID: remoteID) }
    func submit(_ command: WalletCommand) async throws -> CommandResult { try await inner.submit(command) }
    func setAllowance(_ command: AllowanceRuleCommand) async throws -> WalletSnapshot { try await inner.setAllowance(command) }
    func setup(_ setup: ParentSetup) async throws -> WalletSnapshot { try await inner.setup(setup) }
    func clearSession() { inner.clearSession() }
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
    private(set) var cancelCount = 0
    var onCancel: (() -> Void)?

    var identifier: ObjectIdentifier { ObjectIdentifier(token) }

    func configure(
        delegate: ASAuthorizationControllerDelegate,
        presentationContextProvider: ASAuthorizationControllerPresentationContextProviding
    ) {}

    func performRequests() {
        performCount += 1
    }

    func cancel() {
        cancelCount += 1
        onCancel?()
    }
}
