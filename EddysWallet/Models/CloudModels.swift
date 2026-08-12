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

/// Why a Cloud device may not start a protected parent write right now.
///
/// Each case is a distinct fact about this device, and each one carries the
/// parent-facing reason and the label of the control that clears it, so a block
/// can never reach a parent as an unattributed "something is wrong" with no way
/// out. Presenting all of them as one generic reconnect-and-review line is what
/// made a genuinely pending review indistinguishable from an unconfirmed
/// revision in 0.1.14 - and left the parent hunting for a "Got it" that was
/// only ever shown for the review case.
public enum ParentMutationBlock: Equatable, Sendable, CaseIterable {
    /// A refused request whose local cleanup has not finished on this device.
    case rejectedCleanup
    /// A request this device sent has no settled outcome yet.
    case unsettledMutation
    /// This device holds no usable Cloud replica.
    case replicaUnavailable
    /// The Cloud plan is not active, so this device may not write to Cloud.
    case planInactive
    /// The newest read did not reach the Cloud authority.
    case authorityUnreached
    /// The wallet moved on elsewhere and the parent has not looked yet.
    case awaitingReview
    /// No successful read has confirmed this device's replica revision yet.
    case revisionUnconfirmed

    /// What the parent is told, in the terms of the guard that is holding.
    public func message(deviceNoun: String) -> String {
        switch self {
        case .rejectedCleanup:
            "This change was not recorded. Finish local cleanup before recording another action."
        case .unsettledMutation:
            "Cloud has not confirmed this \(deviceNoun)'s last change yet. Check again before recording another one."
        case .replicaUnavailable:
            "This \(deviceNoun) does not have the Cloud wallet yet. Reconnect to get it before recording a change."
        case .planInactive:
            "The Cloud plan is not active, so this \(deviceNoun) cannot record changes to the Cloud wallet."
        case .awaitingReview:
            "This wallet changed somewhere else. Review the latest balance before recording another change."
        case .authorityUnreached:
            "This \(deviceNoun) has not reached Cloud. Reconnect before recording another change."
        case .revisionUnconfirmed:
            "This \(deviceNoun) has not confirmed the latest Cloud wallet yet. Refresh before recording another change."
        }
    }

    /// What pressing the block's own control does.
    public enum Recovery: Equatable, Sendable {
        /// Read the latest wallet. An outstanding review ends only after a
        /// post-boundary repository-accepted read is published.
        case readLatest
        /// The one block no read can lift. The way out is the Cloud plan
        /// surface further down the same screen, so the control goes there.
        case cloudPlan
    }

    /// Every case has a recovery: a blocked parent must always have something
    /// to press, on the block itself.
    public var recovery: Recovery { self == .planInactive ? .cloudPlan : .readLatest }

    /// The label of the control shown on the block itself.
    public var recoveryActionTitle: String {
        switch self {
        case .rejectedCleanup: "Finish local cleanup"
        case .unsettledMutation: "Check again"
        case .awaitingReview: "Review latest"
        case .planInactive: "See Cloud plan"
        case .replicaUnavailable, .authorityUnreached, .revisionUnconfirmed: "Refresh now"
        }
    }
}

/// Why Cloud plans cannot be offered right now, at the granularity the parent
/// copy branches on. The finer per-step outcome classes live in
/// `CloudRecoveryEvidence`; this only separates a deliberate service answer
/// from a failed check, so the card never presents a stable policy state as a
/// passing outage or the other way around.
public enum CloudPlansUnavailableReason: Equatable, Sendable {
    /// The service answered: Cloud is not offered for this account right now.
    case notOffered
    /// The availability check itself failed - the service answer or the App
    /// Store product query was unreadable, absent, or wrong - so whether Cloud
    /// could be offered is unknown. A retry may succeed.
    case couldNotCheck
}

public enum PurchaseAttemptState: Equatable, Sendable {
    case idle
    case productsUnavailable(CloudPlansUnavailableReason)
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

    public var requiresAccountDeletionBillingAcknowledgement: Bool {
        switch self {
        case .active(_, autoRenewEnabled: false), .none, .expired, .refunded, .revoked:
            false
        case .active(_, autoRenewEnabled: true), .billingGrace, .billingRetry, .verificationPending:
            true
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

/// What first-run discovery found for the exact signed-in parent. Anything the
/// client cannot read as one of the three known authorities is `unusable`, so a
/// malformed answer never offers or adopts a wallet.
public enum CloudExistingWalletDiscovery: Equatable, Sendable {
    /// This parent has no server-held household; ordinary local-first setup.
    case noHousehold
    /// A pre-Cloud service household that a consented transition can recover.
    case legacyHousehold(lineageID: UUID, revision: Int64, entitlementActive: Bool)
    /// Already Cloud-authoritative: adopt through context and bootstrap, never
    /// through the legacy transition.
    case cloudHousehold(lineageID: UUID, revision: Int64)
    /// Deliberately moved to a device's local authority. Server recovery is
    /// not offered.
    case detachedHousehold
    /// A household this client cannot read: an unknown authority or a missing
    /// lineage. It is never offered and never adopted.
    case unusable

    /// Only a legacy household under an active entitlement may be offered.
    public var offer: CloudExistingWalletOffer? {
        guard case .legacyHousehold(let lineageID, let revision, let entitlementActive) = self else { return nil }
        return CloudExistingWalletOffer(
            lineageID: lineageID,
            revision: revision,
            entitlementActive: entitlementActive
        )
    }
}

/// The exact server-held wallet a parent may accept on this device, pinned to
/// the revision discovery reported so the transition guards on it.
public struct CloudExistingWalletOffer: Equatable, Sendable {
    public let lineageID: UUID
    public let revision: Int64
    public let entitlementActive: Bool

    public init(lineageID: UUID, revision: Int64, entitlementActive: Bool) {
        self.lineageID = lineageID
        self.revision = revision
        self.entitlementActive = entitlementActive
    }
}

/// Typed outcomes of the settled legacy-to-Cloud transition. Each one is a
/// definite server answer, so the client never loops or invents success.
public enum CloudLegacyActivationRefusal: Equatable, Sendable {
    /// No active entitlement. Purchase or restore, then retry the same action.
    case entitlementRequired
    /// Activation policy or StoreKit readiness is closed for this parent.
    case activationUnavailable
    /// Emergency write stop. The same action may be retried later.
    case serviceReadOnly
    /// Discovery was stale: this parent has no household after all.
    case householdMissing
    /// The household moved on while still legacy. Discovery must run again
    /// before a new acceptance.
    case revisionChanged(currentRevision: Int64)
    /// The household is detached; server recovery is unavailable.
    case householdDetached
    /// The key was already used for a different request; a new acceptance
    /// needs a new key.
    case idempotencyKeyReused
    /// The same command is still running. Retrying the same key is safe.
    case commandInProgress
    /// `If-Match` was missing, which this client always sends.
    case revisionRequired
    /// The service session is not usable; discovery must be repeated.
    case authenticationRequired
    /// The service could not be reached or answered unreadably. The accepted
    /// action may be retried with the same key.
    case unreachable

    /// Whether the exact same accepted action may be sent again unchanged.
    /// Refusals roll back completely, so key reuse is safe for these.
    public var permitsSameActionRetry: Bool {
        switch self {
        case .entitlementRequired, .serviceReadOnly, .commandInProgress, .revisionRequired, .unreachable: true
        case .activationUnavailable, .householdMissing, .revisionChanged, .householdDetached,
             .idempotencyKeyReused, .authenticationRequired: false
        }
    }

    /// Whether a retry has to start from a fresh discovery and a fresh key.
    public var requiresFreshDiscovery: Bool {
        switch self {
        case .revisionChanged, .idempotencyKeyReused, .authenticationRequired: true
        default: false
        }
    }

    /// Parent-facing explanation. Truthful about what did and did not happen:
    /// a refused transition changes nothing on the server.
    public var parentMessage: String {
        switch self {
        case .entitlementRequired:
            "Your Cloud subscription is not active right now, so this wallet was not moved. Nothing changed."
        case .activationUnavailable:
            "Cloud cannot take on this wallet yet. Nothing changed, and your wallet is still saved to your account."
        case .serviceReadOnly:
            "Cloud is not accepting changes right now. Nothing changed - try again in a little while."
        case .householdMissing:
            "There is no longer a wallet saved to this Apple account."
        case .revisionChanged:
            "This wallet changed somewhere else. Check for it again before moving it."
        case .householdDetached:
            "This wallet was moved to another device and can only be used there."
        case .idempotencyKeyReused, .authenticationRequired:
            "This device could not confirm the move. Check for your wallet again."
        case .commandInProgress:
            "This wallet is still being moved. Try again in a moment."
        case .revisionRequired:
            "Cloud needs the latest version of this wallet. Nothing changed - try again."
        case .unreachable:
            "Cloud could not be reached, so this wallet was not moved. Nothing changed."
        }
    }
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
    /// The service's own answer to "does this parent have Cloud access right
    /// now". Absent on older responses, where the mapped state stands in.
    public let active: Bool?

    public init(
        state: String,
        accessUntil: Date? = nil,
        graceExpiresAt: Date? = nil,
        autoRenewEnabled: Bool? = nil,
        active: Bool? = nil
    ) {
        self.state = state
        self.accessUntil = accessUntil
        self.graceExpiresAt = graceExpiresAt
        self.autoRenewEnabled = autoRenewEnabled
        self.active = active
    }

    /// Whether a paid transition may be offered. The service's `active` flag
    /// wins; without it the client falls back to the mapped state and never
    /// invents access.
    public var grantsCloud: Bool { active ?? clientState.grantsCloud }

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
