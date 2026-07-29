import Foundation

/// Public Cloud contract client. It contains only public method/path/status
/// vocabulary and is injected in tests. Release code never substitutes a
/// capability or transaction response for server authority.
@MainActor
public final class CloudAPIClient {
    private let baseURL: URL
    private let sessionStore: any SessionStore
    private let transport: any HTTPTransport

    public init(baseURL: URL = APIConfiguration.productionBaseURL, sessionStore: (any SessionStore)? = nil, transport: any HTTPTransport = URLSessionTransport()) {
        self.baseURL = baseURL
        self.sessionStore = sessionStore ?? KeychainSessionStore()
        self.transport = transport
    }

    public func capabilities() async throws -> CloudCapabilities {
        try await send(path: "/v1/capabilities", method: "GET", body: nil, authenticated: false).decoded(CloudCapabilities.self)
    }

    public func context() async throws -> CloudContext {
        try await send(path: "/v1/cloud/context", method: "GET", body: nil, authenticated: true).decoded(CloudContext.self)
    }

    /// The server receives Apple's signed JWS. No decoded client claim is sent.
    public func deliver(transactionJWS: String) async throws -> CloudContext {
        try await send(path: "/v1/cloud/transactions", method: "POST", body: ["signedTransaction": transactionJWS], authenticated: true, idempotencyKey: UUID().uuidString).decoded(CloudContext.self)
    }

    public func bootstrap(cursor: String? = nil) async throws -> Data {
        let suffix = cursor.map { "?cursor=" + ($0.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "") } ?? ""
        return try await send(path: "/v1/cloud/bootstrap\(suffix)", method: "GET", body: nil, authenticated: true)
    }

    public func changes(afterRevision revision: Int64) async throws -> Data {
        try await send(path: "/v1/cloud/changes?afterRevision=\(revision)", method: "GET", body: nil, authenticated: true)
    }

    public func importHousehold(_ manifest: Data, idempotencyKey: String = UUID().uuidString) async throws -> Data {
        try await sendData(path: "/v1/cloud/household/import", method: "POST", body: manifest, authenticated: true, idempotencyKey: idempotencyKey)
    }

    public func legacyContext() async throws -> Data { try await send(path: "/v1/cloud/legacy-context", method: "GET", body: nil, authenticated: true) }
    public func detachLegacy(expectedRevision: Int64, idempotencyKey: String = UUID().uuidString) async throws -> Data { try await revisionRequest(path: "/v1/cloud/legacy-detach", revision: expectedRevision, idempotencyKey: idempotencyKey) }
    public func activateLegacy(expectedRevision: Int64, idempotencyKey: String = UUID().uuidString) async throws -> Data { try await revisionRequest(path: "/v1/cloud/legacy-activate", revision: expectedRevision, idempotencyKey: idempotencyKey) }

    public func revokeCurrentSession() async throws {
        _ = try await send(path: "/v1/session/current", method: "DELETE", body: nil, authenticated: true)
        sessionStore.clear()
    }

    private func revisionRequest(path: String, revision: Int64, idempotencyKey: String) async throws -> Data {
        try await send(path: path, method: "POST", body: [:], authenticated: true, idempotencyKey: idempotencyKey, revision: revision)
    }

    private func send(path: String, method: String, body: [String: Any]?, authenticated: Bool, idempotencyKey: String? = nil, revision: Int64? = nil) async throws -> Data {
        let data = body.map { try? JSONSerialization.data(withJSONObject: $0) } ?? nil
        return try await sendData(path: path, method: method, body: data, authenticated: authenticated, idempotencyKey: idempotencyKey, revision: revision)
    }

    private func sendData(path: String, method: String, body: Data?, authenticated: Bool, idempotencyKey: String? = nil, revision: Int64? = nil) async throws -> Data {
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
            guard (200..<300).contains(http.statusCode) else {
                if http.statusCode == 401 { sessionStore.clear(); throw WalletAPIError.unauthorized }
                let envelope = try? JSONDecoder().decode(CloudErrorEnvelope.self, from: data)
                if http.statusCode == 409, envelope?.error.code == "REVISION_CONFLICT" {
                    throw WalletAPIError.revisionConflict(currentRevision: envelope?.error.currentRevision ?? 0)
                }
                throw WalletAPIError.server(statusCode: http.statusCode, code: envelope?.error.code ?? "HTTP_\(http.statusCode)", message: envelope?.error.message ?? "The Cloud service did not accept this request.")
            }
            return data
        } catch let error as WalletAPIError { throw error
        } catch { throw WalletAPIError.network("Cloud is unavailable right now. Your wallet is still available on this device.") }
    }
}

private struct CloudErrorEnvelope: Decodable {
    struct Details: Decodable { let code: String; let message: String; let currentRevision: Int64? }
    let error: Details
}

private extension Data {
    func decoded<T: Decodable>(_ type: T.Type) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do { return try decoder.decode(type, from: self) }
        catch { throw WalletAPIError.invalidResponse("The Cloud response could not be read.") }
    }
}
