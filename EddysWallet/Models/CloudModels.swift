import Foundation

/// Exactly one accepted repository owns a wallet lineage at a time. These
/// states are deliberately separate from parent identity and StoreKit UI.
public enum WalletAuthorityState: Equatable, Sendable {
    case unconfigured
    case authenticatingParent
    case localSetup
    case local(lineageID: UUID)
    case localRecovery(WalletRecoveryState)
    case legacyService
    case transitioningToCloud
    case transitioningToLocal
    case cloud(lineageID: UUID, revision: Int64)
    case cloudOffline(lineageID: UUID, revision: Int64)
    case cloudOfflineGrace(lineageID: UUID, revision: Int64)

    public var isConfigured: Bool {
        switch self {
        case .unconfigured, .authenticatingParent, .localSetup: false
        default: true
        }
    }

    public var isLocalAuthority: Bool {
        switch self {
        case .local, .localRecovery: true
        default: false
        }
    }

    public var isCloudAuthority: Bool {
        switch self {
        case .cloud, .cloudOffline, .cloudOfflineGrace: true
        default: false
        }
    }

    public var lineageID: UUID? {
        switch self {
        case .local(let lineageID): lineageID
        case .cloud(let lineageID, _), .cloudOffline(let lineageID, _), .cloudOfflineGrace(let lineageID, _): lineageID
        default: nil
        }
    }

    public var revision: Int64? {
        switch self {
        case .cloud(_, let revision), .cloudOffline(_, let revision), .cloudOfflineGrace(_, let revision): revision
        default: nil
        }
    }
}

public enum WalletRecoveryState: Equatable, Sendable {
    case historyUnavailable
    case storageUnavailable
}

public enum PurchaseAttemptState: Equatable, Sendable {
    case idle
    case productsUnavailable
    case purchasing(productID: String)
    case pending
    case cancelled
    case clientUnverified
    case storeClientError
    case serverVerifying
    case serverPending
    case serverRejected(correlationID: String?)
    case verifiedPaid
    /// A verified transaction was delivered, but the backend projection does
    /// not grant Cloud (expired, refunded, revoked, or billing retry). Always
    /// rendered as that real state, never as a generic server rejection.
    case entitlementNotActive(CloudEntitlementState)
    case activationConflict
}

public enum CloudEntitlementState: Equatable, Sendable {
    case none
    case verificationPending
    case active(accessUntil: Date, autoRenewEnabled: Bool)
    case billingGrace(accessUntil: Date)
    case billingRetry
    case expired
    case refunded
    case revoked

    /// Whether the backend's projection currently grants Cloud. The client
    /// never derives this from StoreKit state.
    public var grantsCloud: Bool {
        switch self {
        case .active, .billingGrace: true
        default: false
        }
    }

    public var permitsLocalContinuation: Bool {
        switch self {
        case .billingRetry, .expired, .refunded, .revoked: true
        default: false
        }
    }
}

public enum CloudProductID {
    public static let monthly = "com.kunchenguid.eddieswallet.cloud.monthly"
    public static let annual = "com.kunchenguid.eddieswallet.cloud.annual"
    public static let all: Set<String> = [monthly, annual]
    /// Stable presentation order: monthly first, then annual.
    public static let ordered: [String] = [monthly, annual]
}

/// `GET /v1/capabilities`. The server publishes the eligible product ids under
/// `products`; unknown or future fields are ignored.
public struct CloudCapabilities: Codable, Equatable, Sendable {
    public let cloudActivationAvailable: Bool
    public let cloudServiceAvailable: Bool?
    public let productIDs: [String]

    private enum CodingKeys: String, CodingKey {
        case cloudActivationAvailable
        case cloudServiceAvailable
        case productIDs = "products"
    }

    public init(cloudActivationAvailable: Bool, cloudServiceAvailable: Bool? = nil, productIDs: [String]) {
        self.cloudActivationAvailable = cloudActivationAvailable
        self.cloudServiceAvailable = cloudServiceAvailable
        self.productIDs = productIDs
    }

    public var hasExactProducts: Bool { Set(productIDs) == CloudProductID.all }
    /// Cloud may only be offered when the server says activation is available
    /// and it publishes exactly the two known products.
    public var canOfferCloud: Bool { cloudActivationAvailable && hasExactProducts }
}

/// Server household authority. An unknown or malformed value is never treated
/// as Cloud, so a bad response can never establish Cloud authority.
public enum CloudAuthorityMode: String, Codable, Equatable, Sendable {
    case legacyService = "legacy_service"
    case cloud
    case localDetached = "local_detached"
    case unknown

    public init(rawValue: String) {
        switch rawValue {
        case "legacy_service": self = .legacyService
        case "cloud": self = .cloud
        case "local_detached": self = .localDetached
        default: self = .unknown
        }
    }
}

/// `household` object shared by context, bootstrap, changes, import, detach and
/// activate. Server casing is `lineageId`.
public struct CloudHousehold: Codable, Equatable, Sendable {
    public let lineageID: UUID?
    public let authority: CloudAuthorityMode
    public let revision: Int64

    private enum CodingKeys: String, CodingKey {
        case lineageID = "lineageId"
        case authority
        case revision
    }

    public init(lineageID: UUID?, authority: CloudAuthorityMode, revision: Int64) {
        self.lineageID = lineageID
        self.authority = authority
        self.revision = revision
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        lineageID = try container.decodeIfPresent(UUID.self, forKey: .lineageID)
        authority = CloudAuthorityMode(rawValue: try container.decodeIfPresent(String.self, forKey: .authority) ?? "")
        revision = try container.decodeIfPresent(Int64.self, forKey: .revision) ?? 0
    }

    /// Cloud authority requires a real Cloud household with a usable lineage.
    public var isCloudAuthoritative: Bool { authority == .cloud && lineageID != nil }
}

public struct CloudCapabilityFlags: Codable, Equatable, Sendable {
    public let newActivationsEnabled: Bool?
    public let serviceMode: String?

    public init(newActivationsEnabled: Bool?, serviceMode: String?) {
        self.newActivationsEnabled = newActivationsEnabled
        self.serviceMode = serviceMode
    }
}

/// `GET /v1/cloud/context` and the verified `POST /v1/cloud/transactions`
/// response. `entitlement` and `household` are absent before a purchase or
/// before a household exists, so both are optional here.
public struct CloudContext: Codable, Equatable, Sendable {
    public let storeAccountToken: UUID?
    public let entitlement: CloudEntitlementStateDTO?
    public let household: CloudHousehold?
    public let capability: CloudCapabilityFlags?

    public init(
        storeAccountToken: UUID?,
        entitlement: CloudEntitlementStateDTO?,
        household: CloudHousehold? = nil,
        capability: CloudCapabilityFlags? = nil
    ) {
        self.storeAccountToken = storeAccountToken
        self.entitlement = entitlement
        self.household = household
        self.capability = capability
    }

    /// Absent entitlement means no Cloud, never an implied grant.
    public var entitlementState: CloudEntitlementState { entitlement?.clientState ?? .none }
    public var lineageID: UUID? { household?.lineageID }
    public var revision: Int64? { household?.revision }
    public var authority: CloudAuthorityMode? { household?.authority }
}

/// Wire representation is intentionally public-contract vocabulary only.
public struct CloudEntitlementStateDTO: Codable, Equatable, Sendable {
    public let state: String
    public let accessUntil: Date?
    public let graceExpiresAt: Date?
    public let autoRenewEnabled: Bool?

    public init(state: String, accessUntil: Date? = nil, graceExpiresAt: Date? = nil, autoRenewEnabled: Bool? = nil) {
        self.state = state
        self.accessUntil = accessUntil
        self.graceExpiresAt = graceExpiresAt
        self.autoRenewEnabled = autoRenewEnabled
    }

    public var clientState: CloudEntitlementState {
        switch state {
        case "active": return .active(accessUntil: accessUntil ?? .distantPast, autoRenewEnabled: autoRenewEnabled ?? true)
        case "billing_grace": return .billingGrace(accessUntil: graceExpiresAt ?? accessUntil ?? .distantPast)
        case "verification_pending": return .verificationPending
        case "billing_retry": return .billingRetry
        case "expired": return .expired
        case "refunded": return .refunded
        case "revoked": return .revoked
        default: return .none
        }
    }
}

public struct CloudRevisionConflict: Equatable, Sendable {
    public let currentRevision: Int64
}

/// The one unresolved runtime mutation a Cloud device may retain. Keeping the
/// exact request bytes, revision, and idempotency key makes response loss safe:
/// reconciliation can only replay this request, never mint a replacement key.
enum CloudMutationKind: String, Codable, Equatable, Sendable {
    case deposit
    case withdrawal
    case loan
    case repayment
    case recordAllowance
    case setAllowance
    case childProfile

    var activityType: ActivityType? {
        switch self {
        case .deposit: .deposit
        case .withdrawal: .withdrawal
        case .loan: .loan
        case .repayment: .repayment
        case .recordAllowance: .allowance
        case .setAllowance, .childProfile: nil
        }
    }

    var isMoney: Bool { activityType != nil }
}

enum CloudMutationPhase: String, Codable, Equatable, Sendable {
    case staged
    /// The request was durably protected before its first transport attempt.
    case awaitingOutcome
    /// The service accepted it, but this device has not observed the accepted
    /// entry or revision in a replica yet.
    case acceptedAwaitingReplica
    case rejected
}

@MainActor
protocol CloudMutationStatusProviding {
    var hasUnsettledMutation: Bool { get }
    var unsettledMutationPhase: CloudMutationPhase? { get }
    var unsettledMutationMessage: String? { get }
}

struct PendingCloudMutation: Codable, Equatable, Sendable {
    let operationID: UUID
    let kind: CloudMutationKind
    let method: String
    let path: String
    let body: Data
    let idempotencyKey: String
    let expectedRevision: Int64
    let amountCents: Int?
    let reason: String?
    let createdAt: Date
    var phase: CloudMutationPhase
    var acceptedEntryID: String?
    var acceptedRevision: Int64?
    var rejectionStatusCode: Int?
    var rejectionCode: String?
    var rejectionMessage: String?

    init(
        kind: CloudMutationKind,
        method: String,
        path: String,
        body: Data,
        idempotencyKey: String,
        expectedRevision: Int64,
        amountCents: Int? = nil,
        reason: String? = nil,
        operationID: UUID = UUID(),
        createdAt: Date = .now
    ) {
        self.operationID = operationID
        self.kind = kind
        self.method = method
        self.path = path
        self.body = body
        self.idempotencyKey = idempotencyKey
        self.expectedRevision = expectedRevision
        self.amountCents = amountCents
        self.reason = reason
        self.createdAt = createdAt
        self.phase = .staged
        self.acceptedEntryID = nil
        self.acceptedRevision = nil
        self.rejectionStatusCode = nil
        self.rejectionCode = nil
        self.rejectionMessage = nil
    }

    var waitingMessage: String {
        switch phase {
        case .staged:
            "This change has not been sent. This device must finish protecting it before contacting Cloud."
        case .awaitingOutcome:
            "Cloud has not confirmed this change yet. This device will retry the same protected request. Do not record it again."
        case .acceptedAwaitingReplica:
            "Cloud accepted this change. This device is waiting to see it in the wallet. Do not record it again."
        case .rejected:
            rejectionMessage ?? "Cloud did not record this change."
        }
    }

    func pendingEvent() -> WalletEvent? {
        guard phase != .rejected else { return nil }
        guard let type = kind.activityType, let amountCents else { return nil }
        return WalletEvent(
            id: operationID,
            remoteID: "cloud-pending-\(operationID.uuidString.lowercased())",
            type: type,
            amountCents: amountCents,
            reason: reason,
            date: createdAt,
            syncState: .pending,
            explanation: waitingMessage
        )
    }

    func isObserved(in replica: CloudReplica, mappedSnapshot: WalletSnapshot) -> Bool {
        if let acceptedEntryID {
            return replica.entries.contains { $0.id == acceptedEntryID }
                && mappedSnapshot.activities.contains { $0.remoteID == acceptedEntryID }
        }
        guard let acceptedRevision, replica.household.revision >= acceptedRevision else { return false }
        if kind.isMoney {
            return replica.entries.filter { $0.acceptedRevision == acceptedRevision }.count == 1
        }
        return true
    }
}

struct CloudMutationAcceptance: Equatable, Sendable {
    let entryID: String?
    let revision: Int64?
}

// MARK: - Cloud replica payloads

/// The accepted Cloud aggregate returned by bootstrap and changes. Only fields
/// the client renders are decoded; unknown/future fields are ignored.
public struct CloudReplica: Codable, Equatable, Sendable {
    public struct Family: Codable, Equatable, Sendable {
        public let id: String?
        public let name: String?
    }

    public struct Child: Codable, Equatable, Sendable {
        public let id: String?
        public let nickname: String?
        public let avatarURL: String?

        private enum CodingKeys: String, CodingKey {
            case id, nickname
            case avatarURL = "avatarUrl"
        }
    }

    public struct Wallet: Codable, Equatable, Sendable {
        public let id: String?
        public let balanceCents: Int
    }

    public struct Entry: Codable, Equatable, Sendable {
        public let id: String
        public let type: String
        public let direction: String
        public let amountCents: Int
        public let balanceBeforeCents: Int?
        public let balanceAfterCents: Int?
        public let reason: String?
        public let loanID: String?
        public let recordedAt: Date
        public let acceptedRevision: Int64?

        private enum CodingKeys: String, CodingKey {
            case id, type, direction, amountCents, balanceBeforeCents, balanceAfterCents, reason, recordedAt, acceptedRevision
            case loanID = "loanId"
        }
    }

    public struct CloudLoan: Codable, Equatable, Sendable {
        public let id: String
        public let principalCents: Int
        public let outstandingCents: Int
        public let purpose: String?
        public let dueDate: String?
        public let status: String
        public let createdAt: Date
        public let paidAt: Date?
    }

    public struct AllowanceRule: Codable, Equatable, Sendable {
        public let id: String?
        public let amountCents: Int
        public let cadence: String?
        public let weekday: Int?
        public let startDate: String?
        public let endDate: String?
        public let active: Bool?
    }

    public let household: CloudHousehold
    public let family: Family?
    public let child: Child?
    public let wallet: Wallet?
    public let entries: [Entry]
    public let loans: [CloudLoan]
    public let allowanceRule: AllowanceRule?
    public let nextCursor: String?
}

public struct CloudAllowanceSchedule: Codable, Equatable, Sendable {
    public struct Rule: Codable, Equatable, Sendable {
        public let id: String
        public let amountCents: Int
        public let nextOccurrenceID: String?

        private enum CodingKeys: String, CodingKey {
            case id
            case amountCents
            case nextOccurrenceID = "nextOccurrenceId"
        }
    }

    public let allowanceRule: Rule?
}

// MARK: - Local-to-Cloud import manifest

/// The complete local household uploaded once when a paid parent activates
/// Cloud. Key order matches the server's accepted aggregate exactly so that
/// `aggregateSha256` is verifiable on both sides.
public struct CloudImportManifest: Equatable, Sendable {
    public struct Loan: Equatable, Sendable {
        public let id: UUID
        public let principalCents: Int
        public let outstandingCents: Int
        public let purpose: String?
        public let dueDate: String?
        public let status: String
        public let createdAt: Date
        public let paidAt: Date?
    }

    public struct Entry: Equatable, Sendable {
        public let operationID: UUID
        public let type: String
        public let direction: String
        public let amountCents: Int
        public let balanceBeforeCents: Int
        public let balanceAfterCents: Int
        public let reason: String?
        public let loanID: UUID?
        public let recordedAt: Date
    }

    public let lineageID: UUID
    public let operationID: UUID
    public let familyName: String
    public let nickname: String
    public let avatarURL: String?
    public let loans: [Loan]
    public let entries: [Entry]

    public init(
        lineageID: UUID,
        operationID: UUID,
        familyName: String,
        nickname: String,
        avatarURL: String? = nil,
        loans: [Loan],
        entries: [Entry]
    ) {
        self.lineageID = lineageID
        self.operationID = operationID
        self.familyName = familyName
        self.nickname = nickname
        self.avatarURL = avatarURL
        self.loans = loans
        self.entries = entries
    }
}

// MARK: - Parent-facing plan presentation

/// A purchasable Cloud plan, already localized by StoreKit. Views never touch
/// StoreKit types, and there is no hard-coded price anywhere in the app.
public struct CloudPlan: Identifiable, Equatable, Sendable {
    public let id: String
    public let displayName: String
    public let displayPrice: String
    public let periodDescription: String

    public init(id: String, displayName: String, displayPrice: String, periodDescription: String) {
        self.id = id
        self.displayName = displayName
        self.displayPrice = displayPrice
        self.periodDescription = periodDescription
    }
}

/// What signing out does, which differs by accepted authority.
public enum CloudSignOutMode: Equatable, Sendable {
    /// Local-only wallet: signing out erases this device's wallet.
    case localErase
    /// Cloud wallet: this device stops syncing, keeps the mirrored wallet, and
    /// deletes nothing.
    case cloudDevice
    /// Legacy service wallet: this removes the local view and parent PIN while
    /// the service keeps the wallet.
    case serviceDevice
}
