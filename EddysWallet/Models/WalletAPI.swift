import CryptoKit
import Foundation
import Security

public enum AppleAppIdentity {
    public static let bundleIdentifier = "com.kunchenguid.eddieswallet"
    public static let backendAppleAudience = bundleIdentifier
    public static let testBundleIdentifier = "\(bundleIdentifier).tests"
}

public enum APIConfiguration {
    /// The only shipped API environment. The backend operator must provision this
    /// host and TLS before a real-account simulator test can pass.
    public static let productionBaseURL = URL(string: "https://eddieswallet.kunchenguid.com")!
    public static let productionBaseURLString = "https://eddieswallet.kunchenguid.com"
}

enum KeychainServiceMigration {
    static let currentSessionService = "\(AppleAppIdentity.bundleIdentifier).session"
    // Compatibility aliases for pre-correction builds. Migration changes only the service attribute.
    static let legacySessionService = "com.kunchenguid.eddyswallet.session"
    static let currentParentPINService = "\(AppleAppIdentity.bundleIdentifier).parent-pin"
    static let legacyParentPINService = "com.kunchenguid.eddyswallet.parent-pin"

    static func legacyService(forCurrentService service: String) -> String? {
        switch service {
        case currentSessionService: legacySessionService
        case currentParentPINService: legacyParentPINService
        default: nil
        }
    }

    /// Rename only the keychain item's service attribute. This does not read,
    /// log, or copy the protected value.
    static func renameItemIfNeeded(currentService: String, legacyService: String, account: String) {
        guard currentService != legacyService else { return }
        let currentQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: currentService,
            kSecAttrAccount as String: account
        ]
        guard SecItemCopyMatching(currentQuery as CFDictionary, nil) == errSecItemNotFound else { return }

        let legacyQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: legacyService,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [kSecAttrService as String: currentService]
        _ = SecItemUpdate(legacyQuery as CFDictionary, attributes as CFDictionary)
    }
}

public enum WalletAPIError: Error, Equatable, LocalizedError {
    case noSession
    case unauthorized
    case familyNotSetup
    case cancelled
    case timedOut
    case identityMismatch
    case server(statusCode: Int, code: String, message: String)
    case network(String)
    case invalidResponse(String)
    case invalidConfiguration

    public var errorDescription: String? {
        switch self {
        case .noSession: "Sign in with Apple before opening the wallet."
        case .unauthorized: "Your parent session expired. Sign in with Apple again."
        case .familyNotSetup: "Finish parent and child setup before opening the wallet."
        case .cancelled: "Sign in was cancelled."
        case .timedOut: "Apple Sign In took too long. Please try again."
        case .identityMismatch: "That is not the Apple account that manages this wallet."
        case let .server(_, _, message): message
        case let .network(message): message
        case let .invalidResponse(message): message
        case .invalidConfiguration: "The production API URL is not configured correctly."
        }
    }
}

@MainActor
public protocol SessionStore: AnyObject {
    var session: AuthSession? { get }
    func save(_ session: AuthSession) throws
    func clear()
}

@MainActor
public final class KeychainSessionStore: SessionStore {
    private let service: String
    private let account = "parent-session"

    public init(service: String = "\(AppleAppIdentity.bundleIdentifier).session") {
        self.service = service
    }

    public var session: AuthSession? {
        migrateLegacyItemIfNeeded()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let decoded = try? JSONDecoder().decode(AuthSession.self, from: data),
              !decoded.isExpired else {
            if result != nil { clear() }
            return nil
        }
        return decoded
    }

    public func save(_ session: AuthSession) throws {
        migrateLegacyItemIfNeeded()
        let data = try JSONEncoder().encode(session)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            attributes.forEach { item[$0.key] = $0.value }
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError(status: addStatus) }
        } else if status != errSecSuccess {
            throw KeychainError(status: status)
        }
    }

    public func clear() {
        migrateLegacyItemIfNeeded()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }

    private func migrateLegacyItemIfNeeded() {
        guard let legacyService = KeychainServiceMigration.legacyService(forCurrentService: service) else { return }
        KeychainServiceMigration.renameItemIfNeeded(
            currentService: service,
            legacyService: legacyService,
            account: account
        )
    }

    private struct KeychainError: Error {
        let status: OSStatus
    }
}

@MainActor
public protocol ParentPINStore: AnyObject {
    var pin: String? { get }
    func save(pin: String) throws
    func clear()
}

@MainActor
public final class KeychainParentPINStore: ParentPINStore {
    private let service = KeychainServiceMigration.currentParentPINService
    private let account = "parent-pin"

    public init() {}

    public var pin: String? {
        migrateLegacyItemIfNeeded()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let pin = String(data: data, encoding: .utf8),
              pin.count == 4 else { return nil }
        return pin
    }

    public func save(pin: String) throws {
        migrateLegacyItemIfNeeded()
        guard pin.count == 4, pin.allSatisfy(\.isNumber) else {
            throw WalletAPIError.invalidResponse("The parent PIN must contain four digits.")
        }
        let data = Data(pin.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            attributes.forEach { item[$0.key] = $0.value }
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw WalletAPIError.invalidResponse("The parent PIN could not be stored securely.") }
        } else if status != errSecSuccess {
            throw WalletAPIError.invalidResponse("The parent PIN could not be stored securely.")
        }
    }

    public func clear() {
        migrateLegacyItemIfNeeded()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }

    private func migrateLegacyItemIfNeeded() {
        KeychainServiceMigration.renameItemIfNeeded(
            currentService: service,
            legacyService: KeychainServiceMigration.legacyParentPINService,
            account: account
        )
    }
}

@MainActor
public final class InMemoryParentPINStore: ParentPINStore {
    public private(set) var pin: String?

    public init(pin: String? = nil) { self.pin = pin }
    public func save(pin: String) throws { self.pin = pin }
    public func clear() { pin = nil }
}

/// Stores the stable Apple user identifier of the owning parent on this
/// device. It is identity evidence for the forgotten-PIN recovery path: a
/// fresh Sign in with Apple must present the same Apple user identifier
/// before a new parent PIN may be set. The value is an opaque Apple-issued
/// identifier, not a name, email, or credential.
@MainActor
public protocol ParentIdentityStore: AnyObject {
    var appleUserID: String? { get }
    func save(appleUserID: String) throws
    func clear()
}

@MainActor
public final class KeychainParentIdentityStore: ParentIdentityStore {
    private let service = "\(AppleAppIdentity.bundleIdentifier).parent-apple-user"
    private let account = "owning-parent"

    public init() {}

    public var appleUserID: String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty else { return nil }
        return value
    }

    public func save(appleUserID: String) throws {
        guard !appleUserID.isEmpty else {
            throw WalletAPIError.invalidResponse("Apple Sign In did not return a user identifier.")
        }
        let data = Data(appleUserID.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            attributes.forEach { item[$0.key] = $0.value }
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw WalletAPIError.invalidResponse("The parent identity could not be stored securely.")
            }
        } else if status != errSecSuccess {
            throw WalletAPIError.invalidResponse("The parent identity could not be stored securely.")
        }
    }

    public func clear() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}

@MainActor
public final class InMemoryParentIdentityStore: ParentIdentityStore {
    public private(set) var appleUserID: String?

    public init(appleUserID: String? = nil) { self.appleUserID = appleUserID }
    public func save(appleUserID: String) throws { self.appleUserID = appleUserID }
    public func clear() { appleUserID = nil }
}

@MainActor
public final class InMemorySessionStore: SessionStore {
    public private(set) var session: AuthSession?

    public init(session: AuthSession? = nil) {
        self.session = session
    }

    public func save(_ session: AuthSession) throws { self.session = session }
    public func clear() { session = nil }
}

public protocol HTTPTransport {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }
}

@MainActor
public protocol WalletSnapshotCache: AnyObject {
    func load() -> WalletSnapshot?
    func save(_ snapshot: WalletSnapshot)
    func clear()
}

@MainActor
public protocol PendingCommandStore: AnyObject {
    func load() -> [WalletCommand]
    func save(_ commands: [WalletCommand])
    func clear()
}

@MainActor
public final class UserDefaultsPendingCommandStore: PendingCommandStore {
    private let defaults: UserDefaults
    private let key = "wallet.pending-commands.v1"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> [WalletCommand] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([WalletCommand].self, from: data)) ?? []
    }

    public func save(_ commands: [WalletCommand]) {
        guard let data = try? JSONEncoder().encode(commands) else { return }
        defaults.set(data, forKey: key)
    }

    public func clear() { defaults.removeObject(forKey: key) }
}

@MainActor
public final class InMemoryPendingCommandStore: PendingCommandStore {
    private var commands: [WalletCommand]

    public init(commands: [WalletCommand] = []) {
        self.commands = commands
    }

    public func load() -> [WalletCommand] { commands }
    public func save(_ commands: [WalletCommand]) { self.commands = commands }
    public func clear() { commands = [] }
}

@MainActor
public final class UserDefaultsWalletSnapshotCache: WalletSnapshotCache {
    private let defaults: UserDefaults
    private let key = "wallet.snapshot.v1"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> WalletSnapshot? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(WalletSnapshot.self, from: data)
    }

    public func save(_ snapshot: WalletSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: key)
    }

    public func clear() { defaults.removeObject(forKey: key) }
}

private enum WalletVocabulary {
    static let virtualNotice = "Virtual practice only. These dollars are pretend, cannot be redeemed, and never move real money."
}

private struct FlexibleInt: Decodable {
    let value: Int

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let number = try? container.decode(Int.self) {
            value = number
        } else {
            let string = try container.decode(String.self)
            guard let number = Int(string) else {
                throw WalletAPIError.invalidResponse("The server returned an invalid money amount.")
            }
            value = number
        }
    }
}

private struct ErrorEnvelope: Decodable {
    struct APIError: Decodable {
        let code: String
        let message: String
    }

    let error: APIError
}

private struct AuthResponseDTO: Decodable {
    let token: String
    let expiresAt: String
}

private struct WalletDTO: Decodable {
    let balanceCents: FlexibleInt
    let virtualNotice: String
}

private struct EntryDTO: Decodable {
    let id: String
    let type: String
    let direction: String
    let amountCents: FlexibleInt
    let balanceBeforeCents: FlexibleInt?
    let balanceAfterCents: FlexibleInt?
    let reason: String?
    let recordedAt: String
}

private struct LoanDTO: Decodable {
    let id: String
    let principalCents: FlexibleInt
    let outstandingCents: FlexibleInt
    let purpose: String?
    let dueDate: String?
    let status: String
    let createdAt: String
    let paidAt: String?
}

private struct AllowanceDTO: Decodable {
    let id: String
    let amountCents: FlexibleInt
    let cadence: String
    let weekday: Int
    let startDate: String
    let endDate: String?
    let active: Bool
    let nextOccurrenceId: String?
    let nextDueDate: String?
}

private struct ChildDTO: Decodable {
    let nickname: String?
}

private struct SnapshotDTO: Decodable {
    let child: ChildDTO?
    let wallet: WalletDTO
    let allowanceRule: AllowanceDTO?
    let loan: LoanDTO?
    let recentActivity: [EntryDTO]
    let readOnly: Bool?
}

private struct CommandDTO: Decodable {
    let entry: EntryDTO
    let wallet: WalletDTO
    let loan: LoanDTO?
}

private struct ActivityListDTO: Decodable {
    let entries: [EntryDTO]
    let virtualNotice: String
}

private struct ActivityDetailDTO: Decodable {
    let entry: EntryDTO
    let virtualNotice: String
}

private struct LoanDetailDTO: Decodable {
    let loan: LoanDTO
    let repaymentsAndLoanEntry: [EntryDTO]
    let virtualNotice: String
}

@MainActor
public final class APIWalletRepository: WalletRepository, ParentAuthenticator {
    private let baseURL: URL
    private let sessionStore: any SessionStore
    private let transport: any HTTPTransport
    private let cache: any WalletSnapshotCache
    private let pendingStore: any PendingCommandStore
    private var current: WalletSnapshot
    private var pendingCommands: [String: WalletCommand]
    private var rejectedEvents: [WalletEvent] = []

    public init(
        baseURL: URL = APIConfiguration.productionBaseURL,
        sessionStore: (any SessionStore)? = nil,
        transport: any HTTPTransport = URLSessionTransport(),
        cache: (any WalletSnapshotCache)? = nil,
        pendingStore: (any PendingCommandStore)? = nil
    ) {
        self.baseURL = baseURL
        self.sessionStore = sessionStore ?? KeychainSessionStore()
        self.transport = transport
        self.cache = cache ?? UserDefaultsWalletSnapshotCache()
        self.pendingStore = pendingStore ?? (baseURL == APIConfiguration.productionBaseURL ? UserDefaultsPendingCommandStore() : InMemoryPendingCommandStore())
        self.current = self.cache.load() ?? .empty()
        self.pendingCommands = Dictionary(uniqueKeysWithValues: self.pendingStore.load().map { ($0.idempotencyKey, $0) })
    }

    public var isAuthenticated: Bool { sessionStore.session?.isExpired == false }

    public func snapshot() -> WalletSnapshot {
        snapshotWithPending()
    }

    public func authenticateApple(identityToken: String, nonce: String) async throws -> AuthSession {
        guard !identityToken.isEmpty, !nonce.isEmpty else {
            throw WalletAPIError.invalidResponse("Apple Sign In did not return the required identity proof.")
        }
        let body: [String: Any] = ["identityToken": identityToken, "nonce": nonce]
        let data = try await request(path: "/v1/auth/apple", method: "POST", body: body, authenticated: false, idempotencyKey: nil)
        let response = try decode(AuthResponseDTO.self, from: data)
        guard !response.token.isEmpty, let expiresAt = parseTimestamp(response.expiresAt), expiresAt > .now else {
            throw WalletAPIError.invalidResponse("The authentication service returned an invalid session.")
        }
        let session = AuthSession(token: response.token, expiresAt: expiresAt)
        do {
            try sessionStore.save(session)
        } catch {
            throw WalletAPIError.invalidResponse("The parent session could not be stored securely.")
        }
        return session
    }

    public func refresh(for role: UserRole) async throws -> WalletSnapshot {
        guard isAuthenticated else { throw WalletAPIError.noSession }
        try await flushPendingCommands()
        do {
            let path = role == .child ? "/v1/child-view" : "/v1/wallet"
            let data = try await request(path: path, method: "GET", body: nil, authenticated: true, idempotencyKey: nil)
            let response = try decode(SnapshotDTO.self, from: data)
            if role == .child && response.readOnly != true {
                throw WalletAPIError.invalidResponse("The child wallet response was not marked read-only.")
            }
            current = try mapSnapshot(response)
            current.isStale = false
            cache.save(current)
            return snapshotWithPending()
        } catch let error as WalletAPIError {
            switch error {
            case .network, .invalidResponse:
                current.isStale = true
                cache.save(current)
            default:
                break
            }
            throw error
        }
    }

    public func activity(limit: Int = 50) async throws -> [WalletEvent] {
        guard (1...100).contains(limit) else {
            throw WalletAPIError.invalidResponse("Activity limit must be between 1 and 100.")
        }
        let data = try await request(path: "/v1/activity?limit=\(limit)", method: "GET", body: nil, authenticated: true, idempotencyKey: nil)
        let response = try decode(ActivityListDTO.self, from: data)
        guard response.virtualNotice == WalletVocabulary.virtualNotice else {
            throw WalletAPIError.invalidResponse("The activity response did not contain the virtual-money notice.")
        }
        return try response.entries.map { try mapEntry($0, expected: nil) }
    }

    public func activityDetail(remoteID: String) async throws -> WalletEvent {
        let data = try await request(path: "/v1/activity/\(pathComponent(remoteID))", method: "GET", body: nil, authenticated: true, idempotencyKey: nil)
        let response = try decode(ActivityDetailDTO.self, from: data)
        guard response.virtualNotice == WalletVocabulary.virtualNotice else {
            throw WalletAPIError.invalidResponse("The activity detail did not contain the virtual-money notice.")
        }
        return try mapEntry(response.entry, expected: nil)
    }

    public func loanDetail(remoteID: String) async throws -> LoanDetail {
        let data = try await request(path: "/v1/loans/\(pathComponent(remoteID))", method: "GET", body: nil, authenticated: true, idempotencyKey: nil)
        let response = try decode(LoanDetailDTO.self, from: data)
        guard response.virtualNotice == WalletVocabulary.virtualNotice else {
            throw WalletAPIError.invalidResponse("The loan detail did not contain the virtual-money notice.")
        }
        return LoanDetail(loan: try mapLoan(response.loan), entries: try response.repaymentsAndLoanEntry.map { try mapEntry($0, expected: nil) })
    }

    public func setup(_ setup: ParentSetup) async throws -> WalletSnapshot {
        var body: [String: Any] = [
            "nickname": setup.nickname,
            "lessonAgeBand": setup.lessonAgeBand
        ]
        if let familyName = setup.familyName { body["familyName"] = familyName }
        if let avatarURL = setup.avatarURL { body["avatarUrl"] = avatarURL.absoluteString }
        let data = try await request(path: "/v1/family/setup", method: "POST", body: body, authenticated: true, idempotencyKey: setup.idempotencyKey)
        let response = try decode(SnapshotDTO.self, from: data)
        current = try mapSnapshot(response)
        current.isStale = false
        cache.save(current)
        return snapshotWithPending()
    }

    public func setAllowance(_ command: AllowanceRuleCommand) async throws -> WalletSnapshot {
        var body: [String: Any] = [
            "amountCents": command.amountCents,
            "cadence": "weekly",
            "weekday": command.weekday,
            "startDate": formatDate(command.startDate)
        ]
        if let endDate = command.endDate { body["endDate"] = formatDate(endDate) }
        let data = try await request(path: "/v1/allowance-rule", method: "PUT", body: body, authenticated: true, idempotencyKey: command.idempotencyKey)
        let response = try decode(SnapshotDTO.self, from: data)
        current = try mapSnapshot(response)
        current.isStale = false
        cache.save(current)
        return snapshotWithPending()
    }

    public func submit(_ command: WalletCommand) async throws -> CommandResult {
        guard isAuthenticated else { throw WalletAPIError.noSession }
        do {
            let result = try await sendCommand(command)
            pendingCommands.removeValue(forKey: command.idempotencyKey)
            savePendingCommands()
            return result
        } catch let error as WalletAPIError {
            switch error {
            case .unauthorized, .noSession:
                throw error
            case let .server(statusCode, _, message) where (400..<500).contains(statusCode):
                pendingCommands.removeValue(forKey: command.idempotencyKey)
                savePendingCommands()
                let event = makeLocalEvent(for: command, state: .rejected, message: message, rejectionReason: message)
                rejectedEvents.insert(event, at: 0)
                return .rejected(event)
            case .cancelled, .timedOut, .familyNotSetup, .identityMismatch:
                throw error
            case .server, .network, .invalidResponse, .invalidConfiguration:
                pendingCommands[command.idempotencyKey] = command
                savePendingCommands()
                return .pending(makeLocalEvent(for: command, state: .pending, message: "This parent action is waiting to sync. It is not included in the accepted balance."))
            }
        }
    }

    public func clearSession() {
        sessionStore.clear()
        pendingCommands.removeAll()
        rejectedEvents.removeAll()
        pendingStore.clear()
        current = .empty()
        cache.clear()
    }

    private func flushPendingCommands() async throws {
        guard !pendingCommands.isEmpty else { return }
        for command in Array(pendingCommands.values) {
            do {
                _ = try await sendCommand(command)
                pendingCommands.removeValue(forKey: command.idempotencyKey)
                savePendingCommands()
            } catch let error as WalletAPIError {
                switch error {
                case .unauthorized, .noSession:
                    throw error
                case let .server(statusCode, _, message) where (400..<500).contains(statusCode):
                    pendingCommands.removeValue(forKey: command.idempotencyKey)
                    rejectedEvents.insert(makeLocalEvent(for: command, state: .rejected, message: message, rejectionReason: message), at: 0)
                    savePendingCommands()
                default:
                    continue
                }
            }
        }
    }

    private func pathComponent(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? value
    }

    private func optionalBody(_ required: [String: Any], reason: String?) -> [String: Any] {
        var body = required
        if let reason { body["reason"] = reason }
        return body
    }

    private func sendCommand(_ command: WalletCommand) async throws -> CommandResult {
        let endpoint: (path: String, body: [String: Any])
        switch command.kind {
        case .deposit:
            endpoint = ("/v1/wallet/deposits", optionalBody(["amountCents": command.amountCents], reason: command.reason))
        case .withdrawal:
            endpoint = ("/v1/wallet/withdrawals", optionalBody(["amountCents": command.amountCents], reason: command.reason))
        case .loan:
            var loanBody: [String: Any] = ["principalCents": command.amountCents]
            if let purpose = command.reason { loanBody["purpose"] = purpose }
            if let dueDate = command.dueDate { loanBody["dueDate"] = formatDate(dueDate) }
            endpoint = ("/v1/loans", loanBody)
        case .repayment:
            guard let loanID = current.loan?.remoteID else {
                throw WalletAPIError.server(statusCode: 409, code: "LOAN_NOT_FOUND", message: "There is no open loan to repay.")
            }
            endpoint = ("/v1/loans/\(loanID)/repayments", optionalBody(["amountCents": command.amountCents], reason: command.reason))
        case .allowance:
            guard let allowance = current.allowance,
                  let ruleID = allowance.remoteID,
                  let occurrenceID = allowance.nextOccurrenceID else {
                throw WalletAPIError.server(statusCode: 409, code: "ALLOWANCE_NOT_SCHEDULED", message: "There is no scheduled allowance occurrence to record.")
            }
            endpoint = ("/v1/allowance-rule/\(ruleID)/occurrences/\(occurrenceID)/record", optionalBody([:], reason: command.reason))
        }

        let data = try await request(path: endpoint.path, method: "POST", body: endpoint.body, authenticated: true, idempotencyKey: command.idempotencyKey)
        let response = try decode(CommandDTO.self, from: data)
        let event = try mapEntry(response.entry, expected: command.kind)
        guard response.wallet.balanceCents.value >= 0,
              response.wallet.virtualNotice == WalletVocabulary.virtualNotice else {
            throw WalletAPIError.invalidResponse("The command response did not contain an authoritative virtual wallet.")
        }
        current.acceptedBalanceCents = response.wallet.balanceCents.value
        current.activities.removeAll { $0.remoteID == response.entry.id }
        current.activities.insert(event, at: 0)
        if let loan = response.loan {
            current.loan = try mapLoan(loan)
        } else if command.kind == .loan || command.kind == .repayment {
            throw WalletAPIError.invalidResponse("The command response did not contain the updated loan.")
        }
        current.lastUpdated = event.date
        current.isStale = false
        cache.save(current)
        return .accepted(event)
    }

    private func request(
        path: String,
        method: String,
        body: [String: Any]?,
        authenticated: Bool,
        idempotencyKey: String?
    ) async throws -> Data {
        guard let url = URL(string: path, relativeTo: baseURL), url.scheme == "https" || baseURL.scheme == "http" else {
            throw WalletAPIError.invalidConfiguration
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            guard JSONSerialization.isValidJSONObject(body), let data = try? JSONSerialization.data(withJSONObject: body) else {
                throw WalletAPIError.invalidResponse("The request could not be encoded.")
            }
            request.httpBody = data
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let idempotencyKey {
            request.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key")
        }
        if authenticated {
            guard let session = sessionStore.session, !session.isExpired else {
                sessionStore.clear()
                throw WalletAPIError.unauthorized
            }
            request.setValue("Bearer \(session.token)", forHTTPHeaderField: "Authorization")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport.data(for: request)
        } catch {
            throw WalletAPIError.network("The network is unavailable. The accepted balance was not changed.")
        }
        guard let http = response as? HTTPURLResponse else {
            throw WalletAPIError.invalidResponse("The server returned an invalid HTTP response.")
        }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 {
                sessionStore.clear()
                throw WalletAPIError.unauthorized
            }
            if let envelope = try? JSONDecoder().decode(ErrorEnvelope.self, from: data) {
                if envelope.error.code == "FAMILY_NOT_SETUP" { throw WalletAPIError.familyNotSetup }
                throw WalletAPIError.server(statusCode: http.statusCode, code: envelope.error.code, message: envelope.error.message)
            }
            throw WalletAPIError.server(statusCode: http.statusCode, code: "HTTP_\(http.statusCode)", message: "The server did not accept this request.")
        }
        return data
    }

    private func mapSnapshot(_ response: SnapshotDTO) throws -> WalletSnapshot {
        guard response.wallet.balanceCents.value >= 0,
              response.wallet.virtualNotice == WalletVocabulary.virtualNotice else {
            throw WalletAPIError.invalidResponse("The server returned an invalid virtual wallet.")
        }
        let activities = try response.recentActivity.map { try mapEntry($0, expected: nil) }
        let latest = activities.map(\.date).max() ?? .now
        return WalletSnapshot(
            acceptedBalanceCents: response.wallet.balanceCents.value,
            activities: activities,
            loan: try response.loan.map(mapLoan),
            allowance: try response.allowanceRule.map(mapAllowance),
            pendingEvents: pendingEvents,
            lastUpdated: latest,
            isStale: false,
            childNickname: ChildProfileCopy.configuredNickname(from: response.child?.nickname)
        )
    }

    private func mapEntry(_ entry: EntryDTO, expected: WalletCommandKind?) throws -> WalletEvent {
        guard let type = activityType(entry.type), entry.amountCents.value > 0,
              let date = parseTimestamp(entry.recordedAt), !entry.id.isEmpty else {
            throw WalletAPIError.invalidResponse("The server returned an invalid activity entry.")
        }
        if let expected, commandKind(for: type) != expected {
            throw WalletAPIError.invalidResponse("The server returned the wrong activity type.")
        }
        let expectedDirection = type == .withdrawal || type == .repayment ? "debit" : "credit"
        guard entry.direction == expectedDirection else {
            throw WalletAPIError.invalidResponse("The server returned an invalid activity direction.")
        }
        let amount = Money(cents: entry.amountCents.value).display
        let explanation: String
        switch type {
        case .allowance: explanation = "Your parent added \(amount) virtual dollars as your allowance."
        case .deposit: explanation = "Your parent added \(amount) virtual dollars to your wallet."
        case .withdrawal: explanation = "Your parent recorded that \(amount) virtual dollars were used."
        case .loan: explanation = "Your parent gave you \(amount) virtual dollars to use now and give back over time."
        case .repayment: explanation = "Your parent recorded \(amount) virtual dollars returned toward the loan."
        }
        return WalletEvent(
            id: UUID(uuidString: entry.id) ?? UUID(),
            remoteID: entry.id,
            type: type,
            amountCents: entry.amountCents.value,
            balanceBeforeCents: entry.balanceBeforeCents?.value,
            balanceAfterCents: entry.balanceAfterCents?.value,
            reason: entry.reason,
            date: date,
            syncState: .recorded,
            explanation: explanation
        )
    }

    private func mapLoan(_ loan: LoanDTO) throws -> Loan {
        guard loan.principalCents.value > 0,
              loan.outstandingCents.value >= 0,
              loan.outstandingCents.value <= loan.principalCents.value,
              loan.status == "open" || loan.status == "paid",
              let createdAt = parseTimestamp(loan.createdAt) else {
            throw WalletAPIError.invalidResponse("The server returned an invalid loan.")
        }
        _ = createdAt
        return Loan(
            remoteID: loan.id,
            originalCents: loan.principalCents.value,
            remainingCents: loan.outstandingCents.value,
            purpose: loan.purpose,
            dueDate: parseDate(loan.dueDate)
        )
    }

    private func mapAllowance(_ allowance: AllowanceDTO) throws -> AllowancePlan {
        guard allowance.amountCents.value > 0,
              allowance.cadence == "weekly",
              (0...6).contains(allowance.weekday),
              let nextDate = parseDate(allowance.nextDueDate ?? allowance.startDate) else {
            throw WalletAPIError.invalidResponse("The server returned an invalid allowance rule.")
        }
        return AllowancePlan(
            remoteID: allowance.id,
            amountCents: allowance.amountCents.value,
            cadence: "every week",
            weekday: allowance.weekday,
            nextDate: nextDate,
            endDate: parseDate(allowance.endDate),
            nextOccurrenceID: allowance.nextOccurrenceId,
            syncState: allowance.active ? .recorded : .rejected
        )
    }

    private func savePendingCommands() {
        pendingStore.save(Array(pendingCommands.values))
    }

    private var pendingEvents: [WalletEvent] {
        pendingCommands.values.map { command in
            makeLocalEvent(for: command, state: .pending, message: "This parent action is waiting to sync. It is not included in the accepted balance.")
        }
    }

    private func snapshotWithPending() -> WalletSnapshot {
        var result = current
        result.pendingEvents = pendingEvents + rejectedEvents
        return result
    }

    private func makeLocalEvent(for command: WalletCommand, state: SyncState, message: String, rejectionReason: String? = nil) -> WalletEvent {
        let type: ActivityType = switch command.kind {
        case .allowance: .allowance
        case .deposit: .deposit
        case .withdrawal: .withdrawal
        case .loan: .loan
        case .repayment: .repayment
        }
        return WalletEvent(
            id: UUID(uuidString: command.idempotencyKey) ?? UUID(),
            remoteID: command.idempotencyKey,
            type: type,
            amountCents: max(command.amountCents, 0),
            reason: command.reason,
            syncState: state,
            explanation: message,
            rejectionReason: rejectionReason
        )
    }

    private func activityType(_ value: String) -> ActivityType? {
        ActivityType(rawValue: value)
    }

    private func commandKind(for type: ActivityType) -> WalletCommandKind {
        switch type {
        case .allowance: .allowance
        case .deposit: .deposit
        case .withdrawal: .withdrawal
        case .loan: .loan
        case .repayment: .repayment
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch let error as WalletAPIError {
            throw error
        } catch {
            throw WalletAPIError.invalidResponse("The server response could not be read.")
        }
    }

    private func parseTimestamp(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }

    private func parseDate(_ string: String?) -> Date? {
        guard let string else { return nil }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: string)
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

public enum AppleNonce {
    public static func randomString(byteCount: Int = 32) throws -> String {
        guard byteCount > 0 else { throw WalletAPIError.invalidResponse("Secure random generation failed.") }
        var data = Data(count: byteCount)
        let status = data.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, byteCount, buffer.baseAddress!)
        }
        guard status == errSecSuccess else { throw WalletAPIError.invalidResponse("Secure random generation failed.") }
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func sha256(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
