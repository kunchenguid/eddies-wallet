import Foundation
import XCTest
@testable import EddysWallet

@MainActor
final class APIRepositoryTests: XCTestCase {
    func testBuiltBundleAndBackendAudienceUseRegisteredAppleAppID() {
        XCTAssertEqual(AppleAppIdentity.bundleIdentifier, "com.kunchenguid.eddieswallet")
        XCTAssertEqual(AppleAppIdentity.backendAppleAudience, "com.kunchenguid.eddieswallet")
        XCTAssertEqual(AppleAppIdentity.testBundleIdentifier, "com.kunchenguid.eddieswallet.tests")
        XCTAssertEqual(Bundle(for: APIRepositoryTests.self).bundleIdentifier, AppleAppIdentity.testBundleIdentifier)
        XCTAssertEqual(Bundle(identifier: AppleAppIdentity.bundleIdentifier)?.bundleIdentifier, AppleAppIdentity.bundleIdentifier)
    }

    func testKeychainServiceMigrationUsesInPlaceLegacyRenameWithoutSecretData() {
        XCTAssertEqual(KeychainServiceMigration.currentSessionService, "com.kunchenguid.eddieswallet.session")
        XCTAssertEqual(KeychainServiceMigration.currentParentPINService, "com.kunchenguid.eddieswallet.parent-pin")
        XCTAssertEqual(
            KeychainServiceMigration.legacyService(forCurrentService: KeychainServiceMigration.currentSessionService),
            "com.kunchenguid.eddyswallet.session"
        )
        XCTAssertEqual(
            KeychainServiceMigration.legacyService(forCurrentService: KeychainServiceMigration.currentParentPINService),
            "com.kunchenguid.eddyswallet.parent-pin"
        )
        XCTAssertNil(KeychainServiceMigration.legacyService(forCurrentService: "com.example.other"))
    }

    func testProductionConfigurationShipsTheRealBackendURL() {
        XCTAssertEqual(APIConfiguration.productionBaseURLString, "https://eddieswallet.kunchenguid.com")
        XCTAssertEqual(APIConfiguration.productionBaseURL.absoluteString, "https://eddieswallet.kunchenguid.com")
    }

    func testCloudTransaction202PreservesServerPendingStatus() async throws {
        let transport = StubHTTPTransport(responses: [
            StubHTTPTransport.Response(statusCode: 202, body: Data())
        ])
        let client = CloudAPIClient(
            baseURL: URL(string: "https://api.example.test")!,
            sessionStore: InMemorySessionStore(session: validSession),
            transport: transport
        )

        do {
            _ = try await client.deliver(transactionJWS: "signed-jws")
            XCTFail("Expected verification to remain pending")
        } catch let error as WalletAPIError {
            guard case .server(let statusCode, let code, _) = error.operationError else {
                return XCTFail("Unexpected wallet error: \(error)")
            }
            XCTAssertEqual(statusCode, 202)
            XCTAssertEqual(code, "VERIFICATION_PENDING")
            XCTAssertEqual(error.transportDiagnostic?.httpStatus, 202)
            XCTAssertEqual(error.transportDiagnostic?.route, "/v1/cloud/transactions")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testWalletSnapshotMapsConfiguredChildNicknameFromService() async throws {
        let repository = APIWalletRepository(
            baseURL: URL(string: "https://api.example.test")!,
            sessionStore: InMemorySessionStore(session: validSession),
            transport: StubHTTPTransport(responses: [StubHTTPTransport.Response(statusCode: 200, body: snapshotBody(balance: 150, nickname: "Maya"))]),
            cache: TestSnapshotCache(),
            configuredKidStore: InMemoryConfiguredKidStore()
        )

        _ = try await repository.refresh(for: .parent)

        XCTAssertEqual(repository.snapshot().childNickname, "Maya")
        XCTAssertEqual(repository.snapshot().configuredChildNickname, "Maya")
    }

    func testFamilySetupPostsNicknameOnlyAndOmitsLessonsEraFields() async throws {
        // Pre-fix shape sent a fixed residual lessonAgeBand; omission is now required.
        let transport = StubHTTPTransport(responses: [
            StubHTTPTransport.Response(
                statusCode: 201,
                // Live backend may still echo a temporary legacy response key; decoding must ignore it.
                body: snapshotBody(balance: 0, nickname: "Eddie", extraChildFields: #""lessonAgeBand":"school-age""#)
            )
        ])
        let configuredKidStore = InMemoryConfiguredKidStore()
        let repository = APIWalletRepository(
            baseURL: URL(string: "https://api.example.test")!,
            sessionStore: InMemorySessionStore(session: validSession),
            transport: transport,
            cache: TestSnapshotCache(),
            configuredKidStore: configuredKidStore
        )

        let snapshot = try await repository.setup(
            ParentSetup(
                familyName: "Chen family",
                nickname: "Eddie",
                avatarURL: URL(string: "https://cdn.example.test/eddie.png"),
                idempotencyKey: "setup-key-1"
            )
        )

        XCTAssertEqual(snapshot.configuredChildNickname, "Eddie")
        XCTAssertTrue(configuredKidStore.isConfigured)
        XCTAssertEqual(transport.requests.count, 1)
        let post = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(post.httpMethod, "POST")
        XCTAssertEqual(post.url?.path, "/v1/family/setup")
        XCTAssertEqual(post.value(forHTTPHeaderField: "Idempotency-Key"), "setup-key-1")

        let body = try XCTUnwrap(post.httpBody).jsonObject()
        XCTAssertEqual(body["nickname"] as? String, "Eddie")
        XCTAssertEqual(body["familyName"] as? String, "Chen family")
        XCTAssertEqual(body["avatarUrl"] as? String, "https://cdn.example.test/eddie.png")
        XCTAssertEqual(Set(body.keys), Set(["nickname", "familyName", "avatarUrl"]))
        XCTAssertNil(body["lessonAgeBand"])
        XCTAssertNil(body["lesson_age_band"])
        XCTAssertFalse(body.keys.contains(where: { $0.lowercased().contains("lesson") }))
        XCTAssertFalse(body.keys.contains(where: { $0.lowercased().contains("ageband") || $0.lowercased().contains("age_band") }))

        if let evidencePath = ProcessInfo.processInfo.environment["EW_EVIDENCE_DIR"], !evidencePath.isEmpty {
            let evidenceDirectory = URL(fileURLWithPath: evidencePath, isDirectory: true)
            try FileManager.default.createDirectory(at: evidenceDirectory, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: body, options: [.prettyPrinted, .sortedKeys])
                .write(to: evidenceDirectory.appendingPathComponent("family-setup-request.json"))
        }
    }

    func testUpdateChildProfilePutsNicknameAndUpdatesParentAndChildCaches() async throws {
        let transport = StubHTTPTransport(responses: [
            StubHTTPTransport.Response(statusCode: 200, body: snapshotBody(balance: 150, nickname: "Eddie")),
            StubHTTPTransport.Response(statusCode: 200, body: snapshotBody(balance: 150, nickname: "Maya")),
            StubHTTPTransport.Response(statusCode: 200, body: snapshotBody(balance: 150, nickname: "Maya", readOnly: true))
        ])
        let cache = TestSnapshotCache()
        let childLastUpdated = Date(timeIntervalSince1970: 1_700_000_000)
        cache.value = WalletSnapshot(
            acceptedBalanceCents: 75,
            activities: [],
            loan: nil,
            allowance: nil,
            pendingEvents: [],
            lastUpdated: childLastUpdated,
            isStale: true,
            childNickname: "Eddie"
        )
        let repository = APIWalletRepository(
            baseURL: URL(string: "https://api.example.test")!,
            sessionStore: InMemorySessionStore(session: validSession),
            transport: transport,
            cache: cache,
            configuredKidStore: InMemoryConfiguredKidStore()
        )

        _ = try await repository.refresh(for: .parent)
        _ = try await repository.updateChildProfile(ChildProfileUpdate(nickname: "  Maya  ", idempotencyKey: "child-profile-1"))

        XCTAssertEqual(repository.snapshot().configuredChildNickname, "Maya")
        XCTAssertEqual(repository.childSnapshot().configuredChildNickname, "Maya")
        XCTAssertEqual(cache.load()?.configuredChildNickname, "Maya")
        XCTAssertEqual(repository.childSnapshot().acceptedBalanceCents, 75)
        XCTAssertEqual(repository.childSnapshot().lastUpdated, childLastUpdated)
        XCTAssertTrue(repository.childSnapshot().isStale)
        XCTAssertEqual(cache.load()?.lastUpdated, childLastUpdated)
        XCTAssertTrue(cache.load()?.isStale == true)

        let put = transport.requests[1]
        XCTAssertEqual(put.httpMethod, "PUT")
        XCTAssertEqual(put.url?.path, "/v1/child")
        XCTAssertEqual(put.value(forHTTPHeaderField: "Idempotency-Key"), "child-profile-1")
        let body = try XCTUnwrap(put.httpBody).jsonObject()
        XCTAssertEqual(body["nickname"] as? String, "Maya")

        // A later child-view refresh keeps the authoritative nickname.
        _ = try await repository.refresh(for: .child)
        XCTAssertEqual(repository.childSnapshot().configuredChildNickname, "Maya")
    }

    func testUpdateChildProfileRejectsBlankNicknameWithoutCallingNetwork() async {
        let transport = StubHTTPTransport(responses: [])
        let repository = APIWalletRepository(
            baseURL: URL(string: "https://api.example.test")!,
            sessionStore: InMemorySessionStore(session: validSession),
            transport: transport,
            cache: TestSnapshotCache(),
            configuredKidStore: InMemoryConfiguredKidStore()
        )

        do {
            _ = try await repository.updateChildProfile(ChildProfileUpdate(nickname: "   "))
            XCTFail("Blank nicknames must fail validation before the network call")
        } catch let error as WalletAPIError {
            XCTAssertEqual(error, .invalidResponse("Enter a child nickname."))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testFamilySetupOmitsLessonsEraFields() async throws {
        let transport = StubHTTPTransport(responses: [
            StubHTTPTransport.Response(statusCode: 201, body: snapshotBody(balance: 0, nickname: "Maya"))
        ])
        let repository = APIWalletRepository(
            baseURL: URL(string: "https://api.example.test")!,
            sessionStore: InMemorySessionStore(session: validSession),
            transport: transport,
            cache: TestSnapshotCache(),
            configuredKidStore: InMemoryConfiguredKidStore()
        )

        _ = try await repository.setup(ParentSetup(familyName: "Chen", nickname: "Maya", idempotencyKey: "setup-1"))

        let post = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(post.url?.path, "/v1/family/setup")
        let body = try XCTUnwrap(post.httpBody).jsonObject()
        XCTAssertEqual(body["familyName"] as? String, "Chen")
        XCTAssertEqual(body["nickname"] as? String, "Maya")
        XCTAssertNil(body["lessonAgeBand"])
    }

    func testAppleSessionRequestUsesIdentityTokenAndNonceAndStoresOpaqueSession() async throws {
        let transport = StubHTTPTransport(responses: [
            StubHTTPTransport.Response(
                statusCode: 201,
                body: Data(#"{"token":"opaque-session","expiresAt":"2099-01-01T00:00:00Z","parent":{"provider":"apple","subject":"apple-subject","email":null}}"#.utf8)
            )
        ])
        let sessions = InMemorySessionStore()
        let repository = APIWalletRepository(
            baseURL: URL(string: "https://api.example.test")!,
            sessionStore: sessions,
            transport: transport,
            cache: TestSnapshotCache(),
            configuredKidStore: InMemoryConfiguredKidStore()
        )

        let session = try await repository.authenticateApple(identityToken: "native.identity.token", nonce: "signed-nonce")

        XCTAssertEqual(session.token, "opaque-session")
        XCTAssertEqual(sessions.session?.token, "opaque-session")
        XCTAssertEqual(transport.requests.count, 1)
        guard let request = transport.requests.first else { return XCTFail("The authentication request was not sent") }
        XCTAssertEqual(request.url?.absoluteString, "https://api.example.test/v1/auth/apple")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        guard let bodyData = request.httpBody else { return XCTFail("The authentication request had no body") }
        let body = try bodyData.jsonObject()
        XCTAssertEqual(body["identityToken"] as? String, "native.identity.token")
        XCTAssertEqual(body["nonce"] as? String, "signed-nonce")
    }

    func testDepositUsesIdempotencyKeyAndOnlyAcceptedResponseChangesBalance() async throws {
        let entryID = "11111111-1111-1111-1111-111111111111"
        let transport = StubHTTPTransport(responses: [
            StubHTTPTransport.Response(statusCode: 200, body: snapshotBody(balance: 0)),
            StubHTTPTransport.Response(
                statusCode: 201,
                body: Data(#"{"entry":{"id":"11111111-1111-1111-1111-111111111111","type":"deposit","direction":"credit","amountCents":150,"balanceBeforeCents":0,"balanceAfterCents":150,"reason":"first","loanId":null,"recordedBy":"parent","recordedAt":"2099-01-01T00:00:00Z"},"wallet":{"id":"wallet","currency":"USD","balanceCents":150,"virtualNotice":"Virtual practice only. These dollars are pretend, cannot be redeemed, and never move real money."}}"#.utf8)
            )
        ])
        let repository = APIWalletRepository(
            baseURL: URL(string: "https://api.example.test")!,
            sessionStore: InMemorySessionStore(session: validSession),
            transport: transport,
            cache: TestSnapshotCache(),
            configuredKidStore: InMemoryConfiguredKidStore()
        )

        _ = try await repository.refresh(for: .parent)
        let result = try await repository.submit(WalletCommand(kind: .deposit, amountCents: 150, reason: "first", idempotencyKey: "deposit-key"))

        guard case .accepted(let event) = result else { return XCTFail("The accepted response must be recorded") }
        XCTAssertEqual(event.remoteID, entryID)
        XCTAssertEqual(repository.snapshot().acceptedBalanceCents, 150)
        XCTAssertEqual(repository.snapshot().activities.first?.amountCents, 150)
        let post = try XCTUnwrap(transport.requests.last)
        XCTAssertEqual(post.httpMethod, "POST")
        XCTAssertEqual(post.value(forHTTPHeaderField: "Idempotency-Key"), "deposit-key")
        XCTAssertEqual(post.url?.path, "/v1/wallet/deposits")
    }

    func testNetworkFailureReturnsWaitingToSyncAndDoesNotChangeAcceptedBalance() async throws {
        let transport = StubHTTPTransport(error: URLError(.notConnectedToInternet))
        let repository = APIWalletRepository(
            baseURL: URL(string: "https://api.example.test")!,
            sessionStore: InMemorySessionStore(session: validSession),
            transport: transport,
            cache: TestSnapshotCache(),
            configuredKidStore: InMemoryConfiguredKidStore()
        )
        _ = try? await repository.refresh(for: .parent)

        let result = try await repository.submit(WalletCommand(kind: .withdrawal, amountCents: 50, idempotencyKey: "offline-key"))

        guard case .pending(let event, _) = result else { return XCTFail("A network failure must remain pending") }
        XCTAssertEqual(event.syncState, .pending)
        XCTAssertEqual(repository.snapshot().acceptedBalanceCents, 0)
        XCTAssertEqual(repository.snapshot().pendingEvents.count, 1)
    }

    func testExpiredSessionIsClearedOnUnauthorizedResponse() async throws {
        let transport = StubHTTPTransport(responses: [StubHTTPTransport.Response(statusCode: 401, body: Data(#"{"error":{"code":"UNAUTHENTICATED","message":"expired"}}"#.utf8))])
        let sessions = InMemorySessionStore(session: validSession)
        let repository = APIWalletRepository(
            baseURL: URL(string: "https://api.example.test")!,
            sessionStore: sessions,
            transport: transport,
            cache: TestSnapshotCache(),
            configuredKidStore: InMemoryConfiguredKidStore()
        )

        do {
            _ = try await repository.refresh(for: .parent)
            XCTFail("Unauthorized responses must fail")
        } catch let error as WalletAPIError {
            XCTAssertEqual(error.operationError, .unauthorized)
            XCTAssertEqual(error.transportDiagnostic?.httpStatus, 401)
            XCTAssertEqual(error.transportDiagnostic?.route, "/v1/wallet")
        }
        XCTAssertNil(sessions.session)
        XCTAssertFalse(repository.isAuthenticated)
    }

    func testChildRefreshRequiresServerReadOnlyResponse() async throws {
        let body = Data("""
        {
          "wallet": {"id":"wallet","currency":"USD","balanceCents":0,"virtualNotice":"Virtual practice only. These dollars are pretend, cannot be redeemed, and never move real money."},
          "allowanceRule": null,
          "loan": null,
          "recentActivity": [],
          "readOnly": false
        }
        """.utf8)
        let repository = APIWalletRepository(
            baseURL: URL(string: "https://api.example.test")!,
            sessionStore: InMemorySessionStore(session: validSession),
            transport: StubHTTPTransport(responses: [StubHTTPTransport.Response(statusCode: 200, body: body)]),
            cache: TestSnapshotCache(),
            configuredKidStore: InMemoryConfiguredKidStore()
        )

        do {
            _ = try await repository.refresh(for: .child)
            XCTFail("The client must reject a child response without a server read-only marker")
        } catch let error as WalletAPIError {
            guard case .invalidResponse = error else { return XCTFail("Expected an invalid response error") }
        }
    }

    func testInvalidVirtualNoticeCannotBecomeAnAcceptedSnapshot() async throws {
        let invalid = Data(#"{"wallet":{"id":"wallet","currency":"USD","balanceCents":999,"virtualNotice":"US dollars"},"allowanceRule":null,"loan":null,"recentActivity":[]}"#.utf8)
        let repository = APIWalletRepository(
            baseURL: URL(string: "https://api.example.test")!,
            sessionStore: InMemorySessionStore(session: validSession),
            transport: StubHTTPTransport(responses: [StubHTTPTransport.Response(statusCode: 200, body: invalid)]),
            cache: TestSnapshotCache(),
            configuredKidStore: InMemoryConfiguredKidStore()
        )

        do {
            _ = try await repository.refresh(for: .parent)
            XCTFail("An invalid authoritative response must fail")
        } catch let error as WalletAPIError {
            guard case .invalidResponse = error else { return XCTFail("Expected an invalid response error") }
        }
        XCTAssertEqual(repository.snapshot().acceptedBalanceCents, 0)
    }

    func testOnlyValidatedChildViewPopulatesKidCache() async throws {
        let cache = TestSnapshotCache()
        let configuredKid = InMemoryConfiguredKidStore()
        let repository = APIWalletRepository(
            baseURL: URL(string: "https://api.example.test")!,
            sessionStore: InMemorySessionStore(session: validSession),
            transport: StubHTTPTransport(responses: [
                StubHTTPTransport.Response(statusCode: 200, body: snapshotBody(balance: 100, readOnly: true)),
                StubHTTPTransport.Response(statusCode: 200, body: snapshotBody(balance: 900))
            ]),
            cache: cache,
            configuredKidStore: configuredKid
        )

        _ = try await repository.refresh(for: .child)
        _ = try await repository.refresh(for: .parent)

        XCTAssertEqual(repository.childSnapshot().acceptedBalanceCents, 100)
        XCTAssertEqual(cache.value?.acceptedBalanceCents, 100)
        XCTAssertEqual(repository.snapshot().acceptedBalanceCents, 900)
        XCTAssertTrue(configuredKid.isConfigured)
    }

    func testExplicitSessionClearRemovesKidCacheAndConfiguredMarker() throws {
        let cache = TestSnapshotCache()
        cache.value = .fixture()
        let configuredKid = InMemoryConfiguredKidStore(isConfigured: true)
        let repository = APIWalletRepository(
            baseURL: URL(string: "https://api.example.test")!,
            sessionStore: InMemorySessionStore(session: validSession),
            transport: StubHTTPTransport(),
            cache: cache,
            configuredKidStore: configuredKid
        )

        try repository.clearSession()

        XCTAssertNil(cache.value)
        XCTAssertFalse(configuredKid.isConfigured)
        XCTAssertEqual(repository.childSnapshot().acceptedBalanceCents, 0)
    }

    func testInflightChildRefreshCannotRestoreClearedKidShell() async throws {
        let cache = TestSnapshotCache()
        cache.value = .fixture()
        let configuredKid = InMemoryConfiguredKidStore(isConfigured: true)
        let transport = SuspendingHTTPTransport()
        let repository = APIWalletRepository(
            baseURL: URL(string: "https://api.example.test")!,
            sessionStore: InMemorySessionStore(session: validSession),
            transport: transport,
            cache: cache,
            configuredKidStore: configuredKid
        )

        let refresh = Task { try await repository.refresh(for: .child) }
        await waitForRequestCount(1, transport: transport)

        try repository.clearSession()
        transport.complete(
            statusCode: 200,
            body: snapshotBody(balance: 900, readOnly: true)
        )
        _ = try await refresh.value

        XCTAssertNil(cache.value)
        XCTAssertFalse(configuredKid.isConfigured)
        XCTAssertEqual(repository.childSnapshot().acceptedBalanceCents, 0)
        let relaunched = WalletStore(
            repository: repository,
            pinStore: InMemoryParentPINStore(pin: "1234"),
            identityStore: InMemoryParentIdentityStore(appleUserID: "owner-1")
        )
        XCTAssertFalse(relaunched.isSignedIn)
    }

    func testInflightCommandSuccessCannotRestoreStateAfterSessionClear() async throws {
        let pending = TestPendingCommandStore()
        let transport = SuspendingHTTPTransport()
        let repository = makeSuspendingRepository(transport: transport, pending: pending)
        let command = WalletCommand(kind: .deposit, amountCents: 150, idempotencyKey: "stale-success")

        let submission = Task { try await repository.submit(command) }
        await waitForRequestCount(1, transport: transport)

        try repository.clearSession()
        transport.complete(statusCode: 201, body: commandBody(balance: 150))

        await assertCancelled(submission)
        XCTAssertEqual(repository.snapshot().acceptedBalanceCents, 0)
        XCTAssertTrue(repository.snapshot().activities.isEmpty)
        XCTAssertTrue(pending.commands.isEmpty)
    }

    func testInflightCommandNetworkFailureCannotRequeueAfterSessionClear() async throws {
        let pending = TestPendingCommandStore()
        let transport = SuspendingHTTPTransport()
        let repository = makeSuspendingRepository(transport: transport, pending: pending)
        let command = WalletCommand(kind: .deposit, amountCents: 150, idempotencyKey: "stale-network")

        let submission = Task { try await repository.submit(command) }
        await waitForRequestCount(1, transport: transport)

        try repository.clearSession()
        transport.fail(URLError(.notConnectedToInternet))

        await assertCancelled(submission)
        XCTAssertTrue(repository.snapshot().pendingEvents.isEmpty)
        XCTAssertTrue(pending.commands.isEmpty)
    }

    func testInflightCommandRejectionCannotRestoreStateAfterSessionClear() async throws {
        let pending = TestPendingCommandStore()
        let transport = SuspendingHTTPTransport()
        let repository = makeSuspendingRepository(transport: transport, pending: pending)
        let command = WalletCommand(kind: .deposit, amountCents: 150, idempotencyKey: "stale-rejection")

        let submission = Task { try await repository.submit(command) }
        await waitForRequestCount(1, transport: transport)

        try repository.clearSession()
        transport.complete(
            statusCode: 422,
            body: Data(#"{"error":{"code":"INVALID_AMOUNT","message":"Not recorded"}}"#.utf8)
        )

        await assertCancelled(submission)
        XCTAssertTrue(repository.snapshot().pendingEvents.isEmpty)
        XCTAssertTrue(pending.commands.isEmpty)
    }

    func testPendingFlushCrossingSessionClearCannotReplayUnderNewSession() async throws {
        let command = WalletCommand(kind: .deposit, amountCents: 150, idempotencyKey: "old-session-command")
        let pending = TestPendingCommandStore(commands: [command])
        let transport = SuspendingHTTPTransport()
        let sessions = InMemorySessionStore(session: validSession)
        let repository = APIWalletRepository(
            baseURL: URL(string: "https://api.example.test")!,
            sessionStore: sessions,
            transport: transport,
            cache: TestSnapshotCache(),
            configuredKidStore: InMemoryConfiguredKidStore(),
            pendingStore: pending
        )

        let firstRefresh = Task { try await repository.refresh(for: .parent) }
        await waitForRequestCount(1, transport: transport)
        XCTAssertEqual(transport.requests.first?.httpMethod, "POST")

        try repository.clearSession()
        transport.complete(statusCode: 201, body: commandBody(balance: 150))
        await assertCancelled(firstRefresh)
        XCTAssertTrue(pending.commands.isEmpty)

        try sessions.save(AuthSession(token: "different-session", expiresAt: Date(timeIntervalSince1970: 4_000_000_000)))
        let secondRefresh = Task { try await repository.refresh(for: .parent) }
        await waitForRequestCount(2, transport: transport)
        XCTAssertEqual(transport.requests.last?.httpMethod, "GET")
        XCTAssertEqual(transport.requests.last?.url?.path, "/v1/wallet")

        transport.complete(statusCode: 200, body: snapshotBody(balance: 25))
        _ = try await secondRefresh.value

        XCTAssertEqual(transport.requests.count, 2)
        XCTAssertTrue(pending.commands.isEmpty)
        XCTAssertEqual(repository.snapshot().acceptedBalanceCents, 25)
    }

    private var validSession: AuthSession {
        AuthSession(token: "opaque-session", expiresAt: Date(timeIntervalSince1970: 4_000_000_000))
    }

    private func makeSuspendingRepository(
        transport: SuspendingHTTPTransport,
        pending: TestPendingCommandStore
    ) -> APIWalletRepository {
        APIWalletRepository(
            baseURL: URL(string: "https://api.example.test")!,
            sessionStore: InMemorySessionStore(session: validSession),
            transport: transport,
            cache: TestSnapshotCache(),
            configuredKidStore: InMemoryConfiguredKidStore(),
            pendingStore: pending
        )
    }

    private func waitForRequestCount(
        _ count: Int,
        transport: SuspendingHTTPTransport,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        // Bound the spin so a stuck suspension fails the test instead of burning the CI job timeout.
        let deadline = ContinuousClock.now + .seconds(5)
        while transport.requests.count < count || !transport.isAwaitingCompletion {
            if ContinuousClock.now >= deadline {
                XCTFail(
                    "Timed out waiting for \(count) suspended request(s); saw \(transport.requests.count) request(s), awaiting=\(transport.isAwaitingCompletion)",
                    file: file,
                    line: line
                )
                return
            }
            await Task.yield()
        }
    }

    private func assertCancelled<T>(_ task: Task<T, Error>, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await task.value
            XCTFail("The stale operation must be cancelled", file: file, line: line)
        } catch let error as WalletAPIError {
            XCTAssertEqual(error, .cancelled, file: file, line: line)
        } catch {
            XCTFail("Unexpected stale-operation error: \(error)", file: file, line: line)
        }
    }

    private func commandBody(balance: Int) -> Data {
        Data("""
        {
          "entry": {
            "id": "11111111-1111-1111-1111-111111111111",
            "type": "deposit",
            "direction": "credit",
            "amountCents": 150,
            "balanceBeforeCents": 0,
            "balanceAfterCents": \(balance),
            "reason": null,
            "loanId": null,
            "recordedBy": "parent",
            "recordedAt": "2099-01-01T00:00:00Z"
          },
          "wallet": {
            "id": "wallet",
            "currency": "USD",
            "balanceCents": \(balance),
            "virtualNotice": "Virtual practice only. These dollars are pretend, cannot be redeemed, and never move real money."
          }
        }
        """.utf8)
    }

    private func snapshotBody(
        balance: Int,
        nickname: String = "Eddie",
        readOnly: Bool? = nil,
        extraChildFields: String? = nil
    ) -> Data {
        let readOnlyField = readOnly.map { ",\n          \"readOnly\": \($0)" } ?? ""
        let childExtras = extraChildFields.map { ",\($0)" } ?? ""
        return Data("""
        {
          "family": {"id":"family","name":"Eddie's family"},
          "child": {"id":"child","nickname":"\(nickname)","avatarUrl":null\(childExtras)},
          "wallet": {"id":"wallet","currency":"USD","balanceCents":\(balance),"virtualNotice":"Virtual practice only. These dollars are pretend, cannot be redeemed, and never move real money."},
          "allowanceRule": null,
          "loan": null,
          "recentActivity": []\(readOnlyField)
        }
        """.utf8)
    }
}

private final class StubHTTPTransport: HTTPTransport {
    struct Response {
        let statusCode: Int
        let body: Data
    }

    var responses: [Response]
    var requests: [URLRequest] = []
    let error: Error?

    init(responses: [Response] = [], error: Error? = nil) {
        self.responses = responses
        self.error = error
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        if let error { throw error }
        guard !responses.isEmpty else { throw URLError(.badServerResponse) }
        let response = responses.removeFirst()
        let http = HTTPURLResponse(url: request.url!, statusCode: response.statusCode, httpVersion: nil, headerFields: nil)!
        return (response.body, http)
    }
}

/// `HTTPTransport.data(for:)` is nonisolated, so the parked request runs on a
/// cooperative thread while the test body polls and completes it from the main
/// actor. Unsynchronised stored properties corrupt their own buffers and kill
/// the test host with SIGSEGV instead of failing an assertion, so all state
/// lives in one lock-guarded value.
private final class SuspendingHTTPTransport: HTTPTransport {
    private struct State {
        var requests: [URLRequest] = []
        var continuation: CheckedContinuation<(Data, URLResponse), Error>?
        /// Result delivered if complete/fail races ahead of the suspension callback.
        var pendingResult: Result<(Data, URLResponse), Error>?
    }

    private let lock = NSLock()
    private var state = State()

    private func withState<T>(_ body: (inout State) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&state)
    }

    var requests: [URLRequest] { withState { $0.requests } }

    /// True while a request is parked in `withCheckedThrowingContinuation`.
    var isAwaitingCompletion: Bool { withState { $0.continuation != nil } }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        withState { $0.requests.append(request) }
        return try await withCheckedThrowingContinuation { continuation in
            let pending: Result<(Data, URLResponse), Error>? = withState { state in
                guard let pendingResult = state.pendingResult else {
                    state.continuation = continuation
                    return nil
                }
                state.pendingResult = nil
                return pendingResult
            }
            if let pending { continuation.resume(with: pending) }
        }
    }

    func complete(statusCode: Int, body: Data) {
        guard let request = requests.last else { return }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
        deliver(.success((body, response)))
    }

    func fail(_ error: Error) {
        deliver(.failure(error))
    }

    private func deliver(_ result: Result<(Data, URLResponse), Error>) {
        let parked: CheckedContinuation<(Data, URLResponse), Error>? = withState { state in
            guard let continuation = state.continuation else {
                // complete/fail can observe `requests` before the suspension callback assigns `continuation`.
                state.pendingResult = result
                return nil
            }
            state.continuation = nil
            return continuation
        }
        parked?.resume(with: result)
    }
}

@MainActor
private final class TestSnapshotCache: WalletSnapshotCache {
    var value: WalletSnapshot?
    func load() -> WalletSnapshot? { value }
    func save(_ snapshot: WalletSnapshot) { value = snapshot }
    func clear() { value = nil }
}

@MainActor
private final class TestPendingCommandStore: PendingCommandStore {
    private(set) var commands: [WalletCommand]

    init(commands: [WalletCommand] = []) {
        self.commands = commands
    }

    func load() -> [WalletCommand] { commands }
    func save(_ commands: [WalletCommand]) { self.commands = commands }
    func clear() { commands = [] }
}

private extension Data {
    func jsonObject() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: self) as? [String: Any])
    }
}
