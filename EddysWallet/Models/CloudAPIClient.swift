import Foundation

/// Public Cloud contract client. It contains only public method/path/status
/// vocabulary and is injected in tests. Release code never substitutes a
/// capability or transaction response for server authority.
@MainActor
public final class CloudAPIClient: ParentAuthenticator {
    /// Accepted Cloud command result: the new household revision plus whatever
    /// the endpoint returned. Callers refresh from `/v1/cloud/changes` rather
    /// than trusting a per-endpoint body shape.
    public struct CommandAcceptance: Equatable, Sendable {
        public let revision: Int64?
        public let statusCode: Int
    }

    private let baseURL: URL
    private let sessionStore: any SessionStore
    private let transport: any HTTPTransport

    public init(baseURL: URL = APIConfiguration.productionBaseURL, sessionStore: (any SessionStore)? = nil, transport: any HTTPTransport = URLSessionTransport()) {
        self.baseURL = baseURL
        self.sessionStore = sessionStore ?? KeychainSessionStore()
        self.transport = transport
    }

    public var hasSession: Bool { sessionStore.session?.isExpired == false }

    public func authenticateApple(identityToken: String, nonce: String) async throws -> AuthSession {
        guard !identityToken.isEmpty, !nonce.isEmpty else {
            throw WalletAPIError.invalidResponse("Apple Sign In did not return the required identity proof.")
        }
        let response = try await send(
            path: "/v1/auth/apple",
            method: "POST",
            body: ["identityToken": identityToken, "nonce": nonce],
            authenticated: false
        ).decoded(CloudAuthResponse.self)
        guard !response.token.isEmpty, response.expiresAt > .now else {
            throw WalletAPIError.invalidResponse("The authentication service returned an invalid session.")
        }
        let session = AuthSession(token: response.token, expiresAt: response.expiresAt)
        do {
            try sessionStore.save(session)
        } catch {
            throw WalletAPIError.invalidResponse("The parent session could not be stored securely.")
        }
        return session
    }

    public func establishSession(_ session: AuthSession) throws {
        guard !session.token.isEmpty, !session.isExpired else {
            throw WalletAPIError.invalidResponse("Cloud Sign In did not return a usable session.")
        }
        try sessionStore.save(session)
    }

    public func capabilities() async throws -> CloudCapabilities {
        try await send(path: "/v1/capabilities", method: "GET", body: nil, authenticated: false).decoded(CloudCapabilities.self)
    }

    public func context() async throws -> CloudContext {
        try await send(path: "/v1/cloud/context", method: "GET", body: nil, authenticated: true).decoded(CloudContext.self)
    }

    /// The server receives Apple's signed JWS. No decoded client claim is sent.
    /// A verified 200 returns the full context, which is the only thing that may
    /// enable Cloud; 202 stays server-pending.
    public func deliver(transactionJWS: String) async throws -> CloudContext {
        try await send(
            path: "/v1/cloud/transactions",
            method: "POST",
            body: ["signedTransaction": transactionJWS],
            authenticated: true,
            idempotencyKey: UUID().uuidString,
            pendingStatusCode: 202
        ).decoded(CloudContext.self)
    }

    public func bootstrap(cursor: String? = nil) async throws -> CloudReplica {
        let suffix = cursor.map { "?cursor=" + ($0.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "") } ?? ""
        return try await send(path: "/v1/cloud/bootstrap\(suffix)", method: "GET", body: nil, authenticated: true).decoded(CloudReplica.self)
    }

    public func changes(afterRevision revision: Int64) async throws -> CloudReplica {
        try await send(path: "/v1/cloud/changes?afterRevision=\(revision)", method: "GET", body: nil, authenticated: true).decoded(CloudReplica.self)
    }

    public func allowanceSchedule() async throws -> CloudAllowanceSchedule {
        try await send(path: "/v1/allowance-rule", method: "GET", body: nil, authenticated: true).decoded(CloudAllowanceSchedule.self)
    }

    /// One-time upload of the complete local household. The manifest carries its
    /// own operation id and aggregate digest, and the idempotency key is stable
    /// across retries so an interrupted upload replays instead of duplicating.
    public func importHousehold(_ manifest: CloudImportManifest, idempotencyKey: String) async throws -> CloudHousehold {
        let data = try await sendData(
            path: "/v1/cloud/household/import",
            method: "POST",
            body: manifest.requestBody,
            authenticated: true,
            idempotencyKey: idempotencyKey
        )
        return try data.decoded(HouseholdEnvelope.self).household
    }

    public func legacyContext() async throws -> CloudLegacyContext {
        try await send(path: "/v1/cloud/legacy-context", method: "GET", body: nil, authenticated: true).decoded(CloudLegacyContext.self)
    }

    public func detachLegacy(expectedRevision: Int64, idempotencyKey: String = UUID().uuidString) async throws -> CloudHousehold {
        try await revisionRequest(path: "/v1/cloud/legacy-detach", revision: expectedRevision, idempotencyKey: idempotencyKey)
    }

    public func activateLegacy(expectedRevision: Int64, idempotencyKey: String = UUID().uuidString) async throws -> CloudHousehold {
        try await revisionRequest(path: "/v1/cloud/legacy-activate", revision: expectedRevision, idempotencyKey: idempotencyKey)
    }

    /// Cloud household mutation. Every write carries the retained revision as
    /// `If-Match`, so a stale device is refused instead of overwriting.
    public func command(
        path: String,
        body: [String: Any],
        expectedRevision: Int64,
        idempotencyKey: String,
        method: String = "POST"
    ) async throws -> CommandAcceptance {
        try await sendCommand(
            path: path,
            method: method,
            body: try JSONSerialization.data(withJSONObject: body),
            expectedRevision: expectedRevision,
            idempotencyKey: idempotencyKey
        )
    }

    public func revokeCurrentSession() async throws {
        _ = try await send(path: "/v1/session/current", method: "DELETE", body: nil, authenticated: true)
        sessionStore.clear()
    }

    /// Clears only the local session copy, for an authority-aware sign-out that
    /// could not reach the server.
    public func clearLocalSession() {
        sessionStore.clear()
    }

    private func revisionRequest(path: String, revision: Int64, idempotencyKey: String) async throws -> CloudHousehold {
        try await send(path: path, method: "POST", body: [:], authenticated: true, idempotencyKey: idempotencyKey, revision: revision)
            .decoded(HouseholdEnvelope.self).household
    }

    private func send(path: String, method: String, body: [String: Any]?, authenticated: Bool, idempotencyKey: String? = nil, revision: Int64? = nil, pendingStatusCode: Int? = nil) async throws -> Data {
        let data = body.map { try? JSONSerialization.data(withJSONObject: $0) } ?? nil
        return try await sendData(path: path, method: method, body: data, authenticated: authenticated, idempotencyKey: idempotencyKey, revision: revision, pendingStatusCode: pendingStatusCode)
    }

    private func sendCommand(path: String, method: String, body: Data, expectedRevision: Int64, idempotencyKey: String) async throws -> CommandAcceptance {
        var status = 0
        let data = try await sendData(
            path: path,
            method: method,
            body: body,
            authenticated: true,
            idempotencyKey: idempotencyKey,
            revision: expectedRevision,
            observedStatus: { status = $0 }
        )
        return CommandAcceptance(revision: (try? data.decoded(RevisionEnvelope.self))?.resolvedRevision, statusCode: status)
    }

    private func sendData(
        path: String,
        method: String,
        body: Data?,
        authenticated: Bool,
        idempotencyKey: String? = nil,
        revision: Int64? = nil,
        pendingStatusCode: Int? = nil,
        observedStatus: ((Int) -> Void)? = nil
    ) async throws -> Data {
        guard let url = URL(string: path, relativeTo: baseURL) else { throw WalletAPIError.invalidConfiguration }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body { request.httpBody = body; request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if let idempotencyKey { request.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key") }
        if let revision { request.setValue("\"rev-\(revision)\"", forHTTPHeaderField: "If-Match") }
        if authenticated {
            guard let session = sessionStore.session, !session.isExpired else { throw WalletAPIError.noSession }
            request.setValue("Bearer \(session.token)", forHTTPHeaderField: "Authorization")
        }
        do {
            let (data, response) = try await transport.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw WalletAPIError.invalidResponse("The server returned an invalid HTTP response.") }
            observedStatus?(http.statusCode)
            if http.statusCode == pendingStatusCode {
                throw WalletAPIError.server(statusCode: http.statusCode, code: "VERIFICATION_PENDING", message: "The Cloud service is still verifying this purchase.")
            }
            guard (200..<300).contains(http.statusCode) else {
                if http.statusCode == 401 { sessionStore.clear(); throw WalletAPIError.unauthorized }
                let envelope = try? JSONDecoder().decode(CloudErrorEnvelope.self, from: data)
                if http.statusCode == 409, envelope?.error.code == "REVISION_CONFLICT" {
                    throw WalletAPIError.revisionConflict(currentRevision: envelope?.error.details?.currentRevision ?? envelope?.error.currentRevision ?? 0)
                }
                if http.statusCode == 428 {
                    throw WalletAPIError.revisionRequired
                }
                if http.statusCode == 403, envelope?.error.code == "CLOUD_ENTITLEMENT_REQUIRED" {
                    throw WalletAPIError.cloudEntitlementRequired
                }
                throw WalletAPIError.server(statusCode: http.statusCode, code: envelope?.error.code ?? "HTTP_\(http.statusCode)", message: envelope?.error.message ?? "The Cloud service did not accept this request.")
            }
            return data
        } catch let error as WalletAPIError { throw error
        } catch { throw WalletAPIError.network("Cloud is unavailable right now. Your wallet is still available on this device.") }
    }
}

public struct CloudLegacyContext: Codable, Equatable, Sendable {
    public let household: CloudHousehold?
    public let entitlement: CloudEntitlementStateDTO?
    public let exportAvailable: Bool?
}

private struct HouseholdEnvelope: Decodable {
    let household: CloudHousehold
}

private struct CloudAuthResponse: Decodable {
    let token: String
    let expiresAt: Date
}

/// Accepted wallet commands report the new revision either at the top level or
/// inside the family/household object, depending on the endpoint.
private struct RevisionEnvelope: Decodable {
    private struct Nested: Decodable { let revision: Int64? }
    private let revision: Int64?
    private let family: Nested?
    private let household: Nested?

    var resolvedRevision: Int64? { revision ?? family?.revision ?? household?.revision }
}

private struct CloudErrorEnvelope: Decodable {
    struct Details: Decodable { let currentRevision: Int64? }
    struct Body: Decodable {
        let code: String
        let message: String
        let currentRevision: Int64?
        let details: Details?
    }
    let error: Body
}

private extension Data {
    func decoded<T: Decodable>(_ type: T.Type) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)
            guard let date = CloudDateFormat.date(from: raw) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unsupported date \(raw)"))
            }
            return date
        }
        do { return try decoder.decode(type, from: self) }
        catch { throw WalletAPIError.invalidResponse("The Cloud response could not be read.") }
    }
}

/// The service emits ISO-8601 with or without fractional seconds.
enum CloudDateFormat {
    static func date(from raw: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: raw) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }
}
