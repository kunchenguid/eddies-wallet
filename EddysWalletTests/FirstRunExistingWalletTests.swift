import Foundation
import XCTest
@testable import EddysWallet

/// First-run behaviour on a fresh device whose Apple account already owns a
/// server-held wallet, plus the convergence of a device that was still reading
/// the legacy service when that wallet moved to Cloud. Everything here is
/// synthetic: no Apple account, no purchase, no real family, no production host.
@MainActor
final class FirstRunExistingWalletTests: XCTestCase {
    private var directory: URL!
    private static let baseURL = URL(string: "https://api.example.test")!
    private let lineage = UUID(uuidString: "7a1c9d40-0000-4000-8000-00000000fa11")!

    override func setUp() async throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("first-run-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Discovery before setup

    /// The reported regression: a fresh second device signs in with the same
    /// Apple identity that owns a complete legacy household and a paid Cloud
    /// entitlement, and the app goes straight to `Set up your child's wallet`.
    func testExistingLegacyWalletIsOfferedBeforeSetupAndNothingIsMutatedYet() async throws {
        let transport = discoveringTransport()
        transport.stub("GET", "/v1/cloud/legacy-context", FirstRunFixtures.legacyContext(lineage: lineage, revision: 0))
        let store = try makeStore(transport: transport)

        await store.signInWithApple()

        XCTAssertTrue(
            transport.requests.contains { $0.url?.path == "/v1/cloud/legacy-context" },
            "first-run sign-in must ask whether this exact parent already has a wallet"
        )
        XCTAssertEqual(store.rootRoute, .existingWallet)
        XCTAssertEqual(store.existingWalletRecovery, .offered(CloudExistingWalletOffer(
            lineageID: lineage,
            revision: 0,
            entitlementActive: true
        )))
        XCTAssertFalse(store.needsSetup, "setup must not be presented behind the offer")
        XCTAssertTrue(mutatingRequests(transport).isEmpty, "discovery alone must change nothing")
    }

    func testNoServerHouseholdKeepsTheOrdinaryLocalFirstSetup() async throws {
        let transport = discoveringTransport()
        transport.stub("GET", "/v1/cloud/legacy-context", FirstRunFixtures.noHouseholdContext)
        let store = try makeStore(transport: transport)

        await store.signInWithApple()

        XCTAssertEqual(store.rootRoute, .setup)
        XCTAssertTrue(store.needsSetup)
        XCTAssertNil(store.existingWalletRecovery, "there is nothing to recover")
        XCTAssertNil(store.existingWalletNotice, "an account with no wallet has nothing to explain")
        XCTAssertTrue(mutatingRequests(transport).isEmpty)
    }

    func testDetachedHouseholdIsNeverOfferedForServerRecovery() async throws {
        let transport = discoveringTransport()
        transport.stub("GET", "/v1/cloud/legacy-context", FirstRunFixtures.detachedContext(lineage: lineage))
        let store = try makeStore(transport: transport)

        await store.signInWithApple()

        XCTAssertEqual(store.rootRoute, .setup, "a wallet detached to another device stays there")
        XCTAssertNil(store.existingWalletRecovery)
        XCTAssertTrue(mutatingRequests(transport).isEmpty)
        XCTAssertFalse(transport.requests.contains { $0.url?.path == "/v1/cloud/legacy-activate" })
    }

    func testAlreadyCloudHouseholdIsAdoptedDirectlyWithoutTheLegacyTransition() async throws {
        let transport = discoveringTransport()
        transport.stub("GET", "/v1/cloud/legacy-context", FirstRunFixtures.cloudContext(lineage: lineage, revision: 4))
        transport.stub("GET", "/v1/cloud/context", FirstRunFixtures.context(lineage: lineage, revision: 4))
        transport.stub("GET", "/v1/cloud/bootstrap", FirstRunFixtures.completeWallet(lineage: lineage, revision: 4))
        let store = try makeStore(transport: transport)

        await store.signInWithApple()

        XCTAssertFalse(
            transport.requests.contains { $0.url?.path == "/v1/cloud/legacy-activate" },
            "an already-Cloud household must never be routed through the legacy transition"
        )
        XCTAssertEqual(store.rootRoute, .kidHome)
        XCTAssertTrue(store.repository is CloudWalletRepository)
        XCTAssertEqual(store.authorityState, .cloud(lineageID: lineage, revision: 4))
        XCTAssertEqual(store.snapshot.acceptedBalanceCents, 500)
        XCTAssertEqual(store.snapshot.configuredChildNickname, "Test Kid")
    }

    func testLegacyWalletWithoutActiveCloudIsNotOfferedButIsExplainedTruthfully() async throws {
        let transport = discoveringTransport()
        transport.stub(
            "GET",
            "/v1/cloud/legacy-context",
            FirstRunFixtures.legacyContext(lineage: lineage, revision: 0, entitlementActive: false)
        )
        let store = try makeStore(transport: transport)

        await store.signInWithApple()

        XCTAssertEqual(store.rootRoute, .setup)
        XCTAssertNil(store.existingWalletRecovery, "a transition may only be offered under an active entitlement")
        XCTAssertEqual(store.existingWalletNotice, .foundButCloudInactive)
        XCTAssertTrue(mutatingRequests(transport).isEmpty)
    }

    // MARK: - Accepting the offered wallet

    func testAcceptingTheOfferedWalletRecoversEveryWalletFactWithoutResetup() async throws {
        let transport = discoveringTransport()
        transport.stub("GET", "/v1/cloud/legacy-context", FirstRunFixtures.legacyContext(lineage: lineage, revision: 0))
        transport.stub(
            "POST",
            "/v1/cloud/legacy-activate",
            FirstRunFixtures.activated(lineage: lineage, revision: 1),
            headers: ["ETag": "\"rev-1\""]
        )
        transport.stub("GET", "/v1/cloud/bootstrap", FirstRunFixtures.completeWallet(lineage: lineage, revision: 1))
        let store = try makeStore(transport: transport)
        await store.signInWithApple()

        await store.acceptExistingWallet()

        let activations = transport.requests.filter { $0.url?.path == "/v1/cloud/legacy-activate" }
        XCTAssertEqual(activations.count, 1, "one acceptance is exactly one transition request")
        let activation = try XCTUnwrap(activations.first)
        XCTAssertEqual(activation.value(forHTTPHeaderField: "If-Match"), "\"rev-0\"", "the discovered revision guards the transition")
        XCTAssertNotNil(activation.value(forHTTPHeaderField: "Idempotency-Key"))
        XCTAssertEqual(activation.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic-session")
        XCTAssertNil(activation.httpBody, "the service derives the parent and household from the session alone")
        XCTAssertFalse(
            transport.requests.contains { $0.url?.path == "/v1/cloud/household/import" },
            "a recovered wallet is never re-uploaded"
        )

        XCTAssertNil(store.existingWalletRecovery)
        XCTAssertFalse(store.needsSetup, "the recovered wallet is entered without re-setup")
        XCTAssertEqual(store.rootRoute, .kidHome)
        XCTAssertEqual(store.authorityState, .cloud(lineageID: lineage, revision: 1))
        XCTAssertEqual(store.snapshot.acceptedBalanceCents, 500, "the accepted balance is not reinterpreted")
        XCTAssertEqual(store.snapshot.configuredChildNickname, "Test Kid")
        XCTAssertEqual(store.snapshot.activities.count, 4, "the whole ledger comes back")
        XCTAssertEqual(store.snapshot.activities.map(\.type), [.withdrawal, .repayment, .loan, .deposit])
        XCTAssertEqual(store.snapshot.loan?.originalCents, 300)
        XCTAssertEqual(store.snapshot.loan?.remainingCents, 200, "the repayment is preserved")
        XCTAssertEqual(store.snapshot.allowance?.amountCents, 500)
    }

    /// The recovered device holds no parent PIN yet, so the Parent door asks
    /// the owning parent to sign in and choose one - the established path,
    /// never a second setup form.
    func testRecoveredDeviceChoosesItsParentPINAtTheParentDoor() async throws {
        let store = try await recoveredStore()

        store.openParentGate()

        XCTAssertEqual(store.gateRoute, .reauth(.missingPIN))
        XCTAssertTrue(store.canVerifyOwningParent, "the signed-in parent is the owner this device verifies against")
    }

    func testDecliningRecoverySendsNoMutatingRequestAndContinuesLocalFirst() async throws {
        let transport = discoveringTransport()
        transport.stub("GET", "/v1/cloud/legacy-context", FirstRunFixtures.legacyContext(lineage: lineage, revision: 0))
        let store = try makeStore(transport: transport)
        await store.signInWithApple()
        XCTAssertEqual(store.rootRoute, .existingWallet)

        store.declineExistingWallet()

        XCTAssertEqual(store.rootRoute, .setup)
        XCTAssertTrue(store.needsSetup)
        XCTAssertNil(store.existingWalletRecovery)
        XCTAssertTrue(mutatingRequests(transport).isEmpty, "declining must send nothing at all")

        let created = await store.setupParent(ParentSetup(nickname: "Local Kid"), pin: "1357", confirmation: "1357")
        XCTAssertTrue(created)
        XCTAssertEqual(store.snapshot.configuredChildNickname, "Local Kid")
        XCTAssertTrue(store.authorityState.isLocalAuthority, "the free local wallet is the truthful result")
    }

    // MARK: - One logical action across retries

    func testALostResponseRetriesTheSameKeyAndDeliversTheActionOnce() async throws {
        let transport = discoveringTransport()
        transport.stub("GET", "/v1/cloud/legacy-context", FirstRunFixtures.legacyContext(lineage: lineage, revision: 0))
        transport.stub(
            "POST",
            "/v1/cloud/legacy-activate",
            FirstRunFixtures.activated(lineage: lineage, revision: 1),
            headers: ["ETag": "\"rev-1\""]
        )
        transport.stub("GET", "/v1/cloud/bootstrap", FirstRunFixtures.completeWallet(lineage: lineage, revision: 1))
        let store = try makeStore(transport: transport)
        await store.signInWithApple()

        // The service handled the exact request and the response was lost.
        transport.dropNextResponse("POST", "/v1/cloud/legacy-activate")
        await store.acceptExistingWallet()
        XCTAssertEqual(store.existingWalletRecovery?.refusalMessage, CloudLegacyActivationRefusal.unreachable.parentMessage)
        XCTAssertEqual(store.existingWalletRecovery?.canRetry, true)

        await store.retryExistingWalletRecovery()

        let keys = Set(transport.requests
            .filter { $0.url?.path == "/v1/cloud/legacy-activate" }
            .compactMap { $0.value(forHTTPHeaderField: "Idempotency-Key") })
        XCTAssertEqual(keys.count, 1, "a retry of the same acceptance reuses one idempotency key")
        XCTAssertEqual(transport.committedMutationCount, 1, "the service records one logical delivery")
        XCTAssertEqual(store.authorityState, .cloud(lineageID: lineage, revision: 1))
        XCTAssertEqual(store.snapshot.acceptedBalanceCents, 500)
    }

    func testAFreshAcceptanceAfterAStaleRevisionUsesANewKeyAndANewChoice() async throws {
        let transport = discoveringTransport()
        transport.enqueue("GET", "/v1/cloud/legacy-context", FirstRunFixtures.legacyContext(lineage: lineage, revision: 0))
        transport.enqueue("GET", "/v1/cloud/legacy-context", FirstRunFixtures.legacyContext(lineage: lineage, revision: 3))
        transport.stub("POST", "/v1/cloud/legacy-activate", FirstRunFixtures.revisionConflict(currentRevision: 3), status: 409)
        let store = try makeStore(transport: transport)
        await store.signInWithApple()

        await store.acceptExistingWallet()
        guard case .refused(_, .revisionChanged(let currentRevision)) = store.existingWalletRecovery else {
            return XCTFail("expected a typed revision refusal, got \(String(describing: store.existingWalletRecovery))")
        }
        XCTAssertEqual(currentRevision, 3)
        let firstKey = try XCTUnwrap(transport.requests.last?.value(forHTTPHeaderField: "Idempotency-Key"))

        // Retrying a stale acceptance re-checks the account rather than
        // re-sending: the parent chooses again against the current wallet.
        await store.retryExistingWalletRecovery()
        XCTAssertEqual(store.existingWalletRecovery, .offered(CloudExistingWalletOffer(
            lineageID: lineage,
            revision: 3,
            entitlementActive: true
        )))
        XCTAssertEqual(
            transport.requests.filter { $0.url?.path == "/v1/cloud/legacy-activate" }.count,
            1,
            "a stale acceptance is never re-sent without a fresh choice"
        )

        transport.stub(
            "POST",
            "/v1/cloud/legacy-activate",
            FirstRunFixtures.activated(lineage: lineage, revision: 4),
            headers: ["ETag": "\"rev-4\""]
        )
        transport.stub("GET", "/v1/cloud/bootstrap", FirstRunFixtures.completeWallet(lineage: lineage, revision: 4))
        await store.acceptExistingWallet()

        let activations = transport.requests.filter { $0.url?.path == "/v1/cloud/legacy-activate" }
        XCTAssertEqual(activations.count, 2)
        XCTAssertEqual(activations.last?.value(forHTTPHeaderField: "If-Match"), "\"rev-3\"")
        XCTAssertNotEqual(
            activations.last?.value(forHTTPHeaderField: "Idempotency-Key"),
            firstKey,
            "a new acceptance mints a new idempotency key"
        )
        XCTAssertEqual(store.authorityState, .cloud(lineageID: lineage, revision: 4))
    }

    // MARK: - Typed refusals

    func testTypedRefusalsAreReportedTruthfullyAndNeverLoopOrFabricateSuccess() async throws {
        let cases: [(String, Int, Data, CloudLegacyActivationRefusal, Bool)] = [
            ("entitlement", 403, FirstRunFixtures.error("CLOUD_ENTITLEMENT_REQUIRED"), .entitlementRequired, true),
            ("activation policy", 403, FirstRunFixtures.error("CLOUD_ACTIVATION_DISABLED"), .activationUnavailable, false),
            ("read-only", 503, FirstRunFixtures.error("CLOUD_SERVICE_READ_ONLY"), .serviceReadOnly, true),
            ("in progress", 409, FirstRunFixtures.error("COMMAND_IN_PROGRESS"), .commandInProgress, true),
            ("detached", 409, FirstRunFixtures.error("CLOUD_HOUSEHOLD_CONFLICT"), .householdDetached, false),
            ("stale discovery", 409, FirstRunFixtures.error("FAMILY_NOT_SETUP"), .householdMissing, false),
            ("revision required", 428, FirstRunFixtures.error("REVISION_REQUIRED"), .revisionRequired, true),
            ("key reused", 409, FirstRunFixtures.error("IDEMPOTENCY_KEY_REUSED"), .idempotencyKeyReused, true),
            ("authentication", 401, FirstRunFixtures.error("UNAUTHENTICATED"), .authenticationRequired, true),
        ]

        for (name, status, body, expected, canRetry) in cases {
            let transport = discoveringTransport()
            transport.stub("GET", "/v1/cloud/legacy-context", FirstRunFixtures.legacyContext(lineage: lineage, revision: 0))
            transport.stub("POST", "/v1/cloud/legacy-activate", body, status: status)
            let store = try makeStore(transport: transport)
            await store.signInWithApple()

            await store.acceptExistingWallet()

            guard case .refused(_, let refusal) = store.existingWalletRecovery else {
                XCTFail("\(name): expected a typed refusal, got \(String(describing: store.existingWalletRecovery))")
                continue
            }
            XCTAssertEqual(refusal, expected, name)
            XCTAssertEqual(store.existingWalletRecovery?.canRetry, canRetry, name)
            XCTAssertEqual(store.existingWalletRecovery?.refusalMessage, expected.parentMessage, name)
            XCTAssertEqual(
                transport.requests.filter { $0.url?.path == "/v1/cloud/legacy-activate" }.count,
                1,
                "\(name): a refusal must not retry itself"
            )
            XCTAssertFalse(store.authorityState.isCloudAuthority, "\(name): a refusal changes no authority")
            XCTAssertFalse(store.repository is CloudWalletRepository, "\(name): nothing was recovered")

            // The free local path stays available from every refusal.
            store.declineExistingWallet()
            XCTAssertEqual(store.rootRoute, .setup, name)
        }
    }

    func testARefusalThatCannotClearOffersNoRetryAtAll() async throws {
        let transport = discoveringTransport()
        transport.stub("GET", "/v1/cloud/legacy-context", FirstRunFixtures.legacyContext(lineage: lineage, revision: 0))
        transport.stub("POST", "/v1/cloud/legacy-activate", FirstRunFixtures.error("CLOUD_ACTIVATION_DISABLED"), status: 403)
        let store = try makeStore(transport: transport)
        await store.signInWithApple()
        await store.acceptExistingWallet()

        await store.retryExistingWalletRecovery()

        XCTAssertEqual(
            transport.requests.filter { $0.url?.path == "/v1/cloud/legacy-activate" }.count,
            1,
            "a blocker that will not clear must not be retried"
        )
    }

    /// A blocker that clears - the parent restores their subscription - lets the
    /// same accepted action through on the same protected key.
    func testTheSameAcceptedActionSucceedsOnceItsBlockerClears() async throws {
        let transport = discoveringTransport()
        transport.stub("GET", "/v1/cloud/legacy-context", FirstRunFixtures.legacyContext(lineage: lineage, revision: 0))
        transport.enqueue("POST", "/v1/cloud/legacy-activate", FirstRunFixtures.error("CLOUD_ENTITLEMENT_REQUIRED"), status: 403)
        transport.enqueue(
            "POST",
            "/v1/cloud/legacy-activate",
            FirstRunFixtures.activated(lineage: lineage, revision: 1),
            headers: ["ETag": "\"rev-1\""]
        )
        transport.stub("GET", "/v1/cloud/bootstrap", FirstRunFixtures.completeWallet(lineage: lineage, revision: 1))
        let store = try makeStore(transport: transport)
        await store.signInWithApple()

        await store.acceptExistingWallet()
        XCTAssertEqual(store.existingWalletRecovery?.canRetry, true)
        await store.retryExistingWalletRecovery()

        let keys = Set(transport.requests
            .filter { $0.url?.path == "/v1/cloud/legacy-activate" }
            .compactMap { $0.value(forHTTPHeaderField: "Idempotency-Key") })
        XCTAssertEqual(keys.count, 1, "a refused action rolls back fully, so its key is safe to reuse")
        XCTAssertEqual(store.authorityState, .cloud(lineageID: lineage, revision: 1))
        XCTAssertEqual(store.snapshot.acceptedBalanceCents, 500)
    }

    // MARK: - Offline and discovery errors

    func testDiscoveryFailureNeverStrandsOnboardingAndCanBeCheckedAgain() async throws {
        let transport = RoutingTransport()
        transport.failEverything = true
        let store = try makeStore(transport: transport)

        await store.signInWithApple()

        XCTAssertEqual(store.rootRoute, .setup, "an unreachable service still reaches the free local wallet")
        XCTAssertTrue(store.needsSetup)
        XCTAssertEqual(store.existingWalletNotice, .checkUnavailable)
        XCTAssertNil(store.existingWalletRecovery, "a failed check never auto-accepts a recovery")
        XCTAssertTrue(mutatingRequests(transport).isEmpty)

        transport.failEverything = false
        transport.stub("POST", "/v1/auth/apple", FirstRunFixtures.authenticated, status: 201)
        transport.stub("GET", "/v1/cloud/legacy-context", FirstRunFixtures.legacyContext(lineage: lineage, revision: 0))

        await store.checkForExistingWallet()

        XCTAssertEqual(store.rootRoute, .existingWallet)
        XCTAssertNil(store.existingWalletNotice)
    }

    func testDiscoveryReadFailureAfterASuccessfulSessionAlsoDegradesToLocalFirst() async throws {
        let transport = discoveringTransport()
        transport.stub("GET", "/v1/cloud/legacy-context", FirstRunFixtures.error("INTERNAL_ERROR"), status: 500)
        let store = try makeStore(transport: transport)

        await store.signInWithApple()

        XCTAssertEqual(store.rootRoute, .setup)
        XCTAssertEqual(store.existingWalletNotice, .checkUnavailable)
    }

    func testSetupInvalidatesAnExistingWalletCheckThatFinishesLater() async throws {
        let transport = discoveringTransport()
        transport.stub("GET", "/v1/cloud/legacy-context", FirstRunFixtures.noHouseholdContext)
        let store = try makeStore(transport: transport)
        await store.signInWithApple()

        transport.stub("GET", "/v1/cloud/legacy-context", FirstRunFixtures.legacyContext(lineage: lineage, revision: 3))
        transport.suspend("GET", "/v1/cloud/legacy-context")
        let check = Task { await store.checkForExistingWallet() }
        await transport.waitUntilSuspended()

        let created = await store.setupParent(
            ParentSetup(nickname: "Local Kid"),
            pin: "1357",
            confirmation: "1357"
        )
        transport.resumeSuspendedRequest()
        await check.value

        XCTAssertTrue(created)
        XCTAssertEqual(store.rootRoute, .kidHome)
        XCTAssertEqual(store.snapshot.configuredChildNickname, "Local Kid")
        XCTAssertNil(store.existingWalletRecovery)
        XCTAssertTrue(store.authorityState.isLocalAuthority)
    }

    func testSignOutFromLocalSetupClearsTheFirstRunCloudSession() async throws {
        let transport = discoveringTransport()
        transport.stub("GET", "/v1/cloud/legacy-context", FirstRunFixtures.noHouseholdContext)
        let store = try makeStore(transport: transport)

        await store.signInWithApple()
        XCTAssertFalse(store.needsCloudSignIn)

        store.signOut()

        XCTAssertTrue(store.needsCloudSignIn)
        XCTAssertFalse(store.isSignedIn)
        XCTAssertEqual(store.rootRoute, .welcome)
    }

    /// The offer is only ever made for the exact signed-in Apple account, so a
    /// re-check by a different account is refused before anything is read.
    func testACheckByADifferentAppleAccountIsRefusedBeforeAnyServiceRead() async throws {
        let transport = RoutingTransport()
        transport.failEverything = true
        let provider = FirstRunSignInProvider(appleUserID: "synthetic-parent")
        let store = try makeStore(transport: transport, provider: provider)
        await store.signInWithApple()
        XCTAssertEqual(store.existingWalletNotice, .checkUnavailable)

        let otherAccount = try makeStore(
            transport: transport,
            provider: FirstRunSignInProvider(appleUserID: "synthetic-other-parent"),
            identityStore: InMemoryParentIdentityStore(appleUserID: "synthetic-parent")
        )
        await otherAccount.checkForExistingWallet()

        XCTAssertNil(otherAccount.existingWalletRecovery)
        XCTAssertFalse(transport.requests.contains { $0.url?.path == "/v1/cloud/legacy-context" })
    }

    // MARK: - Old device convergence

    func testALegacyDeviceConvergesOntoCloudWhenItsOwnSnapshotReportsTheTransition() async throws {
        let transport = RoutingTransport()
        transport.stub("GET", "/v1/child-view", FirstRunFixtures.legacyChildView(authority: "cloud", revision: 1))
        transport.stub("GET", "/v1/cloud/context", FirstRunFixtures.context(lineage: lineage, revision: 1))
        transport.stub("GET", "/v1/cloud/bootstrap", FirstRunFixtures.completeWallet(lineage: lineage, revision: 1))
        transport.stub("GET", "/v1/cloud/changes", FirstRunFixtures.completeWallet(lineage: lineage, revision: 1))
        let (store, _) = try makeLegacyStore(transport: transport)

        await store.refresh()

        await waitUntil("the legacy device to adopt the Cloud household") {
            store.repository is CloudWalletRepository
        }
        XCTAssertEqual(store.authorityState, .cloud(lineageID: lineage, revision: 1))
        XCTAssertEqual(store.snapshot.acceptedBalanceCents, 500)
        XCTAssertEqual(store.snapshot.activities.count, 4)
        XCTAssertFalse(
            transport.requests.contains { $0.url?.path == "/v1/cloud/legacy-activate" },
            "the device that did not accept anything never transitions a household"
        )
        XCTAssertFalse(
            transport.requests.contains { $0.url?.path == "/v1/cloud/household/import" },
            "convergence never uploads a second household"
        )
    }

    func testALegacyDeviceStaysOnLegacyWhileItsOwnWriteIsStillUnresolved() async throws {
        let transport = RoutingTransport()
        transport.stub("GET", "/v1/child-view", FirstRunFixtures.legacyChildView(authority: "cloud", revision: 1))
        transport.stub("GET", "/v1/cloud/context", FirstRunFixtures.context(lineage: lineage, revision: 1))
        transport.stub("GET", "/v1/cloud/bootstrap", FirstRunFixtures.completeWallet(lineage: lineage, revision: 1))
        let pending = WalletCommand(kind: .deposit, amountCents: 250, reason: "chores")
        let (store, _) = try makeLegacyStore(transport: transport, pending: [pending])

        await store.refresh()

        XCTAssertFalse(
            store.repository is CloudWalletRepository,
            "authority must not change while a legacy parent action is unresolved"
        )
        XCTAssertFalse(transport.requests.contains { $0.url?.path == "/v1/cloud/bootstrap" })
    }

    /// A legacy-style write after the transition is refused deterministically.
    /// The parent sees that it was not recorded, the wallet is unchanged, and
    /// only then does the device converge - so nothing is lost or forked.
    func testARefusedLegacyWriteIsSurfacedAndSurvivesTheSwitchToCloud() async throws {
        let transport = RoutingTransport()
        transport.stub("GET", "/v1/wallet", FirstRunFixtures.legacyWallet(authority: "cloud", revision: 1))
        transport.stub("POST", "/v1/wallet/deposits", FirstRunFixtures.error("REVISION_REQUIRED"), status: 428)
        transport.stub("GET", "/v1/cloud/context", FirstRunFixtures.context(lineage: lineage, revision: 1))
        transport.stub("GET", "/v1/cloud/bootstrap", FirstRunFixtures.completeWallet(lineage: lineage, revision: 1))
        transport.stub("GET", "/v1/cloud/changes", FirstRunFixtures.completeWallet(lineage: lineage, revision: 1))
        let pending = WalletCommand(kind: .deposit, amountCents: 250, reason: "chores")
        let (store, _) = try makeLegacyStore(transport: transport, pending: [pending])
        store.openParentGate()
        for digit in ["1", "2", "3", "4"] { store.appendPINDigit(digit) }

        await store.refresh()

        await waitUntil("the parent device to converge after settling its own write") {
            store.repository is CloudWalletRepository
        }
        XCTAssertEqual(store.authorityState, .cloud(lineageID: lineage, revision: 1))
        XCTAssertTrue(
            store.snapshot.pendingEvents.contains { $0.syncState == .rejected && $0.amountCents == 250 },
            "the refused legacy action stays visible across the switch"
        )
        XCTAssertEqual(store.snapshot.acceptedBalanceCents, 500, "the refused action changed no accepted money")
        let depositKeys = Set(transport.requests
            .filter { $0.url?.path == "/v1/wallet/deposits" }
            .compactMap { $0.value(forHTTPHeaderField: "Idempotency-Key") })
        XCTAssertEqual(
            depositKeys,
            [pending.idempotencyKey],
            "the unresolved legacy write stays one protected request and is never re-keyed against Cloud"
        )
        XCTAssertEqual(transport.committedMutationCount, 0, "neither authority recorded it")
    }

    // MARK: - Helpers

    private func discoveringTransport() -> RoutingTransport {
        let transport = RoutingTransport()
        transport.stub("POST", "/v1/auth/apple", FirstRunFixtures.authenticated, status: 201)
        return transport
    }

    private func mutatingRequests(_ transport: RoutingTransport) -> [URLRequest] {
        transport.requests.filter { request in
            guard let method = request.httpMethod, method != "GET" else { return false }
            // The session exchange is the only non-GET first-run request, and
            // it scopes discovery to this parent without changing anything.
            return request.url?.path != "/v1/auth/apple"
        }
    }

    private func makeStore(
        transport: RoutingTransport,
        provider: FirstRunSignInProvider? = nil,
        identityStore: InMemoryParentIdentityStore? = nil
    ) throws -> WalletStore {
        let local = try LocalWalletRepository(directory: directory)
        return WalletStore(
            repository: local,
            appleSignInProvider: provider ?? FirstRunSignInProvider(),
            initiallySignedIn: false,
            pinStore: InMemoryParentPINStore(),
            identityStore: identityStore ?? InMemoryParentIdentityStore(),
            cloudCoordinator: coordinator(transport: transport, session: nil)
        )
    }

    private func recoveredStore() async throws -> WalletStore {
        let transport = discoveringTransport()
        transport.stub("GET", "/v1/cloud/legacy-context", FirstRunFixtures.legacyContext(lineage: lineage, revision: 0))
        transport.stub(
            "POST",
            "/v1/cloud/legacy-activate",
            FirstRunFixtures.activated(lineage: lineage, revision: 1),
            headers: ["ETag": "\"rev-1\""]
        )
        transport.stub("GET", "/v1/cloud/bootstrap", FirstRunFixtures.completeWallet(lineage: lineage, revision: 1))
        let store = try makeStore(transport: transport)
        await store.signInWithApple()
        await store.acceptExistingWallet()
        return store
    }

    private func makeLegacyStore(
        transport: RoutingTransport,
        pending: [WalletCommand] = []
    ) throws -> (WalletStore, LocalWalletRepository) {
        let session = AuthSession(token: "synthetic-session", expiresAt: .distantFuture)
        let legacy = APIWalletRepository(
            baseURL: Self.baseURL,
            sessionStore: InMemorySessionStore(session: session),
            transport: transport,
            cache: InMemoryWalletSnapshotCache(),
            configuredKidStore: InMemoryConfiguredKidStore(isConfigured: true),
            pendingStore: InMemoryPendingCommandStore(commands: pending)
        )
        let replica = try LocalWalletRepository(directory: directory)
        let store = WalletStore(
            repository: legacy,
            appleSignInProvider: FirstRunSignInProvider(),
            initiallySignedIn: true,
            pinStore: InMemoryParentPINStore(pin: "1234"),
            identityStore: InMemoryParentIdentityStore(appleUserID: "synthetic-parent"),
            cloudCoordinator: coordinator(transport: transport, session: session),
            localReplicaProvider: { replica }
        )
        return (store, replica)
    }

    private func coordinator(transport: RoutingTransport, session: AuthSession?) -> CloudCoordinator {
        let client = CloudAPIClient(
            baseURL: Self.baseURL,
            sessionStore: InMemorySessionStore(session: session),
            transport: transport
        )
        return CloudCoordinator(
            client: client,
            subscriptions: CloudSubscriptionStore(
                client: client,
                storeKit: StubCloudStoreKitOperations(),
                observeTransactions: false
            )
        )
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

/// A native Sign in with Apple that returns the short-lived Apple proof the
/// production coordinator returns, so the store can exchange one service
/// session inside the same user action.
@MainActor
final class FirstRunSignInProvider: AppleSignInProviding, AppleIdentityAuthorizing {
    private let appleUserID: String

    init(appleUserID: String = "synthetic-parent") {
        self.appleUserID = appleUserID
    }

    func signIn(requiredAppleUserID: String?) async throws -> AppleSignInOutcome {
        let identity = try await authorizeAppleIdentity(requiredAppleUserID: requiredAppleUserID)
        return AppleSignInOutcome(appleUserID: identity.appleUserID, identity: identity)
    }

    func authorizeAppleIdentity(requiredAppleUserID: String?) async throws -> AppleIdentity {
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

@MainActor
final class InMemoryWalletSnapshotCache: WalletSnapshotCache {
    private var stored: WalletSnapshot?

    init(snapshot: WalletSnapshot? = nil) { stored = snapshot }
    func load() -> WalletSnapshot? { stored }
    func save(_ snapshot: WalletSnapshot) { stored = snapshot }
    func clear() { stored = nil }
}

enum FirstRunFixtures {
    static let authenticated = Data("""
    {"token":"synthetic-session","expiresAt":"2099-01-01T00:00:00Z",
     "parent":{"provider":"apple","subject":"synthetic-parent","email":null}}
    """.utf8)

    static let noHouseholdContext = Data("""
    {"household":null,"entitlement":null,"exportAvailable":false}
    """.utf8)

    static func legacyContext(lineage: UUID, revision: Int64, entitlementActive: Bool = true) -> Data {
        Data("""
        {"household":{"lineageId":"\(lineage.uuidString.lowercased())","authority":"legacy_service","revision":\(revision)},
         "entitlement":{"state":"\(entitlementActive ? "active" : "expired")","accessUntil":"2027-01-01T00:00:00.000Z",
                        "graceExpiresAt":null,"lastReconciledAt":"2026-08-01T00:00:00.000Z","active":\(entitlementActive)},
         "exportAvailable":true}
        """.utf8)
    }

    static func cloudContext(lineage: UUID, revision: Int64) -> Data {
        Data("""
        {"household":{"lineageId":"\(lineage.uuidString.lowercased())","authority":"cloud","revision":\(revision)},
         "entitlement":{"state":"active","accessUntil":"2027-01-01T00:00:00.000Z","graceExpiresAt":null,
                        "lastReconciledAt":"2026-08-01T00:00:00.000Z","active":true},
         "exportAvailable":false}
        """.utf8)
    }

    static func detachedContext(lineage: UUID) -> Data {
        Data("""
        {"household":{"lineageId":"\(lineage.uuidString.lowercased())","authority":"local_detached","revision":2},
         "entitlement":{"state":"active","accessUntil":"2027-01-01T00:00:00.000Z","graceExpiresAt":null,
                        "lastReconciledAt":"2026-08-01T00:00:00.000Z","active":true},
         "exportAvailable":true}
        """.utf8)
    }

    static func context(lineage: UUID, revision: Int64) -> Data {
        Data("""
        {"storeAccountToken":"11111111-1111-4111-8111-111111111111",
         "entitlement":{"state":"active","accessUntil":"2027-01-01T00:00:00.000Z","active":true},
         "household":{"lineageId":"\(lineage.uuidString.lowercased())","authority":"cloud","revision":\(revision)}}
        """.utf8)
    }

    static func activated(lineage: UUID, revision: Int64) -> Data {
        Data("""
        {"household":{"lineageId":"\(lineage.uuidString.lowercased())","authority":"cloud","revision":\(revision)}}
        """.utf8)
    }

    static func revisionConflict(currentRevision: Int64) -> Data {
        Data("""
        {"error":{"code":"REVISION_CONFLICT","message":"This wallet changed on another device.",
                  "details":{"currentRevision":\(currentRevision)}}}
        """.utf8)
    }

    static func error(_ code: String) -> Data {
        Data("{\"error\":{\"code\":\"\(code)\",\"message\":\"The Cloud service refused this request.\"}}".utf8)
    }

    /// A complete synthetic household: one child, four accepted ledger entries,
    /// one partly repaid loan, and a weekly allowance rule.
    static func completeWallet(lineage: UUID, revision: Int64) -> Data {
        Data("""
        {"household":{"lineageId":"\(lineage.uuidString.lowercased())","authority":"cloud","revision":\(revision)},
         "family":{"id":"f-1","name":"Test Kid's family"},
         "child":{"id":"c-1","nickname":"Test Kid","avatarUrl":null},
         "wallet":{"id":"w-1","balanceCents":500},
         "entries":[
           {"id":"e-1","type":"deposit","direction":"credit","amountCents":500,"balanceBeforeCents":0,"balanceAfterCents":500,"reason":"chores","loanId":null,"recordedAt":"2026-07-24T10:00:00.000Z","acceptedRevision":\(revision)},
           {"id":"e-2","type":"loan","direction":"credit","amountCents":300,"balanceBeforeCents":500,"balanceAfterCents":800,"reason":"scooter","loanId":"96e6db14-91ea-4fa4-9a43-dddebd3d3807","recordedAt":"2026-07-25T10:00:00.000Z","acceptedRevision":\(revision)},
           {"id":"e-3","type":"repayment","direction":"debit","amountCents":100,"balanceBeforeCents":800,"balanceAfterCents":700,"reason":null,"loanId":"96e6db14-91ea-4fa4-9a43-dddebd3d3807","recordedAt":"2026-07-26T10:00:00.000Z","acceptedRevision":\(revision)},
           {"id":"e-4","type":"withdrawal","direction":"debit","amountCents":200,"balanceBeforeCents":700,"balanceAfterCents":500,"reason":"sticker book","loanId":null,"recordedAt":"2026-07-27T10:00:00.000Z","acceptedRevision":\(revision)}],
         "loans":[{"id":"96e6db14-91ea-4fa4-9a43-dddebd3d3807","principalCents":300,"outstandingCents":200,"purpose":"scooter","dueDate":null,"status":"open","createdAt":"2026-07-25T10:00:00.000Z","paidAt":null}],
         "allowanceRule":{"id":"a-1","amountCents":500,"cadence":"weekly","weekday":5,"startDate":"2026-08-07","endDate":null,"active":true},
         "nextCursor":null}
        """.utf8)
    }

    /// The legacy read routes keep working after the transition and report the
    /// authority that now owns the household.
    static func legacyChildView(authority: String, revision: Int64) -> Data {
        legacySnapshot(authority: authority, revision: revision, readOnly: true)
    }

    static func legacyWallet(authority: String, revision: Int64) -> Data {
        legacySnapshot(authority: authority, revision: revision, readOnly: false)
    }

    private static func legacySnapshot(authority: String, revision: Int64, readOnly: Bool) -> Data {
        Data("""
        {"family":{"authority":"\(authority)","revision":\(revision)},
         "child":{"nickname":"Test Kid"},
         "wallet":{"balanceCents":500,"virtualNotice":"Virtual practice only. These dollars are pretend, cannot be redeemed, and never move real money."},
         "allowanceRule":null,"loan":null,"recentActivity":[],"readOnly":\(readOnly)}
        """.utf8)
    }
}
