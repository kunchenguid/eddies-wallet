import Foundation
import UserNotifications

/// Local reminders for scheduled money. They are garnish: settlement still
/// happens on read whether these fire, are denied, or are never authorized.
/// Copy is content-generic (PRD 11): no child names, amounts, balances, or
/// loan details.
enum ScheduledReminderCopy {
    static let allowanceDueTitle = "Allowance day"
    static let paymentDueTitle = "Payment day"
    static let allowanceRecordedTitle = "Allowance recorded"
    static let paymentRecordedTitle = "Payment recorded"
    static let body = "Open the wallet when you can."
}

public struct ScheduledReminder: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        case allowanceDue
        case paymentDue
        case allowanceRecorded
        case paymentRecorded
    }

    public let id: String
    public let kind: Kind
    public let fireDate: Date?

    public init(id: String, kind: Kind, fireDate: Date?) {
        self.id = id
        self.kind = kind
        self.fireDate = fireDate
    }

    public var title: String {
        switch kind {
        case .allowanceDue: ScheduledReminderCopy.allowanceDueTitle
        case .paymentDue: ScheduledReminderCopy.paymentDueTitle
        case .allowanceRecorded: ScheduledReminderCopy.allowanceRecordedTitle
        case .paymentRecorded: ScheduledReminderCopy.paymentRecordedTitle
        }
    }

    public var body: String { ScheduledReminderCopy.body }

    public var isImmediate: Bool { fireDate == nil }
}

enum ScheduledReminderPlanner {
    static let dueHour = 8
    static let dueIdentifierPrefix = "ew.due."
    static let recordedIdentifierPrefix = "ew.recorded."

    static func dueReminders(
        allowanceDue: Date?,
        paymentDue: Date?,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> [ScheduledReminder] {
        var reminders: [ScheduledReminder] = []
        if let fire = fireDate(on: allowanceDue, now: now, calendar: calendar) {
            reminders.append(
                ScheduledReminder(
                    id: dueIdentifierPrefix + "allowance",
                    kind: .allowanceDue,
                    fireDate: fire
                )
            )
        }
        if let fire = fireDate(on: paymentDue, now: now, calendar: calendar) {
            reminders.append(
                ScheduledReminder(
                    id: dueIdentifierPrefix + "payment",
                    kind: .paymentDue,
                    fireDate: fire
                )
            )
        }
        return reminders
    }

    static func settledReminders(
        locallySettled: [WalletEvent],
        newlyArrived: [WalletEvent]
    ) -> [ScheduledReminder] {
        let automatic = locallySettled + newlyArrived.filter { AcceptedEventCopy.isScheduleSettled($0.recordedBy) }
        return automatic.compactMap { event in
            let kind: ScheduledReminder.Kind
            switch event.type {
            case .allowance: kind = .allowanceRecorded
            case .repayment: kind = .paymentRecorded
            default: return nil
            }
            return ScheduledReminder(
                id: recordedIdentifierPrefix + event.id.uuidString.lowercased(),
                kind: kind,
                fireDate: nil
            )
        }
    }

    private static func fireDate(on due: Date?, now: Date, calendar: Calendar) -> Date? {
        guard let due else { return nil }
        var components = calendar.dateComponents([.year, .month, .day], from: calendar.startOfDay(for: due))
        components.hour = dueHour
        components.minute = 0
        components.second = 0
        guard let fire = calendar.date(from: components), fire > now else { return nil }
        return fire
    }
}

@MainActor
public protocol ScheduledReminderCentering: AnyObject {
    func replaceDueReminders(_ reminders: [ScheduledReminder], requestAuthorization: Bool) async
    func deliverImmediate(_ reminders: [ScheduledReminder]) async
}

@MainActor
final class NoOpScheduledReminderCenter: ScheduledReminderCentering {
    func replaceDueReminders(_ reminders: [ScheduledReminder], requestAuthorization: Bool) async {}
    func deliverImmediate(_ reminders: [ScheduledReminder]) async {}
}

@MainActor
final class RecordingScheduledReminderCenter: ScheduledReminderCentering {
    private(set) var dueReminders: [ScheduledReminder] = []
    private(set) var immediateReminders: [ScheduledReminder] = []
    private(set) var askedForAuthorization = false

    func replaceDueReminders(_ reminders: [ScheduledReminder], requestAuthorization: Bool) async {
        dueReminders = reminders
        if requestAuthorization { askedForAuthorization = true }
    }

    func deliverImmediate(_ reminders: [ScheduledReminder]) async {
        immediateReminders.append(contentsOf: reminders)
    }
}

@MainActor
final class UserNotificationsReminderCenter: ScheduledReminderCentering {
    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    func replaceDueReminders(_ reminders: [ScheduledReminder], requestAuthorization: Bool) async {
        if requestAuthorization {
            let settings = await center.notificationSettings()
            if settings.authorizationStatus == .notDetermined {
                _ = try? await center.requestAuthorization(options: [.alert, .sound])
            }
        }
        center.removePendingNotificationRequests(
            withIdentifiers: [
                ScheduledReminderPlanner.dueIdentifierPrefix + "allowance",
                ScheduledReminderPlanner.dueIdentifierPrefix + "payment",
            ]
        )
        for reminder in reminders {
            await add(reminder)
        }
    }

    func deliverImmediate(_ reminders: [ScheduledReminder]) async {
        for reminder in reminders {
            await add(reminder)
        }
    }

    private func add(_ reminder: ScheduledReminder) async {
        let content = UNMutableNotificationContent()
        content.title = reminder.title
        content.body = reminder.body
        content.sound = .default
        let trigger: UNNotificationTrigger?
        if let fireDate = reminder.fireDate {
            trigger = UNCalendarNotificationTrigger(
                dateMatching: Calendar.current.dateComponents(
                    [.year, .month, .day, .hour, .minute],
                    from: fireDate
                ),
                repeats: false
            )
        } else {
            trigger = nil
        }
        let request = UNNotificationRequest(identifier: reminder.id, content: content, trigger: trigger)
        try? await center.add(request)
    }
}
