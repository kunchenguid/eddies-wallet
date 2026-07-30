import Foundation

/// Public Cloud contract client. It contains only public method/path/status
/// vocabulary and is injected in tests. Release code never substitutes a
/// capability or transaction response for server authority.
@MainActor
public final class CloudAPIClient: ParentAuthenticator {
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
            session: .never
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

    /// Capability discovery stays readable without a session, but presents the
    /// parent session whenever this device has one. The service may scope Cloud
    /// availability to a named parent, and it can only do that when it can see
    /// who is asking; an anonymous read still returns the public answer.
    public func capabilities() async throws -> CloudCapabilities {
        try await send(path: "/v1/capabilities", method: "GET", body: nil, session: .presentedWhenAvailable)
            .decoded(CloudCapabilities.self)
    }

    public func context() async throws -> CloudContext {
        try await send(path: "/v1/cloud/context", method: "GET", body: nil, session: .required).decoded(CloudContext.self)
    }

    /// The server receives Apple's signed JWS. No decoded client claim is sent.
    /// A verified 200 returns the full context, which is the only thing that may
    /// enable Cloud; 202 stays server-pending.
    public func deliver(transactionJWS: String) async throws -> CloudContext {
        try await send(
            path: "/v1/cloud/transactions",
            method: "POST",
            body: ["signedTransaction": transactionJWS],
            session: .required,
            idempotencyKey: UUID().uuidString,
            pendingStatusCode: 202
        ).decoded(CloudContext.self)
    }

    public func bootstrap(cursor: String? = nil) async throws -> CloudReplica {
        let suffix = cursor.map { "?cursor=" + ($0.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "") } ?? ""
        return try await send(path: "/v1/cloud/bootstrap\(suffix)", method: "GET", body: nil, session: .required).decoded(CloudReplica.self)
    }

    public func changes(afterRevision revision: Int64) async throws -> CloudReplica {
        try await send(path: "/v1/cloud/changes?afterRevision=\(revision)", method: "GET", body: nil, session: .required).decoded(CloudReplica.self)
    }

    public func allowanceSchedule() async throws -> CloudAllowanceSchedule {
        try await send(path: "/v1/allowance-rule", method: "GET", body: nil, session: .required).decoded(CloudAllowanceSchedule.self)
    }

    /// Sends one already-persisted runtime mutation. The exact body, key, and
    /// revision come from the durable record so retries cannot drift. A 2xx
    /// response is usable only when it includes a stable entry id or accepted
    /// revision, either in the JSON body or its revision ETag.
    func mutate(_ mutation: PendingCloudMutation) async throws -> CloudMutationAcceptance {
        let response = try await sendResponse(
            path: mutation.path,
            method: mutation.method,
            body: mutation.body,
            session: .required,
            idempotencyKey: mutation.idempotencyKey,
            expectedRevision: mutation.expectedRevision
        )
        guard let object = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any] else {
            throw WalletAPIError.invalidResponse("Cloud accepted a response that this device could not reconcile.")
        }
        let rawEntryID = (object["entry"] as? [String: Any])?["id"] as? String
        let entryID = rawEntryID?.isEmpty == false ? rawEntryID : nil
        let bodyRevision = Self.int64(object["revision"])
            ?? Self.int64((object["family"] as? [String: Any])?["revision"])
            ?? Self.int64((object["household"] as? [String: Any])?["revision"])
        let etagRevision = response.http.value(forHTTPHeaderField: "ETag").flatMap(Self.revision(fromETag:))
        let reportedRevision = bodyRevision ?? etagRevision
        let nextRevision = mutation.expectedRevision == .max ? nil : mutation.expectedRevision + 1
        let acceptedRevision: Int64? = if let reportedRevision, let nextRevision, reportedRevision == nextRevision {
            reportedRevision
        } else {
            nil
        }
        let accepted = CloudMutationAcceptance(entryID: entryID, revision: acceptedRevision)
        guard accepted.entryID != nil || accepted.revision != nil else {
            throw WalletAPIError.invalidResponse("Cloud accepted a response without an entry id or revision.")
        }
        return accepted
    }

    /// One-time upload of the complete local household. The manifest carries its
    /// own operation id and aggregate digest, and the idempotency key is stable
    /// across retries so an interrupted upload replays instead of duplicating.
    public func importHousehold(_ manifest: CloudImportManifest, idempotencyKey: String) async throws -> CloudHousehold {
        let data = try await sendData(
            path: "/v1/cloud/household/import",
            method: "POST",
            body: manifest.requestBody,
            session: .required,
            idempotencyKey: idempotencyKey
        )
        return try data.decoded(HouseholdEnvelope.self).household
    }

    public func legacyContext() async throws -> CloudLegacyContext {
        try await send(path: "/v1/cloud/legacy-context", method: "GET", body: nil, session: .required).decoded(CloudLegacyContext.self)
    }

    public func revokeCurrentSession() async throws {
        _ = try await send(path: "/v1/session/current", method: "DELETE", body: nil, session: .required)
        sessionStore.clear()
    }

    /// Clears only the local session copy, for an authority-aware sign-out that
    /// could not reach the server.
    public func clearLocalSession() {
        sessionStore.clear()
    }

    /// How a request presents the parent session.
    private enum SessionPresentation {
        /// Never authenticated, even when a session exists.
        case never
        /// A valid session is required; the request fails without one.
        case required
        /// A valid session is presented when this device has one, and the
        /// request is still made anonymously when it does not.
        case presentedWhenAvailable
    }

    private func send(path: String, method: String, body: [String: Any]?, session: SessionPresentation, idempotencyKey: String? = nil, pendingStatusCode: Int? = nil) async throws -> Data {
        let data = body.map { try? JSONSerialization.data(withJSONObject: $0) } ?? nil
        return try await sendData(path: path, method: method, body: data, session: session, idempotencyKey: idempotencyKey, pendingStatusCode: pendingStatusCode)
    }

    private func sendData(
        path: String,
        method: String,
        body: Data?,
        session: SessionPresentation,
        idempotencyKey: String? = nil,
        pendingStatusCode: Int? = nil
    ) async throws -> Data {
        try await sendResponse(
            path: path,
            method: method,
            body: body,
            session: session,
            idempotencyKey: idempotencyKey,
            pendingStatusCode: pendingStatusCode
        ).data
    }

    private func sendResponse(
        path: String,
        method: String,
        body: Data?,
        session: SessionPresentation,
        idempotencyKey: String? = nil,
        pendingStatusCode: Int? = nil,
        expectedRevision: Int64? = nil
    ) async throws -> CloudHTTPResponse {
        guard let url = URL(string: path, relativeTo: baseURL) else { throw WalletAPIError.invalidConfiguration }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body { request.httpBody = body; request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if let idempotencyKey { request.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key") }
        if let expectedRevision { request.setValue("\"rev-\(expectedRevision)\"", forHTTPHeaderField: "If-Match") }
        switch session {
        case .never:
            break
        case .required:
            guard let stored = sessionStore.session, !stored.isExpired else { throw WalletAPIError.noSession }
            request.setValue("Bearer \(stored.token)", forHTTPHeaderField: "Authorization")
        case .presentedWhenAvailable:
            // An expired session is never presented: it would only invite a 401
            // that clears the session behind an otherwise public read.
            if let stored = sessionStore.session, !stored.isExpired {
                request.setValue("Bearer \(stored.token)", forHTTPHeaderField: "Authorization")
            }
        }
        do {
            let (data, response) = try await transport.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw WalletAPIError.invalidResponse("The server returned an invalid HTTP response.") }
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
            return CloudHTTPResponse(data: data, http: http)
        } catch let error as WalletAPIError { throw error
        } catch { throw WalletAPIError.network("Cloud is unavailable right now. Your wallet is still available on this device.") }
    }

    private static func int64(_ value: Any?) -> Int64? {
        if let value = value as? NSNumber {
            guard CFGetTypeID(value) != CFBooleanGetTypeID() else { return nil }
            guard let parsed = Int64(value.stringValue), parsed >= 0 else { return nil }
            return parsed
        }
        if let value = value as? String, let parsed = Int64(value), parsed >= 0 { return parsed }
        return nil
    }

    private static func revision(fromETag value: String) -> Int64? {
        guard value.hasPrefix("\"rev-"), value.hasSuffix("\"") else { return nil }
        return Int64(value.dropFirst(5).dropLast())
    }
}

private struct CloudHTTPResponse {
    let data: Data
    let http: HTTPURLResponse
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
