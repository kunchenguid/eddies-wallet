import Foundation
import XCTest
@testable import EddysWallet

/// Field-level Cloud contract coverage using the exact bodies the private
/// backend returns, so a rename on either side fails here instead of in Sandbox.
/// Every fixture is synthetic: no real parent, child, purchase, or account.
@MainActor
final class CloudContractTests: XCTestCase {
    private let session = AuthSession(token: "synthetic-session", expiresAt: .distantFuture)

    // MARK: - Capability

    func testCapabilityDecodesTheBackendProductsFieldAndGatesOnExactProducts() async throws {
        let ready = try await capability(CloudContractFixtures.capabilitiesReady)
        XCTAssertTrue(ready.cloudActivationAvailable)
        XCTAssertEqual(ready.cloudServiceAvailable, true)
        XCTAssertEqual(Set(ready.productIDs), CloudProductID.all, "the server publishes product ids under `products`")
        XCTAssertTrue(ready.hasExactProducts)
        XCTAssertTrue(ready.canOfferCloud)

        let dark = try await capability(CloudContractFixtures.capabilitiesDark)
        XCTAssertFalse(dark.cloudActivationAvailable)
        XCTAssertTrue(dark.hasExactProducts, "a dark backend still lists the two products")
        XCTAssertFalse(dark.canOfferCloud, "activation must be available before anything is offered")

        let partial = try await capability(CloudContractFixtures.capabilitiesPartialProducts)
        XCTAssertFalse(partial.canOfferCloud, "a missing or extra product must fail closed")

        let futureFields = try await capability(CloudContractFixtures.capabilitiesWithUnknownFields)
        XCTAssertTrue(futureFields.canOfferCloud, "unknown future fields are ignored")
    }

    func testCapabilityRequestIsUnauthenticatedAndUsesThePublishedPath() async throws {
        let transport = StubTransport(responses: [.init(statusCode: 200, body: CloudContractFixtures.capabilitiesReady)])
        let client = CloudAPIClient(baseURL: Self.baseURL, sessionStore: InMemorySessionStore(), transport: transport)
        _ = try await client.capabilities()
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.url?.path, "/v1/capabilities")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"), "capability is readable without a session")
    }

    // MARK: - Context

    func testContextDecodesWithoutEntitlementOrHousehold() async throws {
        let context = try await context(CloudContractFixtures.contextNoEntitlement)
        XCTAssertEqual(context.storeAccountToken?.uuidString.lowercased(), "5d15c540-02fe-475c-9c07-70260a3a0db5")
        XCTAssertNil(context.entitlement)
        XCTAssertEqual(context.entitlementState, .none, "an absent entitlement is never a grant")
        XCTAssertNil(context.household)
        XCTAssertEqual(context.capability?.newActivationsEnabled, true)
    }

    func testContextDecodesNestedHouseholdWithServerCasingAndRetainsRevision() async throws {
        let context = try await context(CloudContractFixtures.contextActive)
        XCTAssertEqual(context.lineageID?.uuidString.lowercased(), "c715311d-e4c5-4878-99b7-f42adb8ff90e")
        XCTAssertEqual(context.authority, .cloud)
        XCTAssertEqual(context.revision, 4, "the client must retain the revision it will send as If-Match")
        XCTAssertEqual(context.household?.isCloudAuthoritative, true)
        let entitlementState = context.entitlementState
        guard case .active(let accessUntil, let autoRenew) = entitlementState else {
            return XCTFail("expected an active entitlement, got \(context.entitlementState)")
        }
        XCTAssertEqual(accessUntil.timeIntervalSince1970, 1_787_951_027.17, accuracy: 1, "2026-08-28T21:03:47.170Z")
        XCTAssertTrue(autoRenew, "an absent autoRenewEnabled defaults to renewing")
    }

    func testMalformedOrNonCloudAuthorityNeverBecomesACloudGrant() async throws {
        for fixture in [CloudContractFixtures.contextUnknownAuthority, CloudContractFixtures.contextLegacyAuthority] {
            let context = try await context(fixture)
            XCTAssertNotEqual(context.household?.authority, .cloud)
            XCTAssertEqual(context.household?.isCloudAuthoritative, false, "only an explicit cloud authority with a lineage counts")
        }
        let missingLineage = try await context(CloudContractFixtures.contextCloudWithoutLineage)
        XCTAssertEqual(missingLineage.household?.authority, .cloud)
        XCTAssertEqual(missingLineage.household?.isCloudAuthoritative, false, "a Cloud household without a lineage is unusable")
    }

    func testBillingGraceAndTerminalStatesMapToTheDocumentedClientStates() async throws {
        let graceState = try await context(CloudContractFixtures.contextBillingGrace).entitlementState
        guard case .billingGrace(let until) = graceState else { return XCTFail("expected billing grace") }
        XCTAssertEqual(until.timeIntervalSince1970, 1_786_743_136.643, accuracy: 1, "grace access runs to the verified grace date")
        let expired = try await context(CloudContractFixtures.contextExpired).entitlementState
        let revoked = try await context(CloudContractFixtures.contextRevoked).entitlementState
        let pending = try await context(CloudContractFixtures.contextPending).entitlementState
        XCTAssertEqual(expired, .expired)
        XCTAssertEqual(revoked, .revoked)
        XCTAssertEqual(pending, .verificationPending)
        XCTAssertFalse(expired.grantsCloud)
        XCTAssertTrue(graceState.grantsCloud)
    }

    // MARK: - Transaction delivery

    func testVerifiedTransactionReturnsTheFullContext() async throws {
        let transport = StubTransport(responses: [.init(statusCode: 200, body: CloudContractFixtures.verifiedTransaction)])
        let client = CloudAPIClient(baseURL: Self.baseURL, sessionStore: InMemorySessionStore(session: session), transport: transport)
        let context = try await client.deliver(transactionJWS: "synthetic.jws.value")
        XCTAssertTrue(context.entitlementState.grantsCloud)
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.url?.path, "/v1/cloud/transactions")
        XCTAssertNotNil(request.value(forHTTPHeaderField: "Idempotency-Key"))
        let body = try XCTUnwrap(request.httpBody).jsonObject()
        XCTAssertEqual(body["signedTransaction"] as? String, "synthetic.jws.value")
        XCTAssertEqual(Set(body.keys), ["signedTransaction"], "only Apple's signed payload is sent")
    }

    /// The verified body also carries `status`, and the household it reports may
    /// still be the pre-activation legacy wallet. Neither may be read as a Cloud
    /// household, and neither may break decoding.
    func testVerifiedTransactionIgnoresExtraFieldsAndDoesNotInventACloudHousehold() async throws {
        let transport = StubTransport(responses: [.init(statusCode: 200, body: CloudContractFixtures.verifiedTransactionBeforeActivation)])
        let client = CloudAPIClient(baseURL: Self.baseURL, sessionStore: InMemorySessionStore(session: session), transport: transport)
        let context = try await client.deliver(transactionJWS: "synthetic.jws.value")
        XCTAssertTrue(context.entitlementState.grantsCloud, "the purchase is verified and access is projected")
        XCTAssertEqual(context.authority, .legacyService)
        XCTAssertEqual(context.revision, 0, "the reported revision is the one the next Cloud write must send")
        XCTAssertEqual(context.household?.isCloudAuthoritative, false, "a verified purchase alone is not a Cloud household")
    }

    func testPendingRejectedAndUnreadableDeliveryNeverGrantCloud() async throws {
        let cases: [(Int, Data, String)] = [
            (202, Data(), "202 stays server-pending"),
            (403, CloudContractFixtures.accountMismatchError, "an explicit rejection stays rejected"),
            (422, CloudContractFixtures.unverifiedError, "an unverified transaction stays rejected"),
            (200, Data("{\"status\":\"verified\"}".utf8), "a body without a context is not a grant"),
        ]
        for (status, body, message) in cases {
            let transport = StubTransport(responses: [.init(statusCode: status, body: body)])
            let client = CloudAPIClient(baseURL: Self.baseURL, sessionStore: InMemorySessionStore(session: session), transport: transport)
            do {
                let context = try await client.deliver(transactionJWS: "synthetic.jws.value")
                XCTAssertFalse(context.entitlementState.grantsCloud, message)
            } catch {
                // Throwing is also a non-grant, which is the point of the case.
                XCTAssertTrue(error is WalletAPIError, message)
            }
        }
    }

    // MARK: - Revision discipline

    func testCloudCommandSendsRetainedRevisionAsIfMatchAndReportsTheNewRevision() async throws {
        let transport = StubTransport(responses: [.init(statusCode: 201, body: CloudContractFixtures.depositAccepted)])
        let client = CloudAPIClient(baseURL: Self.baseURL, sessionStore: InMemorySessionStore(session: session), transport: transport)
        let acceptance = try await client.command(
            path: "/v1/wallet/deposits",
            body: ["amountCents": 250],
            expectedRevision: 4,
            idempotencyKey: "synthetic-deposit-key"
        )
        XCTAssertEqual(acceptance.revision, 5)
        XCTAssertEqual(acceptance.statusCode, 201)
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.value(forHTTPHeaderField: "If-Match"), "\"rev-4\"")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Idempotency-Key"), "synthetic-deposit-key")
    }

    func testRevisionConflictAndRevisionRequiredAreTypedForReReview() async throws {
        let conflict = StubTransport(responses: [.init(statusCode: 409, body: CloudContractFixtures.revisionConflictError)])
        let conflictClient = CloudAPIClient(baseURL: Self.baseURL, sessionStore: InMemorySessionStore(session: session), transport: conflict)
        do {
            _ = try await conflictClient.command(path: "/v1/wallet/deposits", body: ["amountCents": 1], expectedRevision: 1, idempotencyKey: "k")
            XCTFail("a stale revision must conflict")
        } catch let WalletAPIError.revisionConflict(currentRevision) {
            XCTAssertEqual(currentRevision, 7, "the client learns the server's current revision")
        }

        let required = StubTransport(responses: [.init(statusCode: 428, body: CloudContractFixtures.revisionRequiredError)])
        let requiredClient = CloudAPIClient(baseURL: Self.baseURL, sessionStore: InMemorySessionStore(session: session), transport: required)
        do {
            _ = try await requiredClient.command(path: "/v1/wallet/deposits", body: ["amountCents": 1], expectedRevision: 0, idempotencyKey: "k")
            XCTFail("a Cloud write without the current revision must be refused")
        } catch WalletAPIError.revisionRequired {
            // Expected.
        }
    }

    func testExpiredEntitlementRejectionIsTypedSoTheAppCanOfferLocalContinuation() async throws {
        let transport = StubTransport(responses: [.init(statusCode: 403, body: CloudContractFixtures.entitlementRequiredError)])
        let client = CloudAPIClient(baseURL: Self.baseURL, sessionStore: InMemorySessionStore(session: session), transport: transport)
        do {
            _ = try await client.command(path: "/v1/wallet/deposits", body: ["amountCents": 1], expectedRevision: 4, idempotencyKey: "k")
            XCTFail("an expired entitlement must refuse Cloud writes")
        } catch WalletAPIError.cloudEntitlementRequired {
            // Expected: the parent is offered local continuation, nothing is deleted.
        }
    }

    // MARK: - Replica

    func testBootstrapDecodesAndMapsIntoTheOneChildSnapshot() async throws {
        let transport = StubTransport(responses: [.init(statusCode: 200, body: CloudContractFixtures.bootstrap)])
        let client = CloudAPIClient(baseURL: Self.baseURL, sessionStore: InMemorySessionStore(session: session), transport: transport)
        let replica = try await client.bootstrap()
        XCTAssertEqual(replica.household.revision, 4)
        XCTAssertEqual(replica.entries.count, 4)
        XCTAssertNil(replica.nextCursor)

        let snapshot = CloudReplicaMapper.snapshot(from: replica, mergingInto: [], fallbackNickname: nil)
        XCTAssertEqual(snapshot.acceptedBalanceCents, 500)
        XCTAssertEqual(snapshot.childNickname, "Test Kid")
        XCTAssertEqual(snapshot.activities.count, 4)
        XCTAssertEqual(snapshot.activities.first?.type, .withdrawal, "activities render newest first")
        XCTAssertTrue(snapshot.pendingEvents.isEmpty, "a Cloud replica contains only accepted events")
        XCTAssertFalse(snapshot.isStale)
        XCTAssertEqual(snapshot.loan?.remainingCents, 200)
        XCTAssertEqual(snapshot.loan?.originalCents, 300)
        XCTAssertEqual(snapshot.allowance?.amountCents, 500)
    }

    func testChangesRequestUsesTheRetainedRevisionAndMergesOlderHistory() async throws {
        let transport = StubTransport(responses: [.init(statusCode: 200, body: CloudContractFixtures.changesAfterRevision)])
        let client = CloudAPIClient(baseURL: Self.baseURL, sessionStore: InMemorySessionStore(session: session), transport: transport)
        let replica = try await client.changes(afterRevision: 3)
        XCTAssertEqual(try XCTUnwrap(transport.requests.first).url?.query, "afterRevision=3")

        let older = WalletEvent(
            id: UUID(uuidString: "22222222-2222-4222-8222-222222222222")!,
            remoteID: "22222222-2222-4222-8222-222222222222",
            type: .deposit,
            amountCents: 500,
            balanceBeforeCents: 0,
            balanceAfterCents: 500,
            date: Date(timeIntervalSince1970: 1_700_000_000),
            explanation: "older accepted event"
        )
        let merged = CloudReplicaMapper.snapshot(from: replica, mergingInto: [older], fallbackNickname: "Test Kid")
        XCTAssertEqual(merged.activities.count, 2, "incremental changes never drop accepted history")
        XCTAssertEqual(merged.acceptedBalanceCents, 750)
    }

    // MARK: - Import manifest

    func testImportManifestMatchesTheServerAggregateDigestByteForByte() {
        let manifest = CloudImportManifest(
            lineageID: UUID(uuidString: "55555555-5555-4555-8555-555555555555")!,
            operationID: UUID(uuidString: "66666666-6666-4666-8666-666666666666")!,
            familyName: "Test Kid\u{2019}s family",
            nickname: "Test Kid",
            avatarURL: nil,
            loans: [
                .init(
                    id: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!,
                    principalCents: 300,
                    outstandingCents: 200,
                    purpose: "scooter \"fast\"",
                    dueDate: "2026-09-01",
                    status: "open",
                    createdAt: Date(timeIntervalSince1970: 1_784_973_600),
                    paidAt: nil
                )
            ],
            entries: [
                .init(operationID: UUID(uuidString: "22222222-2222-4222-8222-222222222222")!, type: "deposit", direction: "credit", amountCents: 500, balanceBeforeCents: 0, balanceAfterCents: 500, reason: "chores\nweek 1", loanID: nil, recordedAt: Date(timeIntervalSince1970: 1_784_887_200)),
                .init(operationID: UUID(uuidString: "33333333-3333-4333-8333-333333333333")!, type: "loan", direction: "credit", amountCents: 300, balanceBeforeCents: 500, balanceAfterCents: 800, reason: "scooter \"fast\"", loanID: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!, recordedAt: Date(timeIntervalSince1970: 1_784_973_600)),
                .init(operationID: UUID(uuidString: "44444444-4444-4444-8444-444444444444")!, type: "repayment", direction: "debit", amountCents: 100, balanceBeforeCents: 800, balanceAfterCents: 700, reason: nil, loanID: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!, recordedAt: Date(timeIntervalSince1970: 1_785_060_000)),
            ]
        )
        // Expected values come from the server's own aggregate hashing
        // (JSON.stringify of the accepted aggregate, then sha256).
        XCTAssertEqual(manifest.canonicalAggregate.encoded, CloudContractFixtures.expectedAggregateJSON)
        XCTAssertEqual(manifest.aggregateSHA256, CloudContractFixtures.expectedAggregateDigest)

        let body = manifest.requestBody.jsonObject()
        XCTAssertEqual(body["aggregateSha256"] as? String, CloudContractFixtures.expectedAggregateDigest)
        XCTAssertEqual(body["operationId"] as? String, "66666666-6666-4666-8666-666666666666")
        XCTAssertEqual((body["entries"] as? [[String: Any]])?.count, 3)
    }

    func testCanonicalJSONEscapingMatchesTheServerEncoder() {
        XCTAssertEqual(CloudCanonicalJSON.quoted("plain"), "\"plain\"")
        XCTAssertEqual(CloudCanonicalJSON.quoted("quote\"back\\slash"), "\"quote\\\"back\\\\slash\"")
        XCTAssertEqual(CloudCanonicalJSON.quoted("tab\tnewline\n"), "\"tab\\tnewline\\n\"")
        XCTAssertEqual(CloudCanonicalJSON.quoted("bell\u{07}"), "\"bell\\u0007\"")
        XCTAssertEqual(CloudCanonicalJSON.quoted("slash/kept"), "\"slash/kept\"", "the server does not escape forward slashes")
        XCTAssertEqual(CloudCanonicalJSON.quoted("emoji 🙂"), "\"emoji 🙂\"", "non-ASCII stays literal UTF-8")
    }

    func testManifestRebuildsEveryHistoricalLoanFromTheAcceptedChain() throws {
        let firstLoanID = UUID()
        let secondLoanID = UUID()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let events: [WalletEvent] = [
            .init(id: UUID(), type: .deposit, amountCents: 1_000, date: base, explanation: ""),
            .init(id: firstLoanID, type: .loan, amountCents: 300, reason: "helmet", date: base.addingTimeInterval(60), explanation: ""),
            .init(id: UUID(), type: .repayment, amountCents: 300, date: base.addingTimeInterval(120), explanation: ""),
            .init(id: secondLoanID, type: .loan, amountCents: 500, reason: "scooter", date: base.addingTimeInterval(180), explanation: ""),
            .init(id: UUID(), type: .repayment, amountCents: 200, date: base.addingTimeInterval(240), explanation: ""),
        ]
        let snapshot = WalletSnapshot(
            acceptedBalanceCents: 1_300,
            activities: events.reversed(),
            loan: Loan(remoteID: "local-loan", originalCents: 500, remainingCents: 300),
            allowance: nil,
            pendingEvents: [],
            lastUpdated: base,
            isStale: false,
            childNickname: "Test Kid"
        )
        let manifest = try CloudImportManifestBuilder.manifest(
            lineageID: UUID(),
            operationID: UUID(),
            familyName: "Test Kid's family",
            nickname: "Test Kid",
            snapshot: snapshot
        )
        XCTAssertEqual(manifest.loans.count, 2, "a paid historical loan is still uploaded")
        XCTAssertEqual(manifest.loans.first?.status, "paid")
        XCTAssertEqual(manifest.loans.first?.outstandingCents, 0)
        XCTAssertNotNil(manifest.loans.first?.paidAt)
        XCTAssertEqual(manifest.loans.last?.status, "open")
        XCTAssertEqual(manifest.loans.last?.outstandingCents, 300)
        XCTAssertEqual(manifest.entries.map(\.balanceAfterCents), [1_000, 1_300, 1_000, 1_500, 1_300])
        XCTAssertEqual(manifest.entries.compactMap(\.loanID).count, 4, "loan and repayment entries carry their loan")
    }

    func testManifestRefusesAHistoryThatDoesNotBalance() {
        let snapshot = WalletSnapshot(
            acceptedBalanceCents: 999,
            activities: [.init(type: .deposit, amountCents: 100, explanation: "")],
            loan: nil,
            allowance: nil,
            pendingEvents: [],
            lastUpdated: .now,
            isStale: false,
            childNickname: "Test Kid"
        )
        XCTAssertThrowsError(
            try CloudImportManifestBuilder.manifest(lineageID: UUID(), operationID: UUID(), familyName: "f", nickname: "Test Kid", snapshot: snapshot),
            "a wallet whose events do not match its balance is never uploaded"
        )
    }

    // MARK: - Shared public contract fixture

    /// `EddysWalletTests/Fixtures/cloud-api-contract/v1.json` is a mirror of the
    /// backend's own field-level contract fixture, which its tests assert every
    /// live response against. Pinning the version and the field names in both
    /// repositories is what makes an unannounced wire change fail CI instead of
    /// silently making a ready backend look dark or a paid purchase look rejected.
    func testShippedClientMatchesTheSharedPublicContractFixture() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "v1", withExtension: "json", subdirectory: "Fixtures/cloud-api-contract"))
        let contract = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(contract["version"] as? Int, 1, "a wire-contract version bump must be reconciled in both repositories")
        let endpoints = try XCTUnwrap(contract["endpoints"] as? [String: Any])

        func endpoint(_ name: String) throws -> [String: Any] {
            try XCTUnwrap(endpoints[name] as? [String: Any], "missing contract endpoint \(name)")
        }
        func fields(_ name: String) throws -> [String: Any] {
            let body = try XCTUnwrap(try endpoint(name)["body"] as? [String: Any])
            return try XCTUnwrap(body["fields"] as? [String: Any])
        }

        // Capability: the product ids live under `products`, which is the key the
        // client decodes into productIDs.
        let capability = try fields("capabilities")
        XCTAssertEqual(Set(capability.keys), ["cloudActivationAvailable", "cloudServiceAvailable", "products"])
        let publishedProducts = try XCTUnwrap((capability["products"] as? [String: Any])?["const"] as? [String])
        XCTAssertEqual(Set(publishedProducts), CloudProductID.all, "the client knows exactly the published products")
        XCTAssertNoThrow(try JSONDecoder.cloud.decode(CloudCapabilities.self, from: CloudContractFixtures.capabilitiesReady))

        // Context: entitlement and household are nullable before a purchase, and
        // the household fields are nested with server casing.
        XCTAssertEqual(try endpoint("cloudContextBeforePurchase")["expectNull"] as? [String], ["entitlement", "household"])
        let context = try fields("cloudContextActive")
        XCTAssertEqual(Set(context.keys), ["storeAccountToken", "entitlement", "household", "capability"])
        let household = try XCTUnwrap((context["household"] as? [String: Any])?["fields"] as? [String: Any])
        XCTAssertEqual(Set(household.keys), ["lineageId", "authority", "revision"])
        let entitlement = try XCTUnwrap((context["entitlement"] as? [String: Any])?["fields"] as? [String: Any])
        XCTAssertTrue(Set(entitlement.keys).isSuperset(of: ["state", "accessUntil", "graceExpiresAt"]))

        // Verified purchase: the context plus a status field, and the pending body
        // carries only a status.
        XCTAssertEqual(Set(try fields("cloudTransactionVerified").keys), ["status", "storeAccountToken", "entitlement", "household", "capability"])
        XCTAssertEqual(try endpoint("cloudTransactionVerified")["status"] as? Int, 200)
        XCTAssertEqual(Set(try fields("cloudTransactionPending").keys), ["status"])
        XCTAssertEqual(try endpoint("cloudTransactionPending")["status"] as? Int, 202)
        let verified = try JSONDecoder.cloud.decode(CloudContext.self, from: CloudContractFixtures.verifiedTransaction)
        XCTAssertTrue(verified.entitlementState.grantsCloud)
        XCTAssertEqual(verified.revision, 4, "the revision the next Cloud write must send is readable")

        // Bootstrap and household mutations.
        XCTAssertEqual(
            Set(try fields("cloudBootstrap").keys),
            ["household", "family", "child", "wallet", "entries", "loans", "allowanceRule", "nextCursor"]
        )
        XCTAssertEqual(Set(try fields("cloudHouseholdMutation").keys), ["entry", "wallet", "revision"])
        XCTAssertEqual(try endpoint("revisionConflictError")["status"] as? Int, 409)
        XCTAssertEqual(try endpoint("revisionRequiredError")["status"] as? Int, 428)

        // The client hashes the import aggregate in the server's accepted order.
        let aggregate = CloudImportManifest(
            lineageID: UUID(), operationID: UUID(), familyName: "f", nickname: "n", avatarURL: nil, loans: [], entries: []
        ).canonicalAggregate
        guard case .object(let members) = aggregate else { return XCTFail("aggregate must be a JSON object") }
        XCTAssertEqual(members.map(\.0), ["lineageId", "familyName", "nickname", "avatarUrl", "loans", "entries"])
    }

    // MARK: - Helpers

    private static let baseURL = URL(string: "https://api.example.test")!

    private func client(_ body: Data, status: Int = 200) -> CloudAPIClient {
        CloudAPIClient(
            baseURL: Self.baseURL,
            sessionStore: InMemorySessionStore(session: session),
            transport: StubTransport(responses: [.init(statusCode: status, body: body)])
        )
    }

    private func capability(_ body: Data) async throws -> CloudCapabilities {
        try await client(body).capabilities()
    }

    private func context(_ body: Data) async throws -> CloudContext {
        try await client(body).context()
    }
}

/// Exact bodies observed from the private backend's Cloud endpoints.
enum CloudContractFixtures {
    static let capabilitiesReady = json("""
    {"cloudActivationAvailable":true,"cloudServiceAvailable":true,
     "products":["com.kunchenguid.eddieswallet.cloud.monthly","com.kunchenguid.eddieswallet.cloud.annual"]}
    """)
    static let capabilitiesDark = json("""
    {"cloudActivationAvailable":false,"cloudServiceAvailable":false,
     "products":["com.kunchenguid.eddieswallet.cloud.monthly","com.kunchenguid.eddieswallet.cloud.annual"]}
    """)
    static let capabilitiesPartialProducts = json("""
    {"cloudActivationAvailable":true,"cloudServiceAvailable":true,
     "products":["com.kunchenguid.eddieswallet.cloud.monthly"]}
    """)
    static let capabilitiesWithUnknownFields = json("""
    {"cloudActivationAvailable":true,"cloudServiceAvailable":true,"futureFlag":"ignored",
     "products":["com.kunchenguid.eddieswallet.cloud.monthly","com.kunchenguid.eddieswallet.cloud.annual"]}
    """)

    static let contextNoEntitlement = json("""
    {"storeAccountToken":"5d15c540-02fe-475c-9c07-70260a3a0db5","entitlement":null,"household":null,
     "capability":{"newActivationsEnabled":true,"serviceMode":"serve"}}
    """)
    /// The merged verified-purchase body: `status` plus exactly the context that
    /// `GET /v1/cloud/context` serves (eddies-wallet-backend 7f48fc5).
    static let verifiedTransaction = json("""
    {"status":"verified","storeAccountToken":"bf22c3db-6688-4862-9011-9cfef2720341",
     "entitlement":{"state":"active","accessUntil":"2026-08-28T21:03:47.170Z","graceExpiresAt":null,
                    "lastReconciledAt":"2026-07-29T21:33:48.047Z","active":true},
     "household":{"lineageId":"c715311d-e4c5-4878-99b7-f42adb8ff90e","authority":"cloud","revision":4},
     "capability":{"newActivationsEnabled":true,"serviceMode":"serve"}}
    """)
    /// A verified purchase before activation: the household is still the legacy
    /// service wallet at revision 0, which is not a Cloud grant.
    static let verifiedTransactionBeforeActivation = json("""
    {"status":"verified","storeAccountToken":"bf22c3db-6688-4862-9011-9cfef2720341",
     "entitlement":{"state":"active","accessUntil":"2026-08-28T21:03:47.170Z","graceExpiresAt":null,
                    "lastReconciledAt":"2026-07-29T21:33:48.047Z","active":true},
     "household":{"lineageId":"c715311d-e4c5-4878-99b7-f42adb8ff90e","authority":"legacy_service","revision":0},
     "capability":{"newActivationsEnabled":true,"serviceMode":"serve"}}
    """)

    static let contextActive = json("""
    {"storeAccountToken":"bf22c3db-6688-4862-9011-9cfef2720341",
     "entitlement":{"state":"active","accessUntil":"2026-08-28T21:03:47.170Z","graceExpiresAt":null,
                    "lastReconciledAt":"2026-07-29T21:33:48.047Z","active":true},
     "household":{"lineageId":"c715311d-e4c5-4878-99b7-f42adb8ff90e","authority":"cloud","revision":4},
     "capability":{"newActivationsEnabled":true,"serviceMode":"serve"}}
    """)
    static let contextBillingGrace = json("""
    {"storeAccountToken":"bf22c3db-6688-4862-9011-9cfef2720341",
     "entitlement":{"state":"billing_grace","accessUntil":"2026-07-29T21:34:16.643Z",
                    "graceExpiresAt":"2026-08-14T21:32:16.643Z","active":true},
     "household":{"lineageId":"c715311d-e4c5-4878-99b7-f42adb8ff90e","authority":"cloud","revision":4}}
    """)
    static let contextExpired = json("""
    {"storeAccountToken":"bf22c3db-6688-4862-9011-9cfef2720341",
     "entitlement":{"state":"expired","accessUntil":"2026-07-29T21:35:16.643Z","graceExpiresAt":null,"active":false},
     "household":{"lineageId":"c715311d-e4c5-4878-99b7-f42adb8ff90e","authority":"cloud","revision":4}}
    """)
    static let contextRevoked = json("""
    {"storeAccountToken":"bf22c3db-6688-4862-9011-9cfef2720341",
     "entitlement":{"state":"revoked","accessUntil":null,"graceExpiresAt":null,"active":false},
     "household":{"lineageId":"c715311d-e4c5-4878-99b7-f42adb8ff90e","authority":"cloud","revision":4}}
    """)
    static let contextPending = json("""
    {"storeAccountToken":"bf22c3db-6688-4862-9011-9cfef2720341",
     "entitlement":{"state":"verification_pending","accessUntil":null,"graceExpiresAt":null,"active":false},
     "household":null}
    """)
    static let contextUnknownAuthority = json("""
    {"storeAccountToken":"bf22c3db-6688-4862-9011-9cfef2720341","entitlement":null,
     "household":{"lineageId":"c715311d-e4c5-4878-99b7-f42adb8ff90e","authority":"future_mode","revision":9}}
    """)
    static let contextLegacyAuthority = json("""
    {"storeAccountToken":"bf22c3db-6688-4862-9011-9cfef2720341","entitlement":null,
     "household":{"lineageId":"c715311d-e4c5-4878-99b7-f42adb8ff90e","authority":"legacy_service","revision":0}}
    """)
    static let contextCloudWithoutLineage = json("""
    {"storeAccountToken":"bf22c3db-6688-4862-9011-9cfef2720341","entitlement":null,
     "household":{"lineageId":null,"authority":"cloud","revision":3}}
    """)

    static let bootstrap = json("""
    {"household":{"lineageId":"43053f83-eae7-46ac-9516-ca41406c7ff1","authority":"cloud","revision":4},
     "family":{"id":"f-1","name":"Test Kid's family"},
     "child":{"id":"c-1","nickname":"Test Kid","avatarUrl":null},
     "wallet":{"id":"w-1","balanceCents":500,"currency":"USD"},
     "entries":[
       {"id":"e-1","type":"deposit","direction":"credit","amountCents":500,"balanceBeforeCents":0,"balanceAfterCents":500,"reason":"chores","loanId":null,"recordedAt":"2026-07-24T21:31:53.781Z","acceptedRevision":1},
       {"id":"e-2","type":"loan","direction":"credit","amountCents":300,"balanceBeforeCents":500,"balanceAfterCents":800,"reason":"scooter","loanId":"96e6db14-91ea-4fa4-9a43-dddebd3d3807","recordedAt":"2026-07-25T21:31:53.781Z","acceptedRevision":2},
       {"id":"e-3","type":"repayment","direction":"debit","amountCents":100,"balanceBeforeCents":800,"balanceAfterCents":700,"reason":null,"loanId":"96e6db14-91ea-4fa4-9a43-dddebd3d3807","recordedAt":"2026-07-26T21:31:53.781Z","acceptedRevision":3},
       {"id":"e-4","type":"withdrawal","direction":"debit","amountCents":200,"balanceBeforeCents":700,"balanceAfterCents":500,"reason":"sticker book","loanId":null,"recordedAt":"2026-07-27T21:31:53.781Z","acceptedRevision":4}],
     "loans":[{"id":"96e6db14-91ea-4fa4-9a43-dddebd3d3807","principalCents":300,"outstandingCents":200,"purpose":"scooter","dueDate":null,"status":"open","createdAt":"2026-07-25T21:31:53.781Z","paidAt":null}],
     "allowanceRule":{"id":"a-1","amountCents":500,"cadence":"weekly","weekday":5,"startDate":"2026-08-07","endDate":null,"active":true},
     "nextCursor":null}
    """)
    static let changesAfterRevision = json("""
    {"household":{"lineageId":"43053f83-eae7-46ac-9516-ca41406c7ff1","authority":"cloud","revision":5},
     "family":{"id":"f-1","name":"Test Kid's family"},
     "child":{"id":"c-1","nickname":"Test Kid","avatarUrl":null},
     "wallet":{"id":"w-1","balanceCents":750,"currency":"USD"},
     "entries":[{"id":"e-5","type":"deposit","direction":"credit","amountCents":250,"balanceBeforeCents":500,"balanceAfterCents":750,"reason":"allowance top-up","loanId":null,"recordedAt":"2026-07-28T21:31:53.781Z","acceptedRevision":5}],
     "loans":[],"allowanceRule":null}
    """)

    static let depositAccepted = json("""
    {"entry":{"id":"e-5","type":"deposit","amountCents":250},"wallet":{"id":"w-1","balanceCents":750},"revision":5}
    """)
    static let revisionConflictError = json("""
    {"error":{"code":"REVISION_CONFLICT","message":"This wallet changed on another device.","details":{"currentRevision":7}}}
    """)
    static let revisionRequiredError = json("""
    {"error":{"code":"REVISION_REQUIRED","message":"Cloud changes require the current household revision."}}
    """)
    static let entitlementRequiredError = json("""
    {"error":{"code":"CLOUD_ENTITLEMENT_REQUIRED","message":"An active Cloud subscription is required to record this action."}}
    """)
    static let accountMismatchError = json("""
    {"error":{"code":"STORE_TRANSACTION_ACCOUNT_MISMATCH","message":"This App Store purchase belongs to another parent account."}}
    """)
    static let unverifiedError = json("""
    {"error":{"code":"STORE_TRANSACTION_UNVERIFIED","message":"StoreKit signed data could not be verified."}}
    """)

    static let expectedAggregateJSON = "{\"lineageId\":\"55555555-5555-4555-8555-555555555555\",\"familyName\":\"Test Kid\u{2019}s family\",\"nickname\":\"Test Kid\",\"avatarUrl\":null,\"loans\":[{\"id\":\"11111111-1111-4111-8111-111111111111\",\"principalCents\":300,\"outstandingCents\":200,\"purpose\":\"scooter \\\"fast\\\"\",\"dueDate\":\"2026-09-01\",\"status\":\"open\",\"createdAt\":\"2026-07-25T10:00:00.000Z\",\"paidAt\":null}],\"entries\":[{\"operationId\":\"22222222-2222-4222-8222-222222222222\",\"type\":\"deposit\",\"direction\":\"credit\",\"amountCents\":500,\"balanceBeforeCents\":0,\"balanceAfterCents\":500,\"reason\":\"chores\\nweek 1\",\"loanId\":null,\"recordedAt\":\"2026-07-24T10:00:00.000Z\"},{\"operationId\":\"33333333-3333-4333-8333-333333333333\",\"type\":\"loan\",\"direction\":\"credit\",\"amountCents\":300,\"balanceBeforeCents\":500,\"balanceAfterCents\":800,\"reason\":\"scooter \\\"fast\\\"\",\"loanId\":\"11111111-1111-4111-8111-111111111111\",\"recordedAt\":\"2026-07-25T10:00:00.000Z\"},{\"operationId\":\"44444444-4444-4444-8444-444444444444\",\"type\":\"repayment\",\"direction\":\"debit\",\"amountCents\":100,\"balanceBeforeCents\":800,\"balanceAfterCents\":700,\"reason\":null,\"loanId\":\"11111111-1111-4111-8111-111111111111\",\"recordedAt\":\"2026-07-26T10:00:00.000Z\"}]}"
    static let expectedAggregateDigest = "1e0ead09e9b8d84572c313e0041cf86659b74798e9c4a3c497d2c8d2cb3fa8bd"

    private static func json(_ value: String) -> Data { Data(value.utf8) }
}

/// Minimal transport stub for contract tests.
final class StubTransport: HTTPTransport, @unchecked Sendable {
    struct Response {
        let statusCode: Int
        let body: Data
    }

    private(set) var requests: [URLRequest] = []
    private var responses: [Response]

    init(responses: [Response]) {
        self.responses = responses
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        let response = responses.isEmpty ? Response(statusCode: 500, body: Data()) : responses.removeFirst()
        return (
            response.body,
            HTTPURLResponse(url: request.url!, statusCode: response.statusCode, httpVersion: nil, headerFields: nil)!
        )
    }
}

private extension Data {
    func jsonObject() -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: self)) as? [String: Any] ?? [:]
    }
}
