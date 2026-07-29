import Foundation

/// Exactly one accepted repository owns a wallet lineage at a time. These
/// states are deliberately separate from parent identity and StoreKit UI.
public enum WalletAuthorityState: Equatable, Sendable {
    case unconfigured
    case authenticatingParent
    case localSetup
    case local(lineageID: UUID)
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
        if case .local = self { return true }
        return false
    }
}

public enum PurchaseAttemptState: Equatable, Sendable {
    case idle
    case productsUnavailable
    case purchasing(productID: String)
    case pending
    case cancelled
    case clientUnverified
    case serverVerifying
    case serverPending
    case serverRejected(correlationID: String?)
    case verifiedPaid
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
}

public enum CloudProductID {
    public static let monthly = "com.kunchenguid.eddieswallet.cloud.monthly"
    public static let annual = "com.kunchenguid.eddieswallet.cloud.annual"
    public static let all: Set<String> = [monthly, annual]
}

public struct CloudCapabilities: Codable, Equatable, Sendable {
    public let cloudActivationAvailable: Bool
    public let productIDs: [String]

    public init(cloudActivationAvailable: Bool, productIDs: [String]) {
        self.cloudActivationAvailable = cloudActivationAvailable
        self.productIDs = productIDs
    }

    public var hasExactProducts: Bool { Set(productIDs) == CloudProductID.all }
}

public struct CloudContext: Codable, Equatable, Sendable {
    public let storeAccountToken: UUID?
    public let entitlement: CloudEntitlementStateDTO
    public let lineageID: UUID?
    public let revision: Int64?
    public let authority: String?

    public init(storeAccountToken: UUID?, entitlement: CloudEntitlementStateDTO, lineageID: UUID?, revision: Int64?, authority: String?) {
        self.storeAccountToken = storeAccountToken
        self.entitlement = entitlement
        self.lineageID = lineageID
        self.revision = revision
        self.authority = authority
    }
}

/// Wire representation is intentionally public-contract vocabulary only.
public struct CloudEntitlementStateDTO: Codable, Equatable, Sendable {
    public let state: String
    public let accessUntil: Date?
    public let autoRenewEnabled: Bool?

    public init(state: String, accessUntil: Date? = nil, autoRenewEnabled: Bool? = nil) {
        self.state = state
        self.accessUntil = accessUntil
        self.autoRenewEnabled = autoRenewEnabled
    }

    public var clientState: CloudEntitlementState {
        switch state {
        case "active": return .active(accessUntil: accessUntil ?? .distantPast, autoRenewEnabled: autoRenewEnabled ?? true)
        case "billing_grace": return .billingGrace(accessUntil: accessUntil ?? .distantPast)
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
