import Foundation

public enum UserRole: String, CaseIterable, Identifiable, Sendable {
    case parent
    case child

    public var id: String { rawValue }
    public var title: String { self == .parent ? "Parent" : "Eddie's view" }
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
    public let type: ActivityType
    public let amountCents: Int
    public let reason: String?
    public let date: Date
    public let syncState: SyncState
    public let explanation: String
    public let rejectionReason: String?

    public init(
        id: UUID = UUID(),
        type: ActivityType,
        amountCents: Int,
        reason: String? = nil,
        date: Date = .now,
        syncState: SyncState = .recorded,
        explanation: String,
        rejectionReason: String? = nil
    ) {
        self.id = id
        self.type = type
        self.amountCents = amountCents
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
    public let originalCents: Int
    public var remainingCents: Int
    public let purpose: String?
    public let dueDate: Date?

    public init(originalCents: Int, remainingCents: Int, purpose: String? = nil, dueDate: Date? = nil) {
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
    public let amountCents: Int
    public let cadence: String
    public let nextDate: Date
    public let syncState: SyncState

    public init(amountCents: Int, cadence: String, nextDate: Date, syncState: SyncState = .recorded) {
        self.amountCents = amountCents
        self.cadence = cadence
        self.nextDate = nextDate
        self.syncState = syncState
    }
}

public struct WalletSnapshot: Hashable, Codable, Sendable {
    public var acceptedBalanceCents: Int
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
        isStale: Bool
    ) {
        self.acceptedBalanceCents = acceptedBalanceCents
        self.activities = activities
        self.loan = loan
        self.allowance = allowance
        self.pendingEvents = pendingEvents
        self.lastUpdated = lastUpdated
        self.isStale = isStale
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
                WalletEvent(type: .loan, amountCents: 1_000, reason: "Bike helmet", date: loanDate, explanation: "Your parent gave you US$10.00 virtual dollars to use now, and US$10.00 to give back over time."),
                WalletEvent(type: .withdrawal, amountCents: 400, reason: "Comic book", date: withdrawalDate, explanation: "Your parent recorded that US$4.00 virtual dollars were used."),
                WalletEvent(type: .allowance, amountCents: 1_000, reason: "Weekly", date: allowanceDate, explanation: "Your parent added US$10.00 virtual dollars as your weekly allowance.")
            ],
            loan: Loan(originalCents: 1_000, remainingCents: 600, purpose: "Bike helmet", dueDate: dueDate),
            allowance: AllowancePlan(amountCents: 1_000, cadence: "every Friday", nextDate: calendar.date(byAdding: .day, value: 5, to: now) ?? now),
            pendingEvents: [
                WalletEvent(type: .deposit, amountCents: 500, reason: "Birthday practice", syncState: .pending, explanation: "This parent action is waiting to sync. It is not included in the accepted balance."),
                WalletEvent(type: .withdrawal, amountCents: 3_000, reason: "New bicycle", syncState: .rejected, explanation: "This withdrawal was not recorded because it is greater than the accepted wallet balance.", rejectionReason: "The amount is greater than the accepted balance.")
            ],
            lastUpdated: now.addingTimeInterval(-120),
            isStale: true
        )
    }
}

public enum WalletCommandKind: String, Sendable {
    case allowance
    case deposit
    case withdrawal
    case loan
    case repayment
}

public struct WalletCommand: Sendable {
    public let kind: WalletCommandKind
    public let amountCents: Int
    public let reason: String?
    public let dueDate: Date?

    public init(kind: WalletCommandKind, amountCents: Int, reason: String? = nil, dueDate: Date? = nil) {
        self.kind = kind
        self.amountCents = amountCents
        self.reason = reason
        self.dueDate = dueDate
    }
}

public enum CommandResult: Sendable {
    case accepted(WalletEvent)
    case pending(WalletEvent)
    case rejected(WalletEvent)
}

@MainActor
public protocol WalletRepository: AnyObject {
    func snapshot() -> WalletSnapshot
    func submit(_ command: WalletCommand) -> CommandResult
}

@MainActor
public final class MockWalletRepository: WalletRepository {
    private var current: WalletSnapshot

    public init(snapshot: WalletSnapshot = .fixture()) {
        self.current = snapshot
    }

    public func snapshot() -> WalletSnapshot { current }

    public func submit(_ command: WalletCommand) -> CommandResult {
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
            current.allowance = AllowancePlan(amountCents: command.amountCents, cadence: "every Friday", nextDate: command.dueDate ?? .now)
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
        case .allowance: return "Your parent added \(amount) virtual dollars as your allowance."
        case .deposit: return "Your parent added \(amount) virtual dollars to your wallet."
        case .withdrawal: return "Your parent recorded that \(amount) virtual dollars were used."
        case .loan: return "Your parent gave you \(amount) virtual dollars to use now and give back over time."
        case .repayment: return "Your parent recorded \(amount) virtual dollars returned toward the loan."
        }
    }
}
