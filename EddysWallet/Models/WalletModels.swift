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

/// How often a scheduled loan asks for its next payment. A loan created
/// without a cadence has no schedule at all and keeps the one-shot repayment
/// path, so this is never a default.
public enum LoanInstallmentCadence: String, Hashable, Codable, Sendable, CaseIterable, Identifiable {
    case weekly
    case monthly

    public var id: String { rawValue }

    /// The payment date `index` steps after `anchor`.
    ///
    /// Monthly dates are always measured from the anchor rather than from the
    /// previously produced date, so a plan taken out on the 31st stays on the
    /// 31st instead of drifting down to the 28th after February. This matches
    /// the service's own `installmentDueOn`, which is what makes a locally
    /// derived date and a server-seeded occurrence name the same day.
    public func dueDate(from anchor: Date, index: Int, calendar: Calendar = .current) -> Date? {
        let start = calendar.startOfDay(for: anchor)
        return switch self {
        case .weekly: calendar.date(byAdding: .day, value: index * 7, to: start)
        case .monthly: calendar.date(byAdding: .month, value: index, to: start)
        }
    }
}

/// The installment plan a parent names when they create a loan: how often, and
/// how much each payment is. The last payment is not part of the plan - it is
/// always whatever is left to repay.
public struct LoanInstallmentPlan: Hashable, Codable, Sendable {
    public let cadence: LoanInstallmentCadence
    public let amountCents: Int
    /// The first payment date. When a parent does not name one, the service
    /// and the local repository both default it to one full cadence step after
    /// today, so a loan handed over today is never already due.
    public let firstDueDate: Date?

    public init(cadence: LoanInstallmentCadence, amountCents: Int, firstDueDate: Date? = nil) {
        self.cadence = cadence
        self.amountCents = amountCents
        self.firstDueDate = firstDueDate
    }

    /// One full cadence step after today, which is what the service uses when
    /// a parent names no first payment date. A loan handed over today is then
    /// never already due, and never already missed.
    public static func defaultFirstDueDate(
        cadence: LoanInstallmentCadence,
        asOf now: Date = .now,
        calendar: Calendar = .current
    ) -> Date {
        let today = calendar.startOfDay(for: now)
        return cadence.dueDate(from: today, index: 1, calendar: calendar) ?? today
    }
}

/// One payment on a loan's installment grid: the day it is due and what it
/// actually settles. `amountCents` is already capped at what the loan still
/// owes, so the last installment of a plan is smaller than the named amount
/// whenever the balance no longer covers it.
public struct LoanInstallment: Hashable, Identifiable, Sendable {
    public let dueDate: Date
    public let amountCents: Int

    public var id: Date { dueDate }

    public init(dueDate: Date, amountCents: Int) {
        self.dueDate = dueDate
        self.amountCents = amountCents
    }
}

/// The installments of a scheduled loan whose day has already passed and that
/// a parent has not recorded yet. Because each occurrence is capped at the
/// balance remaining when it is settled, `totalCents` can never exceed what
/// the loan still owes. This model never records anything itself - a parent
/// action remains required.
public struct LoanMissedInstallments: Hashable, Sendable {
    public let installments: [LoanInstallment]

    public init(installments: [LoanInstallment]) {
        self.installments = installments
    }

    public var count: Int { installments.count }
    public var totalCents: Int { installments.reduce(0) { $0 + $1.amountCents } }
    public var isEmpty: Bool { installments.isEmpty }
}

public enum LoanRecordAllOutcome: Equatable, Sendable {
    case noMissed
    case recorded(count: Int, totalCents: Int)
    case awaitingCloud(recordedCount: Int, recordedTotalCents: Int)
    case reviewRequired(recordedCount: Int, recordedTotalCents: Int)
    /// The accepted prefix is durable. The remaining installments have not
    /// been recorded and can be explicitly settled in a later parent action.
    case partial(recordedCount: Int, recordedTotalCents: Int, remaining: LoanMissedInstallments)
}

/// A loan's durable installment plan plus the one payment occurrence that is
/// waiting to be recorded.
///
/// The plan itself (`cadence`, `amountCents`, `firstDueDate`) is a
/// creation-time fact and never changes. `nextDueDate` is the earliest
/// unrecorded occurrence and may be in the past while a parent catches up;
/// it advances only alongside an accepted repayment, which is what makes each
/// occurrence recordable exactly once. A settled loan carries no occurrence at
/// all, so a paid-off loan never leaves a payment reminder standing.
public struct LoanSchedule: Hashable, Codable, Sendable {
    /// One payment day of a plan, in the same three states the service keeps.
    /// `entryID` names the accepted repayment that settled a recorded payment,
    /// which is what lets a one-time Cloud upload reproduce the very chain the
    /// service would have built for itself.
    public struct Occurrence: Hashable, Codable, Sendable, Identifiable {
        public enum Status: String, Hashable, Codable, Sendable {
            case scheduled
            case recorded
            case cancelled
        }

        public let id: String
        public let dueDate: Date
        public var status: Status
        public var amountCents: Int?
        public var entryID: UUID?

        public init(
            id: String,
            dueDate: Date,
            status: Status,
            amountCents: Int? = nil,
            entryID: UUID? = nil
        ) {
            self.id = id
            self.dueDate = dueDate
            self.status = status
            self.amountCents = amountCents
            self.entryID = entryID
        }
    }

    public let cadence: LoanInstallmentCadence
    public let amountCents: Int
    public let firstDueDate: Date
    /// Ordered by payment day, oldest first. At most one is ever `scheduled`,
    /// which is the whole walkable chain head: an overdue span is settled by
    /// recording that one and taking the next out of the result.
    public var occurrences: [Occurrence]

    /// The one payment waiting to be recorded, or `nil` for a settled loan.
    public var nextOccurrence: Occurrence? {
        occurrences.first { $0.status == .scheduled }
    }

    public var nextDueDate: Date? { nextOccurrence?.dueDate }
    public var nextOccurrenceID: String? { nextOccurrence?.id }

    public init(
        cadence: LoanInstallmentCadence,
        amountCents: Int,
        firstDueDate: Date,
        occurrences: [Occurrence]
    ) {
        self.cadence = cadence
        self.amountCents = amountCents
        self.firstDueDate = firstDueDate
        self.occurrences = occurrences
    }

    /// Convenience for the authorities that publish only the chain head: a
    /// service projection names the next occurrence directly and keeps its own
    /// recorded rows.
    public init(
        cadence: LoanInstallmentCadence,
        amountCents: Int,
        firstDueDate: Date,
        nextDueDate: Date?,
        nextOccurrenceID: String?
    ) {
        self.init(
            cadence: cadence,
            amountCents: amountCents,
            firstDueDate: firstDueDate,
            occurrences: zip([nextDueDate].compactMap { $0 }, [nextOccurrenceID].compactMap { $0 })
                .map { Occurrence(id: $1, dueDate: $0, status: .scheduled) }
        )
    }

    /// What the service labels an installment a parent did not name.
    public static let defaultInstallmentReason = "Loan payment"

    /// A brand-new plan, seeded one occurrence ahead exactly as the service
    /// seeds it at loan creation. Nothing is debited here.
    public static func opening(
        _ plan: LoanInstallmentPlan,
        occurrenceID: String = UUID().uuidString,
        asOf now: Date = .now,
        calendar: Calendar = .current
    ) -> LoanSchedule {
        let firstDueDate = calendar.startOfDay(
            for: plan.firstDueDate ?? LoanInstallmentPlan.defaultFirstDueDate(cadence: plan.cadence, asOf: now, calendar: calendar)
        )
        return LoanSchedule(
            cadence: plan.cadence,
            amountCents: plan.amountCents,
            firstDueDate: firstDueDate,
            occurrences: [Occurrence(id: occurrenceID, dueDate: firstDueDate, status: .scheduled)]
        )
    }

    /// The installment index of `dueDate` on this plan's grid, or `nil` when
    /// the date is not on the grid at all.
    public func installmentIndex(of dueDate: Date, calendar: Calendar = .current) -> Int? {
        let target = calendar.startOfDay(for: dueDate)
        let anchor = calendar.startOfDay(for: firstDueDate)
        guard target >= anchor else { return nil }
        let index: Int
        switch cadence {
        case .weekly:
            guard let days = calendar.dateComponents([.day], from: anchor, to: target).day, days % 7 == 0 else {
                return nil
            }
            index = days / 7
        case .monthly:
            // Whole calendar months, ignoring day of month, so a clamped date
            // such as February 28th on a plan anchored to the 31st still
            // resolves to its own index instead of the previous one.
            let anchorParts = calendar.dateComponents([.year, .month], from: anchor)
            let targetParts = calendar.dateComponents([.year, .month], from: target)
            guard let anchorYear = anchorParts.year, let anchorMonth = anchorParts.month,
                  let targetYear = targetParts.year, let targetMonth = targetParts.month else { return nil }
            index = (targetYear - anchorYear) * 12 + (targetMonth - anchorMonth)
        }
        guard index >= 0, cadence.dueDate(from: anchor, index: index, calendar: calendar) == target else { return nil }
        return index
    }

    /// The payment date one cadence step after `dueDate`, measured from the
    /// anchor. Returns `nil` when `dueDate` is not on this plan's grid.
    public func dueDateAfter(_ dueDate: Date, calendar: Calendar = .current) -> Date? {
        guard let index = installmentIndex(of: dueDate, calendar: calendar) else { return nil }
        return cadence.dueDate(from: firstDueDate, index: index + 1, calendar: calendar)
    }
}

public struct Loan: Hashable, Codable, Sendable {
    public let remoteID: String?
    public let originalCents: Int
    public var remainingCents: Int
    public let purpose: String?
    public let dueDate: Date?
    /// `nil` for every loan taken out without an installment plan. Those loans
    /// keep the one-shot repayment behavior they have always had and show no
    /// reminder, so a schedule is strictly additive per loan.
    public var schedule: LoanSchedule?

    public init(
        remoteID: String? = nil,
        originalCents: Int,
        remainingCents: Int,
        purpose: String? = nil,
        dueDate: Date? = nil,
        schedule: LoanSchedule? = nil
    ) {
        self.remoteID = remoteID
        self.originalCents = originalCents
        self.remainingCents = remainingCents
        self.purpose = purpose
        self.dueDate = dueDate
        self.schedule = schedule
    }

    public var isPaid: Bool { remainingCents == 0 }
    public var progress: Double {
        guard originalCents > 0 else { return 0 }
        return Double(originalCents - remainingCents) / Double(originalCents)
    }

    /// What one installment settles against a given balance: the named amount,
    /// or the rest of the loan. This is the whole final-payment cap, and it is
    /// the only place the client decides an installment amount.
    public static func installmentPaymentCents(named amountCents: Int, remainingCents: Int) -> Int {
        max(0, min(amountCents, remainingCents))
    }

    /// The amount the next scheduled installment settles right now, or `nil`
    /// when this loan has no occurrence waiting.
    public var nextInstallmentPaymentCents: Int? {
        guard let schedule, schedule.nextDueDate != nil, remainingCents > 0 else { return nil }
        return Self.installmentPaymentCents(named: schedule.amountCents, remainingCents: remainingCents)
    }

    /// Payment days that have already passed and are still unrecorded.
    ///
    /// A payment due today stays the ordinary next installment, so a catch-up
    /// never records today's payment. The walk carries the balance forward,
    /// which caps each installment in turn and stops the moment the loan would
    /// be settled - a long-abandoned plan can therefore never ask for more
    /// than the loan still owes.
    public func missedInstallments(asOf now: Date = .now, calendar: Calendar = .current) -> LoanMissedInstallments {
        guard let schedule, var dueDate = schedule.nextDueDate.map({ calendar.startOfDay(for: $0) }) else {
            return LoanMissedInstallments(installments: [])
        }
        let today = calendar.startOfDay(for: now)
        var remaining = remainingCents
        var installments: [LoanInstallment] = []

        while dueDate < today, remaining > 0 {
            let payment = Self.installmentPaymentCents(named: schedule.amountCents, remainingCents: remaining)
            guard payment > 0 else { break }
            installments.append(LoanInstallment(dueDate: dueDate, amountCents: payment))
            remaining -= payment
            guard remaining > 0, let followingDate = schedule.dueDateAfter(dueDate, calendar: calendar) else { break }
            dueDate = calendar.startOfDay(for: followingDate)
        }
        return LoanMissedInstallments(installments: installments)
    }

    /// The first still-current or future payment, and what it would settle
    /// once every missed payment before it has been recorded. This is
    /// deliberately separate from `schedule.nextDueDate`, which is the earliest
    /// unrecorded occurrence and can be a past day while a parent catches up.
    public func nextCurrentOrFutureInstallment(
        asOf now: Date = .now,
        calendar: Calendar = .current
    ) -> LoanInstallment? {
        guard let schedule, var dueDate = schedule.nextDueDate.map({ calendar.startOfDay(for: $0) }) else {
            return nil
        }
        let today = calendar.startOfDay(for: now)
        var remaining = remainingCents - missedInstallments(asOf: now, calendar: calendar).totalCents
        guard remaining > 0 else { return nil }

        while dueDate < today {
            guard let followingDate = schedule.dueDateAfter(dueDate, calendar: calendar) else { return nil }
            dueDate = calendar.startOfDay(for: followingDate)
        }
        return LoanInstallment(
            dueDate: dueDate,
            amountCents: Self.installmentPaymentCents(named: schedule.amountCents, remainingCents: remaining)
        )
    }

    /// This loan after one accepted installment, or `nil` when no occurrence
    /// is due or `paymentCents` is not what the plan and the balance decide.
    ///
    /// The plan advances to its own next day, measured from the anchor. A
    /// payment that clears the balance drops the occurrence entirely instead of
    /// seeding another, so a settled loan never leaves a reminder standing and
    /// the outstanding balance can never be driven below zero.
    public func recordingInstallment(
        paymentCents: Int,
        nextOccurrenceID: String,
        entryID: UUID? = nil,
        calendar: Calendar = .current
    ) -> Loan? {
        guard var schedule, let occurrence = schedule.nextOccurrence, remainingCents > 0 else { return nil }
        guard paymentCents == Self.installmentPaymentCents(named: schedule.amountCents, remainingCents: remainingCents) else {
            return nil
        }
        guard let index = schedule.occurrences.firstIndex(where: { $0.id == occurrence.id }) else { return nil }
        let remaining = remainingCents - paymentCents
        schedule.occurrences[index].status = .recorded
        schedule.occurrences[index].amountCents = paymentCents
        schedule.occurrences[index].entryID = entryID
        if remaining > 0 {
            guard let followingDate = schedule.dueDateAfter(occurrence.dueDate, calendar: calendar) else { return nil }
            schedule.occurrences.append(
                LoanSchedule.Occurrence(id: nextOccurrenceID, dueDate: followingDate, status: .scheduled)
            )
        }
        var settled = self
        settled.remainingCents = remaining
        settled.schedule = schedule
        return settled
    }

    /// Retires any standing payment occurrence. A free-amount repayment that
    /// clears the balance must leave no reminder behind, exactly as the service
    /// cancels the pending occurrence in the same transaction.
    public mutating func retireScheduleIfSettled() {
        guard remainingCents == 0, var schedule,
              let index = schedule.occurrences.firstIndex(where: { $0.status == .scheduled }) else { return }
        schedule.occurrences[index].status = .cancelled
        self.schedule = schedule
    }
}

public struct AllowanceOccurrence: Hashable, Identifiable, Sendable {
    public let dueDate: Date
    public let amountCents: Int

    public var id: Date { dueDate }

    public init(dueDate: Date, amountCents: Int) {
        self.dueDate = dueDate
        self.amountCents = amountCents
    }
}

/// The scheduled weekly payouts a parent has not recorded yet. The schedule's
/// next date is the first unrecorded occurrence, so walking forward from it is
/// both the local and Cloud-authoritative record of which weeks remain due.
/// This model never records anything itself - a parent action remains required.
public struct AllowanceMissedPayouts: Hashable, Sendable {
    public let occurrences: [AllowanceOccurrence]

    public init(occurrences: [AllowanceOccurrence]) {
        self.occurrences = occurrences
    }

    public var count: Int { occurrences.count }
    public var totalCents: Int { occurrences.reduce(0) { $0 + $1.amountCents } }
    public var isEmpty: Bool { occurrences.isEmpty }
}

public enum AllowanceRecordAllOutcome: Equatable, Sendable {
    case noMissed
    case recorded(count: Int, totalCents: Int)
    case awaitingCloud(recordedCount: Int, recordedTotalCents: Int)
    case scheduleUnavailable(recordedCount: Int, recordedTotalCents: Int)
    case reviewRequired(recordedCount: Int, recordedTotalCents: Int)
    /// The accepted prefix is durable. The remaining occurrences have not
    /// been recorded and can be explicitly settled in a later parent action.
    case partial(recordedCount: Int, recordedTotalCents: Int, remaining: AllowanceMissedPayouts)
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

    /// Past calendar days are missed. A payout due today stays the next
    /// allowance, so recording every missed week never auto-records today's
    /// allowance. `nextDate` is advanced only after an accepted allowance
    /// entry, which makes each returned occurrence unrecorded exactly once.
    public func missedPayouts(asOf now: Date = .now, calendar: Calendar = .current) -> AllowanceMissedPayouts {
        let today = calendar.startOfDay(for: now)
        let inclusiveEndDate = endDate.map { calendar.startOfDay(for: $0) }
        var dueDate = calendar.startOfDay(for: nextDate)
        var occurrences: [AllowanceOccurrence] = []

        while dueDate < today, inclusiveEndDate.map({ dueDate <= $0 }) ?? true {
            occurrences.append(AllowanceOccurrence(dueDate: dueDate, amountCents: amountCents))
            guard let followingDate = calendar.date(byAdding: .day, value: 7, to: dueDate) else { break }
            dueDate = followingDate
        }
        return AllowanceMissedPayouts(occurrences: occurrences)
    }

    /// The first still-current or future occurrence. This is intentionally
    /// separate from `nextDate`, which is the earliest unrecorded occurrence
    /// and can be a missed week while a parent catches up the schedule.
    public func nextCurrentOrFuturePayout(asOf now: Date = .now, calendar: Calendar = .current) -> Date? {
        let today = calendar.startOfDay(for: now)
        let inclusiveEndDate = endDate.map { calendar.startOfDay(for: $0) }
        var dueDate = calendar.startOfDay(for: nextDate)

        while dueDate < today {
            guard let followingDate = calendar.date(byAdding: .day, value: 7, to: dueDate) else { return nil }
            dueDate = followingDate
        }
        return inclusiveEndDate.map { dueDate <= $0 ? dueDate : nil } ?? dueDate
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
    /// Settles one scheduled loan payment. Distinct from `repayment`, which is
    /// the free-amount path a scheduleless loan has always used: an installment
    /// names no amount at all, because the amount is whatever the plan and the
    /// remaining balance decide.
    case loanInstallment
}

public struct WalletCommand: Sendable, Codable, Equatable {
    public let kind: WalletCommandKind
    public let amountCents: Int
    public let reason: String?
    public let dueDate: Date?
    /// Set only on a `loan` command whose parent chose an installment plan.
    public let installmentPlan: LoanInstallmentPlan?
    public let idempotencyKey: String

    public init(
        kind: WalletCommandKind,
        amountCents: Int,
        reason: String? = nil,
        dueDate: Date? = nil,
        installmentPlan: LoanInstallmentPlan? = nil,
        idempotencyKey: String = UUID().uuidString
    ) {
        self.kind = kind
        self.amountCents = amountCents
        self.reason = reason
        self.dueDate = dueDate
        self.installmentPlan = installmentPlan
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
    case acceptedScheduleUnavailable(WalletEvent, error: WalletAPIError)
    case pending(WalletEvent, diagnostic: TransportDiagnostic? = nil)
    case acceptedAwaitingReplica(WalletEvent, diagnostic: TransportDiagnostic? = nil)
    case rejected(WalletEvent)

    public var transportDiagnostic: TransportDiagnostic? {
        switch self {
        case .acceptedScheduleUnavailable(_, let error):
            error.transportDiagnostic
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
    case acceptedScheduleUnavailable
    case notRecorded

    public var syncState: SyncState {
        switch self {
        case .recorded: .recorded
        case .waitingForCloud, .acceptedAwaitingReplica, .acceptedScheduleUnavailable: .pending
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
        case .acceptedScheduleUnavailable:
            "Cloud accepted this change, but the latest allowance schedule could not be loaded. Refresh before paying out allowance."
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
            current.loan?.retireScheduleIfSettled()
        case .loanInstallment:
            guard let loan = current.loan, let payment = loan.nextInstallmentPaymentCents else {
                return .rejected(makeEvent(for: command, state: .rejected, explanation: "This loan payment was not recorded.", rejectionReason: "There is no scheduled loan payment to record."))
            }
            guard payment <= current.acceptedBalanceCents else {
                return .rejected(makeEvent(for: command, state: .rejected, explanation: "This loan payment was not recorded.", rejectionReason: "The payment is greater than the accepted balance."))
            }
            guard let settled = loan.recordingInstallment(paymentCents: payment, nextOccurrenceID: UUID().uuidString) else {
                return .rejected(makeEvent(for: command, state: .rejected, explanation: "This loan payment was not recorded.", rejectionReason: "There is no scheduled loan payment to record."))
            }
            current.acceptedBalanceCents -= payment
            current.loan = settled
            return .accepted(recordInstallmentEvent(for: command, paymentCents: payment))
        case .loan:
            guard current.loan == nil || current.loan?.isPaid == true else {
                return .rejected(makeEvent(for: command, state: .rejected, explanation: "This loan was not recorded.", rejectionReason: "Finish the open loan before creating another one."))
            }
            current.acceptedBalanceCents += command.amountCents
            current.loan = Loan(
                originalCents: command.amountCents,
                remainingCents: command.amountCents,
                purpose: command.reason,
                dueDate: command.dueDate,
                schedule: command.installmentPlan.map { LoanSchedule.opening($0) }
            )
        case .deposit:
            current.acceptedBalanceCents += command.amountCents
        case .allowance:
            current.acceptedBalanceCents += command.amountCents
            if let allowance = current.allowance {
                current.allowance = AllowancePlan(
                    remoteID: allowance.remoteID,
                    amountCents: allowance.amountCents,
                    cadence: allowance.cadence,
                    weekday: allowance.weekday,
                    nextDate: Calendar.current.date(byAdding: .day, value: 7, to: allowance.nextDate) ?? allowance.nextDate,
                    endDate: allowance.endDate,
                    nextOccurrenceID: allowance.nextOccurrenceID,
                    syncState: allowance.syncState
                )
            }
        }

        let event = makeEvent(for: command, state: .recorded, explanation: explanation(for: command))
        current.activities.insert(event, at: 0)
        current.lastUpdated = .now
        current.isStale = false
        return .accepted(event)
    }

    /// A recorded installment carries the amount the plan settled, not the
    /// zero the command names, and is dated on the day it was due.
    private func recordInstallmentEvent(for command: WalletCommand, paymentCents: Int) -> WalletEvent {
        let event = WalletEvent(
            type: .repayment,
            amountCents: paymentCents,
            reason: command.reason ?? LoanSchedule.defaultInstallmentReason,
            date: command.dueDate ?? .now,
            syncState: .recorded,
            explanation: "Your parent recorded \(Money(cents: paymentCents).display) returned toward the loan."
        )
        current.activities.insert(event, at: 0)
        current.lastUpdated = .now
        current.isStale = false
        return event
    }

    private func makeEvent(for command: WalletCommand, state: SyncState, explanation: String, rejectionReason: String? = nil) -> WalletEvent {
        let type: ActivityType = switch command.kind {
        case .allowance: .allowance
        case .deposit: .deposit
        case .withdrawal: .withdrawal
        case .loan: .loan
        case .repayment, .loanInstallment: .repayment
        }
        return WalletEvent(
            type: type,
            amountCents: command.amountCents,
            reason: command.reason,
            date: command.kind == .allowance ? (command.dueDate ?? .now) : .now,
            syncState: state,
            explanation: explanation,
            rejectionReason: rejectionReason
        )
    }

    private func explanation(for command: WalletCommand) -> String {
        let amount = Money(cents: command.amountCents).display
        switch command.kind {
        case .allowance: return "Your parent added \(amount) as your allowance."
        case .deposit: return "Your parent added \(amount) to your wallet."
        case .withdrawal: return "Your parent recorded that \(amount) was used."
        case .loan: return "Your parent gave you \(amount) to use now and give back over time."
        case .repayment, .loanInstallment: return "Your parent recorded \(amount) returned toward the loan."
        }
    }
}
