import Foundation

public enum UserRole: String, CaseIterable, Identifiable, Sendable {
    case parent
    case child

    public var id: String { rawValue }
    public var title: String { self == .parent ? "Parent" : "Child's view" }
}

/// Transient parent elevation over the kid-home root. Lives only in memory:
/// there is deliberately no code path that writes it to disk, so every cold
/// launch of a configured app rests on the kid home.
public enum ParentElevation: Equatable, Sendable {
    case none
    case gate
    case active
}

/// Why the parent gate is asking for a fresh Sign in with Apple instead of
/// (or before) the PIN pad.
public enum ParentReauthReason: Equatable, Sendable {
    case sessionExpired
    case forgotPIN
    case missingPIN
}

/// The screen the parent gate is currently showing.
public enum ParentGateRoute: Equatable, Sendable {
    case pinEntry
    case reauth(ParentReauthReason)
    case setPIN
}

/// External product identity. Use only on install/store surfaces and the one
/// intentional welcome/onboarding brand mention - never as recurring kid or
/// Parent-area chrome. Everyday titles come from `ChildProfileCopy`.
public enum ProductBrand {
    /// App Store / install / welcome wordmark. Not a child nickname.
    public static let displayName = "Eddie's Wallet"
}

/// Child- and family-centric copy derived from the configured nickname.
/// Daily main screens must use these helpers (or neutral fallbacks) instead of
/// `ProductBrand.displayName`, so a child not named Eddie never sees the
/// external brand as if it were their wallet. A real child named Eddie still
/// receives correct personal copy - that overlap with the brand string is
/// personal data, not a brand leak.
public enum ChildProfileCopy {
    public static func configuredNickname(from rawNickname: String?) -> String? {
        guard let nickname = rawNickname?.trimmingCharacters(in: .whitespacesAndNewlines), !nickname.isEmpty else {
            return nil
        }
        return nickname
    }

    public static func roleTitle(nickname: String?) -> String {
        guard let nickname = configuredNickname(from: nickname) else { return "Child's view" }
        return "\(nickname)'s view"
    }

    /// Kid-home header identity. Title-case "Wallet" when personal; neutral
    /// "Your wallet" when no nickname is configured.
    public static func walletTitle(nickname: String?) -> String {
        guard let nickname = configuredNickname(from: nickname) else { return "Your wallet" }
        return "\(nickname)'s Wallet"
    }

    public static func parentBalanceTitle(nickname: String?) -> String {
        guard let nickname = configuredNickname(from: nickname) else { return "Your child's virtual balance" }
        return "\(nickname)'s virtual balance"
    }

    /// Plain kid-home balance label. Intentionally not nickname-aware and not
    /// virtual/pretend-qualified - parents carry the financial boundary. The
    /// nickname argument is kept so call sites stay uniform with other titles.
    public static func childBalanceTitle(nickname _: String?) -> String {
        "Your allowance balance"
    }

    public static func childGreeting(nickname: String?) -> String {
        guard let nickname = configuredNickname(from: nickname) else { return "Your wallet" }
        return "Hi, \(nickname)"
    }

    public static func childReference(nickname: String?) -> String {
        configuredNickname(from: nickname) ?? "your child"
    }

    public static func childSubject(nickname: String?) -> String {
        configuredNickname(from: nickname) ?? "Your child"
    }

    /// Mid-sentence wallet reference (handoff buttons, review copy). Lowercase
    /// "wallet" so it reads as prose, not a brand wordmark.
    public static func walletReference(nickname: String?) -> String {
        guard let nickname = configuredNickname(from: nickname) else { return "your child's wallet" }
        return "\(nickname)'s wallet"
    }

    public static func readOnlyMessage(nickname: String?) -> String {
        guard let nickname = configuredNickname(from: nickname) else {
            return "The child view is read-only. This action was not recorded."
        }
        return "\(nickname)'s view is read-only. This action was not recorded."
    }
}

/// Kid-facing status copy for the kid home. Short sentences, no parent or
/// technical vocabulary ("accepted balance", "sync", "session") - PRD 11.
public enum KidCopy {
    public static func offlineBanner(lastUpdated: Date) -> String {
        "You're offline - this is what your wallet looked like at \(asOf(lastUpdated))."
    }

    /// Said only when this device has a connection but the wallet could not be
    /// reached. Telling a kid on working WiFi that they are offline is simply
    /// untrue, so the two never share wording.
    public static func cannotReachBanner(lastUpdated: Date) -> String {
        "Your wallet is hard to reach right now - this is what it looked like at \(asOf(lastUpdated))."
    }

    /// Said when the wallet answered but the newest read could not be used: a
    /// reply this app could not read, or a failure the service itself
    /// reported. The wallet was reached, so claiming any connection trouble
    /// would be as untrue as calling it offline.
    public static func couldNotUpdateBanner(lastUpdated: Date) -> String {
        "Your wallet couldn't update just now - this is what it looked like at \(asOf(lastUpdated))."
    }

    /// The one status line the kid home shows, in the order the kid needs it:
    /// a wallet that needs a grown-up first, then what this device could
    /// reach, then any other trouble the newest read reported.
    public static func statusBanner(
        sessionExpired: Bool,
        connection: WalletConnection,
        hasError: Bool,
        lastUpdated: Date
    ) -> String? {
        if sessionExpired { return sessionBanner }
        switch connection {
        case .deviceOffline: return offlineBanner(lastUpdated: lastUpdated)
        case .serviceUnreachable: return cannotReachBanner(lastUpdated: lastUpdated)
        case .reached: return hasError ? couldNotUpdateBanner(lastUpdated: lastUpdated) : nil
        }
    }

    private static func asOf(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    public static let sessionBanner = "A parent needs to sign in again."

    public static let emptyWalletTitle = "Your wallet is ready!"

    public static let emptyWalletMessage = "Your parent can add the first dollars."

    public static let cloudReplicaUnavailableTitle = "Your wallet needs to reconnect"

    public static func cloudReplicaUnavailableMessage(deviceNoun: String) -> String {
        "This \(deviceNoun) needs to reconnect before it can show your wallet."
    }

    public static func parentDoorAccessibilityLabel() -> String {
        "Parent area. Asks for the parent PIN."
    }
}

public enum ActivityType: String, CaseIterable, Codable, Sendable {
    case allowance
    case deposit
    case withdrawal
    case loan
    case repayment

    var title: String {
        switch self {
        case .allowance: "Allowance"
        case .deposit: "Deposit"
        case .withdrawal: "Withdrawal"
        case .loan: "Loan"
        case .repayment: "Repayment"
        }
    }

    var iconName: String {
        switch self {
        case .allowance: "gift"
        case .deposit: "arrow.down.circle"
        case .withdrawal: "arrow.up.circle"
        case .loan: "hand.raised"
        case .repayment: "arrow.triangle.2.circlepath"
        }
    }
}

public enum SyncState: String, Codable, Sendable {
    case recorded
    case pending
    case rejected
    case draft

    public var label: String {
        switch self {
        case .recorded: "Recorded"
        case .pending: "Waiting to sync"
        case .rejected: "Not recorded"
        case .draft: "Draft on this iPad"
        }
    }
}

public struct Money: Hashable, Codable, Sendable, ExpressibleByIntegerLiteral {
    public let cents: Int

    public init(cents: Int) {
        self.cents = cents
    }

    public init(integerLiteral value: Int) {
        self.init(cents: value * 100)
    }

    public var display: String {
        let dollars = abs(cents) / 100
        let remainder = abs(cents) % 100
        let sign = cents < 0 ? "-" : ""
        return "\(sign)US$\(dollars).\(String(format: "%02d", remainder))"
    }

    public static func parse(_ input: String) -> Money? {
        let cleaned = input.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "US$", with: "")
            .replacingOccurrences(of: "$", with: "")
        guard !cleaned.isEmpty, !cleaned.contains("-") else { return nil }
        let parts = cleaned.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count <= 2, let dollars = Int(parts[0]), dollars >= 0 else { return nil }
        let fraction: Int
        if parts.count == 2 {
            guard parts[1].allSatisfy(\.isNumber), parts[1].count <= 2 else { return nil }
            let padded = String(parts[1]).padding(toLength: 2, withPad: "0", startingAt: 0)
            fraction = Int(padded) ?? 0
        } else {
            fraction = 0
        }
        let value = dollars * 100 + fraction
        return value > 0 ? Money(cents: value) : nil
    }
}

public struct WalletEvent: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public let remoteID: String?
    public let type: ActivityType
    public let amountCents: Int
    public let balanceBeforeCents: Int?
    public let balanceAfterCents: Int?
    public let reason: String?
    public let date: Date
    public let syncState: SyncState
    public let explanation: String
    public let rejectionReason: String?

    public init(
        id: UUID = UUID(),
        remoteID: String? = nil,
        type: ActivityType,
        amountCents: Int,
        balanceBeforeCents: Int? = nil,
        balanceAfterCents: Int? = nil,
        reason: String? = nil,
        date: Date = .now,
        syncState: SyncState = .recorded,
        explanation: String,
        rejectionReason: String? = nil
    ) {
        self.id = id
        self.remoteID = remoteID
        self.type = type
        self.amountCents = amountCents
        self.balanceBeforeCents = balanceBeforeCents
        self.balanceAfterCents = balanceAfterCents
        self.reason = reason
        self.date = date
        self.syncState = syncState
        self.explanation = explanation
        self.rejectionReason = rejectionReason
    }

    public var isPositive: Bool {
        type == .deposit || type == .allowance || type == .loan
    }

    public var signedAmount: Money {
        Money(cents: isPositive ? amountCents : -amountCents)
    }

    public var displayReason: String {
        reason?.isEmpty == false ? reason! : type.title
    }
}

public struct Loan: Hashable, Codable, Sendable {
    public let remoteID: String?
    public let originalCents: Int
    public var remainingCents: Int
    public let purpose: String?
    public let dueDate: Date?

    public init(
        remoteID: String? = nil,
        originalCents: Int,
        remainingCents: Int,
        purpose: String? = nil,
        dueDate: Date? = nil
    ) {
        self.remoteID = remoteID
        self.originalCents = originalCents
        self.remainingCents = remainingCents
        self.purpose = purpose
        self.dueDate = dueDate
    }

    public var isPaid: Bool { remainingCents == 0 }
    public var progress: Double {
        guard originalCents > 0 else { return 0 }
        return Double(originalCents - remainingCents) / Double(originalCents)
    }
}

public struct AllowancePlan: Hashable, Codable, Sendable {
    public let remoteID: String?
    public let amountCents: Int
    public let cadence: String
    public let weekday: Int
    public let nextDate: Date
    public let endDate: Date?
    public let nextOccurrenceID: String?
    public let syncState: SyncState

    public init(
        remoteID: String? = nil,
        amountCents: Int,
        cadence: String,
        weekday: Int = 5,
        nextDate: Date,
        endDate: Date? = nil,
        nextOccurrenceID: String? = nil,
        syncState: SyncState = .recorded
    ) {
        self.remoteID = remoteID
        self.amountCents = amountCents
        self.cadence = cadence
        self.weekday = weekday
        self.nextDate = nextDate
        self.endDate = endDate
        self.nextOccurrenceID = nextOccurrenceID
        self.syncState = syncState
    }
}

public struct WalletSnapshot: Hashable, Codable, Sendable {
    public var acceptedBalanceCents: Int
    public var childNickname: String?
    public var activities: [WalletEvent]
    public var loan: Loan?
    public var allowance: AllowancePlan?
    public var pendingEvents: [WalletEvent]
    public var lastUpdated: Date
    public var isStale: Bool

    public init(
        acceptedBalanceCents: Int,
        activities: [WalletEvent],
        loan: Loan?,
        allowance: AllowancePlan?,
        pendingEvents: [WalletEvent],
        lastUpdated: Date,
        isStale: Bool,
        childNickname: String? = nil
    ) {
        self.acceptedBalanceCents = acceptedBalanceCents
        self.childNickname = childNickname
        self.activities = activities
        self.loan = loan
        self.allowance = allowance
        self.pendingEvents = pendingEvents
        self.lastUpdated = lastUpdated
        self.isStale = isStale
    }

    public var configuredChildNickname: String? {
        ChildProfileCopy.configuredNickname(from: childNickname)
    }

    public static func empty(now: Date = .now) -> WalletSnapshot {
        WalletSnapshot(
            acceptedBalanceCents: 0,
            activities: [],
            loan: nil,
            allowance: nil,
            pendingEvents: [],
            lastUpdated: now,
            isStale: true
        )
    }

    public static func fixture(now: Date = .now) -> WalletSnapshot {
        let calendar = Calendar.current
        let loanDate = calendar.date(byAdding: .day, value: -8, to: now) ?? now
        let withdrawalDate = calendar.date(byAdding: .day, value: -11, to: now) ?? now
        let allowanceDate = calendar.date(byAdding: .day, value: -12, to: now) ?? now
        let dueDate = calendar.date(byAdding: .day, value: 20, to: now)
        return WalletSnapshot(
            acceptedBalanceCents: 2_400,
            activities: [
                WalletEvent(type: .loan, amountCents: 1_000, reason: "Bike helmet", date: loanDate, explanation: "Your parent gave you US$10.00 to use now, and US$10.00 to give back over time."),
                WalletEvent(type: .withdrawal, amountCents: 400, reason: "Comic book", date: withdrawalDate, explanation: "Your parent recorded that US$4.00 was used."),
                WalletEvent(type: .allowance, amountCents: 1_000, reason: "Weekly", date: allowanceDate, explanation: "Your parent added US$10.00 as your weekly allowance.")
            ],
            loan: Loan(originalCents: 1_000, remainingCents: 600, purpose: "Bike helmet", dueDate: dueDate),
            allowance: AllowancePlan(amountCents: 1_000, cadence: "every Friday", nextDate: calendar.date(byAdding: .day, value: 5, to: now) ?? now),
            pendingEvents: [
                WalletEvent(type: .deposit, amountCents: 500, reason: "Birthday practice", syncState: .pending, explanation: "This parent action is waiting to sync. It is not included in the accepted balance."),
                WalletEvent(type: .withdrawal, amountCents: 3_000, reason: "New bicycle", syncState: .rejected, explanation: "This withdrawal was not recorded because it is greater than the accepted wallet balance.", rejectionReason: "The amount is greater than the accepted balance.")
            ],
            lastUpdated: now.addingTimeInterval(-120),
            isStale: true,
            childNickname: "Eddie" // Preview and test fixture data only.
        )
    }
}

public enum WalletCommandKind: String, Sendable, Codable, Equatable {
    case allowance
    case deposit
    case withdrawal
    case loan
    case repayment
}

public struct WalletCommand: Sendable, Codable, Equatable {
    public let kind: WalletCommandKind
    public let amountCents: Int
    public let reason: String?
    public let dueDate: Date?
    public let idempotencyKey: String

    public init(
        kind: WalletCommandKind,
        amountCents: Int,
        reason: String? = nil,
        dueDate: Date? = nil,
        idempotencyKey: String = UUID().uuidString
    ) {
        self.kind = kind
        self.amountCents = amountCents
        self.reason = reason
        self.dueDate = dueDate
        self.idempotencyKey = idempotencyKey
    }
}

public struct AllowanceRuleCommand: Sendable, Codable {
    public let amountCents: Int
    public let weekday: Int
    public let startDate: Date
    public let endDate: Date?
    public let idempotencyKey: String

    public init(
        amountCents: Int,
        weekday: Int,
        startDate: Date,
        endDate: Date? = nil,
        idempotencyKey: String = UUID().uuidString
    ) {
        self.amountCents = amountCents
        self.weekday = weekday
        self.startDate = startDate
        self.endDate = endDate
        self.idempotencyKey = idempotencyKey
    }
}

public struct ParentSetup: Sendable, Codable {
    public let familyName: String?
    public let nickname: String
    public let avatarURL: URL?
    public let idempotencyKey: String

    public init(
        familyName: String? = nil,
        nickname: String,
        avatarURL: URL? = nil,
        idempotencyKey: String = UUID().uuidString
    ) {
        self.familyName = familyName
        self.nickname = nickname
        self.avatarURL = avatarURL
        self.idempotencyKey = idempotencyKey
    }
}

public struct ChildProfileUpdate: Sendable, Codable {
    public let nickname: String
    public let idempotencyKey: String

    public init(nickname: String, idempotencyKey: String = UUID().uuidString) {
        self.nickname = nickname
        self.idempotencyKey = idempotencyKey
    }

    /// Same non-empty trimmed nickname rule as first-run setup.
    public var validatedNickname: String? {
        ChildProfileCopy.configuredNickname(from: nickname)
    }
}

public struct AuthSession: Codable, Hashable, Sendable {
    public let token: String
    public let expiresAt: Date

    public init(token: String, expiresAt: Date) {
        self.token = token
        self.expiresAt = expiresAt
    }

    public var isExpired: Bool { expiresAt <= .now }
}

public struct LoanDetail: Sendable {
    public let loan: Loan
    public let entries: [WalletEvent]

    public init(loan: Loan, entries: [WalletEvent]) {
        self.loan = loan
        self.entries = entries
    }
}

public enum CommandResult: Sendable {
    case accepted(WalletEvent)
    case pending(WalletEvent, diagnostic: TransportDiagnostic? = nil)
    case acceptedAwaitingReplica(WalletEvent, diagnostic: TransportDiagnostic? = nil)
    case rejected(WalletEvent)

    public var transportDiagnostic: TransportDiagnostic? {
        switch self {
        case .pending(_, let diagnostic), .acceptedAwaitingReplica(_, let diagnostic):
            diagnostic
        case .accepted, .rejected:
            nil
        }
    }
}

/// Parent-visible result for mutations that do not create ledger entries.
/// Cloud acceptance and local observation are separate so a failed reread can
/// never turn an accepted profile or allowance change into "Not recorded".
public enum ParentMutationOutcome: Equatable, Sendable {
    case recorded
    case waitingForCloud
    case acceptedAwaitingReplica
    case notRecorded

    public var syncState: SyncState {
        switch self {
        case .recorded: .recorded
        case .waitingForCloud, .acceptedAwaitingReplica: .pending
        case .notRecorded: .rejected
        }
    }

    public var message: String {
        switch self {
        case .recorded: "Recorded."
        case .waitingForCloud:
            "Cloud has not confirmed this change yet. This device will retry the same protected request. Do not save it again."
        case .acceptedAwaitingReplica:
            "Cloud accepted this change. This device is waiting to see the updated wallet. Do not save it again."
        case .notRecorded:
            "This change was not recorded. Review the latest wallet before trying again."
        }
    }
}

@MainActor
public protocol WalletRepository: AnyObject {
    var isAuthenticated: Bool { get }
    var hasConfiguredKid: Bool { get }
    var supportsRuntimeMutations: Bool { get }
    func snapshot() -> WalletSnapshot
    func childSnapshot() -> WalletSnapshot
    func refresh(for role: UserRole) async throws -> WalletSnapshot
    func activity(limit: Int) async throws -> [WalletEvent]
    func activityDetail(remoteID: String) async throws -> WalletEvent
    func loanDetail(remoteID: String) async throws -> LoanDetail
    func submit(_ command: WalletCommand) async throws -> CommandResult
    func setAllowance(_ command: AllowanceRuleCommand) async throws -> WalletSnapshot
    func setup(_ setup: ParentSetup) async throws -> WalletSnapshot
    func updateChildProfile(_ update: ChildProfileUpdate) async throws -> WalletSnapshot
    func clearAuthentication()
    func clearAuthenticationForAccountDeletion() throws
    func clearSession() throws
}

public extension WalletRepository {
    var supportsRuntimeMutations: Bool { true }
    func clearAuthenticationForAccountDeletion() throws { clearAuthentication() }
}

@MainActor
public protocol ParentAuthenticator: AnyObject {
    func authenticateApple(identityToken: String, nonce: String) async throws -> AuthSession
}

/// The only definite server outcomes for an account-delete request. Any
/// missing, malformed, or transport-level response remains intentionally
/// distinct so the client never calls an unobserved deletion complete.
public enum AccountDeletionResult: Equatable, Sendable {
    case deleted
    case alreadyDeleted
}

public enum AccountDeletionPresentation: Equatable, Sendable {
    case deleting(idempotencyKey: String)
    case incomplete(idempotencyKey: String)
    case deleted

    public var idempotencyKey: String? {
        switch self {
        case .deleting(let idempotencyKey), .incomplete(let idempotencyKey): idempotencyKey
        case .deleted: nil
        }
    }
}

/// Service boundary for the irreversible account-delete command. Keeping it
/// separate from a wallet repository lets even a free local wallet delete the
/// backend parent identity created during Apple sign-in before local data goes.
@MainActor
public protocol AccountDeletionPerforming: AnyObject {
    func preflightAccountDeletion() async throws
    func deleteAccount(idempotencyKey: String) async throws -> AccountDeletionResult
}

@MainActor
public protocol AccountDeletionLocalRetiring: AnyObject {
    func retireLocalWalletForAccountDeletion() throws
}

@MainActor
public final class MockWalletRepository: WalletRepository, AccountDeletionLocalRetiring {
    private var current: WalletSnapshot
    private var currentChild: WalletSnapshot
    private var configuredKid: Bool

    public init(snapshot: WalletSnapshot = .fixture(), hasConfiguredKid: Bool = true) {
        self.current = snapshot
        self.currentChild = snapshot
        self.configuredKid = hasConfiguredKid
    }

    public var isAuthenticated: Bool { true }
    public var hasConfiguredKid: Bool { configuredKid }
    public func snapshot() -> WalletSnapshot { current }
    public func childSnapshot() -> WalletSnapshot { currentChild }
    public func refresh(for role: UserRole) async throws -> WalletSnapshot {
        if role == .child {
            currentChild = current
            return currentChild
        }
        return current
    }
    public func activity(limit: Int) async throws -> [WalletEvent] { Array(current.activities.prefix(max(1, min(limit, 100)))) }
    public func activityDetail(remoteID: String) async throws -> WalletEvent {
        guard let event = current.activities.first(where: { $0.remoteID == remoteID }) else {
            throw WalletAPIError.server(statusCode: 404, code: "ACTIVITY_NOT_FOUND", message: "The activity entry was not found.")
        }
        return event
    }
    public func loanDetail(remoteID: String) async throws -> LoanDetail {
        guard let loan = current.loan, loan.remoteID == remoteID else {
            throw WalletAPIError.server(statusCode: 404, code: "LOAN_NOT_FOUND", message: "The loan was not found.")
        }
        return LoanDetail(loan: loan, entries: current.activities.filter { $0.type == .loan || $0.type == .repayment })
    }
    public func clearAuthentication() {}
    public func clearSession() throws {
        configuredKid = false
        current = .empty()
        currentChild = .empty()
    }
    public func retireLocalWalletForAccountDeletion() throws { try clearSession() }

    public func setup(_ setup: ParentSetup) async throws -> WalletSnapshot {
        guard let nickname = ChildProfileCopy.configuredNickname(from: setup.nickname) else { return current }
        configuredKid = true
        applyNickname(nickname)
        return current
    }

    public func updateChildProfile(_ update: ChildProfileUpdate) async throws -> WalletSnapshot {
        guard let nickname = update.validatedNickname else {
            throw WalletAPIError.invalidResponse("Enter a child nickname.")
        }
        applyNickname(nickname)
        return current
    }

    private func applyNickname(_ nickname: String) {
        current.childNickname = nickname
        currentChild.childNickname = nickname
        current.lastUpdated = .now
        currentChild.lastUpdated = .now
        current.isStale = false
        currentChild.isStale = false
    }

    public func setAllowance(_ command: AllowanceRuleCommand) async throws -> WalletSnapshot {
        guard command.amountCents > 0 else { return current }
        current.allowance = AllowancePlan(
            amountCents: command.amountCents,
            cadence: "every week",
            weekday: command.weekday,
            nextDate: command.startDate,
            endDate: command.endDate
        )
        current.lastUpdated = .now
        current.isStale = false
        return current
    }

    public func submit(_ command: WalletCommand) async throws -> CommandResult {
        guard command.amountCents > 0 else {
            return .rejected(makeEvent(for: command, state: .rejected, explanation: "This amount was not recorded.", rejectionReason: "Enter an amount greater than US$0.00."))
        }

        switch command.kind {
        case .withdrawal:
            guard command.amountCents <= current.acceptedBalanceCents else {
                return .rejected(makeEvent(for: command, state: .rejected, explanation: "This withdrawal was not recorded because it is greater than the accepted wallet balance.", rejectionReason: "The amount is greater than the accepted balance."))
            }
            current.acceptedBalanceCents -= command.amountCents
        case .repayment:
            guard let loan = current.loan, command.amountCents <= loan.remainingCents else {
                return .rejected(makeEvent(for: command, state: .rejected, explanation: "This repayment was not recorded.", rejectionReason: "The repayment is greater than the amount left to repay."))
            }
            guard command.amountCents <= current.acceptedBalanceCents else {
                return .rejected(makeEvent(for: command, state: .rejected, explanation: "This repayment was not recorded.", rejectionReason: "The repayment is greater than the accepted wallet balance."))
            }
            current.acceptedBalanceCents -= command.amountCents
            current.loan?.remainingCents -= command.amountCents
        case .loan:
            guard current.loan == nil || current.loan?.isPaid == true else {
                return .rejected(makeEvent(for: command, state: .rejected, explanation: "This loan was not recorded.", rejectionReason: "Finish the open loan before creating another one."))
            }
            current.acceptedBalanceCents += command.amountCents
            current.loan = Loan(originalCents: command.amountCents, remainingCents: command.amountCents, purpose: command.reason, dueDate: command.dueDate)
        case .deposit:
            current.acceptedBalanceCents += command.amountCents
        case .allowance:
            current.acceptedBalanceCents += command.amountCents
        }

        let event = makeEvent(for: command, state: .recorded, explanation: explanation(for: command))
        current.activities.insert(event, at: 0)
        current.lastUpdated = .now
        current.isStale = false
        return .accepted(event)
    }

    private func makeEvent(for command: WalletCommand, state: SyncState, explanation: String, rejectionReason: String? = nil) -> WalletEvent {
        let type: ActivityType = switch command.kind {
        case .allowance: .allowance
        case .deposit: .deposit
        case .withdrawal: .withdrawal
        case .loan: .loan
        case .repayment: .repayment
        }
        return WalletEvent(type: type, amountCents: command.amountCents, reason: command.reason, syncState: state, explanation: explanation, rejectionReason: rejectionReason)
    }

    private func explanation(for command: WalletCommand) -> String {
        let amount = Money(cents: command.amountCents).display
        switch command.kind {
        case .allowance: return "Your parent added \(amount) as your allowance."
        case .deposit: return "Your parent added \(amount) to your wallet."
        case .withdrawal: return "Your parent recorded that \(amount) was used."
        case .loan: return "Your parent gave you \(amount) to use now and give back over time."
        case .repayment: return "Your parent recorded \(amount) returned toward the loan."
        }
    }
}
