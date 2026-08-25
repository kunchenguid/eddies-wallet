import CryptoKit
import Foundation

/// Kid-facing explanation for an accepted money event, shared by the local
/// authority and the Cloud replica so the same event never reads differently
/// depending on which authority accepted it.
enum AcceptedEventCopy {
    static func explanation(for type: ActivityType, amountCents: Int) -> String {
        let amount = Money(cents: amountCents).display
        return switch type {
        case .allowance: "Your parent added \(amount) as your allowance."
        case .deposit: "Your parent added \(amount) to your wallet."
        case .withdrawal: "Your parent recorded that \(amount) was used."
        case .loan: "Your parent gave you \(amount) to use now and give back over time."
        case .repayment: "Your parent paid \(amount) toward your loan."
        }
    }
}

/// Turns an accepted Cloud aggregate into the one-child snapshot the app
/// renders. Only server-accepted values are used; nothing is inferred.
enum CloudReplicaMapper {
    static func snapshot(
        from replica: CloudReplica,
        mergingInto existingEvents: [WalletEvent],
        fallbackNickname: String?
    ) -> WalletSnapshot {
        let mapped = replica.entries.compactMap(event(from:))
        var byRemoteID: [String: WalletEvent] = [:]
        for event in existingEvents + mapped {
            guard let remoteID = event.remoteID else { continue }
            byRemoteID[remoteID] = event
        }
        // Newest first, which is the order every wallet surface renders.
        let activities = byRemoteID.values.sorted { left, right in
            left.date == right.date ? (left.remoteID ?? "") > (right.remoteID ?? "") : left.date > right.date
        }
        let openLoan = replica.loans.filter { $0.status == "open" }.max(by: { $0.createdAt < $1.createdAt })
            ?? replica.loans.max(by: { $0.createdAt < $1.createdAt })
        return WalletSnapshot(
            acceptedBalanceCents: replica.wallet?.balanceCents ?? 0,
            activities: activities,
            loan: openLoan.map { loan(from: $0, occurrences: replica.loanOccurrences ?? []) },
            allowance: replica.allowanceRule.flatMap(allowance(from:)),
            pendingEvents: [],
            lastUpdated: .now,
            isStale: false,
            childNickname: ChildProfileCopy.configuredNickname(from: replica.child?.nickname) ?? fallbackNickname
        )
    }

    private static func event(from entry: CloudReplica.Entry) -> WalletEvent? {
        guard let type = ActivityType(rawValue: entry.type) else { return nil }
        return WalletEvent(
            id: stableID(for: entry.id),
            remoteID: entry.id,
            type: type,
            amountCents: entry.amountCents,
            balanceBeforeCents: entry.balanceBeforeCents,
            balanceAfterCents: entry.balanceAfterCents,
            reason: entry.reason,
            date: entry.recordedAt,
            syncState: .recorded,
            explanation: AcceptedEventCopy.explanation(for: type, amountCents: entry.amountCents)
        )
    }

    private static func stableID(for remoteID: String) -> UUID {
        if let id = UUID(uuidString: remoteID) {
            return id
        }
        var bytes = Array(SHA256.hash(data: Data(remoteID.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    /// The replica alone carries everything the installment reminder needs:
    /// the loan's durable plan and its occurrence chain. A loan with no plan
    /// correctly yields no schedule and therefore no reminder.
    private static func loan(
        from loan: CloudReplica.CloudLoan,
        occurrences: [CloudReplica.CloudLoanOccurrence]
    ) -> Loan {
        Loan(
            remoteID: loan.id,
            originalCents: loan.principalCents,
            remainingCents: loan.outstandingCents,
            purpose: loan.purpose,
            dueDate: loan.dueDate.flatMap(CloudDayFormat.date(from:)),
            schedule: schedule(from: loan, occurrences: occurrences)
        )
    }

    private static func schedule(
        from loan: CloudReplica.CloudLoan,
        occurrences: [CloudReplica.CloudLoanOccurrence]
    ) -> LoanSchedule? {
        guard let plan = loan.schedule,
              let cadence = LoanInstallmentCadence(rawValue: plan.cadence),
              let firstDueDate = CloudDayFormat.date(from: plan.firstDueDate) else { return nil }
        let mappedOccurrences = occurrences
            .filter { $0.loanID == loan.id }
            .compactMap { occurrence -> LoanSchedule.Occurrence? in
                guard let dueDate = CloudDayFormat.date(from: occurrence.dueOn),
                      let status = LoanSchedule.Occurrence.Status(rawValue: occurrence.status) else { return nil }
                return LoanSchedule.Occurrence(
                    id: occurrence.id,
                    dueDate: dueDate,
                    status: status,
                    amountCents: occurrence.amountCents,
                    entryID: occurrence.acceptedEntryID.map { stableID(for: $0) }
                )
            }
            .sorted { left, right in
                left.dueDate == right.dueDate ? left.id < right.id : left.dueDate < right.dueDate
            }
        return LoanSchedule(
            cadence: cadence,
            amountCents: plan.amountCents,
            firstDueDate: firstDueDate,
            occurrences: mappedOccurrences
        )
    }

    private static func allowance(from rule: CloudReplica.AllowanceRule) -> AllowancePlan? {
        guard rule.active != false, let startDate = rule.startDate.flatMap(CloudDayFormat.date(from:)) else { return nil }
        // Prefer the service-owned chain head when the replica carries it.
        // `/v1/cloud/changes` today omits it, so Cloud mode still overlays
        // `GET /v1/allowance-rule`; a handoff persists that overlay onto the
        // snapshot so local derivation never walks from the rule start date.
        let nextDate = rule.nextDueDate.flatMap(CloudDayFormat.date(from:)) ?? startDate
        return AllowancePlan(
            remoteID: rule.id,
            amountCents: rule.amountCents,
            cadence: rule.cadence == "weekly" ? "every week" : (rule.cadence ?? "every week"),
            weekday: rule.weekday ?? 5,
            nextDate: nextDate,
            endDate: rule.endDate.flatMap(CloudDayFormat.date(from:)),
            nextOccurrenceID: rule.nextOccurrenceID
        )
    }
}

/// `YYYY-MM-DD` calendar days, which the service uses for allowance and loan
/// due dates. These are parent-visible calendar days, not midnight instants:
/// use the device calendar so a west-of-UTC family never sees its scheduled
/// Friday decoded as Thursday.
enum CloudDayFormat {
    private static func formatter(calendar: Calendar) -> DateFormatter {
        var gregorianCalendar = Calendar(identifier: .gregorian)
        gregorianCalendar.timeZone = calendar.timeZone

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = gregorianCalendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }

    static func date(from raw: String) -> Date? {
        date(from: raw, calendar: .current)
    }

    static func date(from raw: String, calendar: Calendar) -> Date? {
        formatter(calendar: calendar).date(from: raw)
    }

    static func string(from date: Date) -> String {
        string(from: date, calendar: .current)
    }

    static func string(from date: Date, calendar: Calendar) -> String {
        formatter(calendar: calendar).string(from: date)
    }
}

/// Rebuilds the complete accepted history as an upload manifest.
///
/// The local snapshot keeps only the current loan, so loans are reconstructed
/// from the accepted event chain: every `loan` event opens a loan and later
/// `repayment` events pay down the most recent open one. That keeps the
/// server-side loan/repayment invariants satisfiable for older, already paid
/// loans as well.
enum CloudImportManifestBuilder {
    static func manifest(
        lineageID: UUID,
        operationID: UUID,
        familyName: String,
        nickname: String,
        snapshot: WalletSnapshot
    ) throws -> CloudImportManifest {
        // Oldest first: the server validates the chain in accepted order.
        let ordered = snapshot.activities.filter { $0.syncState == .recorded }.sorted { left, right in
            left.date == right.date ? left.id.uuidString < right.id.uuidString : left.date < right.date
        }
        var entries: [CloudImportManifest.Entry] = []
        var loans: [UUID: LoanAccumulator] = [:]
        var loanOrder: [UUID] = []
        var openLoanID: UUID?
        var balance = 0

        for event in ordered {
            let credit = event.isPositive
            let expected = credit ? balance + event.amountCents : balance - event.amountCents
            guard event.amountCents > 0, expected >= 0 else {
                throw WalletAPIError.invalidResponse("This wallet history cannot be uploaded until it is repaired.")
            }
            var loanID: UUID?
            switch event.type {
            case .loan:
                let identifier = event.id
                loans[identifier] = LoanAccumulator(
                    principalCents: event.amountCents,
                    repaidCents: 0,
                    purpose: event.reason,
                    createdAt: event.date,
                    paidAt: nil
                )
                loanOrder.append(identifier)
                openLoanID = identifier
                loanID = identifier
            case .repayment:
                guard let identifier = openLoanID, var accumulator = loans[identifier] else {
                    throw WalletAPIError.invalidResponse("This wallet history cannot be uploaded until it is repaired.")
                }
                accumulator.repaidCents += event.amountCents
                guard accumulator.repaidCents <= accumulator.principalCents else {
                    throw WalletAPIError.invalidResponse("This wallet history cannot be uploaded until it is repaired.")
                }
                if accumulator.repaidCents == accumulator.principalCents {
                    accumulator.paidAt = event.date
                    openLoanID = nil
                }
                loans[identifier] = accumulator
                loanID = identifier
            case .deposit, .withdrawal, .allowance:
                loanID = nil
            }
            entries.append(
                CloudImportManifest.Entry(
                    operationID: event.id,
                    type: event.type.rawValue,
                    direction: credit ? "credit" : "debit",
                    amountCents: event.amountCents,
                    balanceBeforeCents: balance,
                    balanceAfterCents: expected,
                    reason: event.reason,
                    loanID: loanID,
                    recordedAt: event.date
                )
            )
            balance = expected
        }

        guard balance == snapshot.acceptedBalanceCents else {
            throw WalletAPIError.invalidResponse("This wallet history cannot be uploaded until it is repaired.")
        }

        // Only the current loan carries a plan: older loans in the chain are
        // reconstructed from events alone and were never scheduled, so they
        // upload exactly as they always have.
        let currentLoanID = loanOrder.last
        let currentSchedule = currentLoanID.flatMap { _ in snapshot.loan?.schedule }
        let manifestLoans = loanOrder.compactMap { identifier -> CloudImportManifest.Loan? in
            guard let accumulator = loans[identifier] else { return nil }
            let outstanding = accumulator.principalCents - accumulator.repaidCents
            let isCurrent = identifier == currentLoanID
            return CloudImportManifest.Loan(
                id: identifier,
                principalCents: accumulator.principalCents,
                outstandingCents: outstanding,
                purpose: accumulator.purpose,
                dueDate: isCurrent ? snapshot.loan?.dueDate.map(CloudDayFormat.string(from:)) : nil,
                status: outstanding == 0 ? "paid" : "open",
                createdAt: accumulator.createdAt,
                paidAt: accumulator.paidAt,
                schedule: isCurrent ? currentSchedule.map { schedule in
                    CloudImportManifest.Loan.Schedule(
                        cadence: schedule.cadence.rawValue,
                        amountCents: schedule.amountCents,
                        firstDueDate: CloudDayFormat.string(from: schedule.firstDueDate)
                    )
                } : nil
            )
        }

        return CloudImportManifest(
            lineageID: lineageID,
            operationID: operationID,
            familyName: familyName,
            nickname: nickname,
            avatarURL: nil,
            loans: manifestLoans,
            entries: entries,
            loanOccurrences: try loanOccurrences(schedule: currentSchedule, loanID: currentLoanID),
            allowanceRule: allowanceRule(from: snapshot.allowance)
        )
    }

    /// The local chain head: local authority stores only the next unrecorded
    /// occurrence, not a separate original start date. Cadence on the wire is
    /// the Cloud `weekly` token so the imported rule matches `/v1/allowance-rule`.
    private static func allowanceRule(from plan: AllowancePlan?) -> CloudImportManifest.AllowanceRule? {
        guard let plan else { return nil }
        let nextDueDate = CloudDayFormat.string(from: plan.nextDate)
        return CloudImportManifest.AllowanceRule(
            id: plan.remoteID,
            amountCents: plan.amountCents,
            cadence: "weekly",
            weekday: plan.weekday,
            startDate: nextDueDate,
            endDate: plan.endDate.map { CloudDayFormat.string(from: $0) },
            active: true,
            nextOccurrenceID: plan.nextOccurrenceID,
            nextDueDate: nextDueDate
        )
    }

    /// The current loan's payment chain, in installment order, exactly as the
    /// record command would have built it. A recorded payment must name the
    /// accepted repayment that settled it, so a chain missing that link is
    /// refused here rather than by the server.
    private static func loanOccurrences(
        schedule: LoanSchedule?,
        loanID: UUID?
    ) throws -> [CloudImportManifest.LoanOccurrence] {
        guard let schedule, let loanID else { return [] }
        return try schedule.occurrences
            .sorted { $0.dueDate < $1.dueDate }
            .map { occurrence in
                if occurrence.status == .recorded, occurrence.entryID == nil {
                    throw WalletAPIError.invalidResponse("This wallet history cannot be uploaded until it is repaired.")
                }
                return CloudImportManifest.LoanOccurrence(
                    loanID: loanID,
                    dueOn: CloudDayFormat.string(from: occurrence.dueDate),
                    status: occurrence.status.rawValue,
                    entryOperationID: occurrence.status == .recorded ? occurrence.entryID : nil
                )
            }
    }

    private struct LoanAccumulator {
        let principalCents: Int
        var repaidCents: Int
        let purpose: String?
        let createdAt: Date
        var paidAt: Date?
    }
}
