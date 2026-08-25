import Foundation
import UserNotifications

/// Local reminders for scheduled money. They are garnish: settlement still
/// happens on read whether these fire, are denied, or are never authorized.
/// Copy is content-generic (PRD 11): no child names, amounts, balances, or
/// loan details. Every reminder has a real future calendar trigger so the
/// system can present it with no app code at delivery.
enum ScheduledReminderCopy {
    static let allowanceDueTitle = "Allowance day"
    static let paymentDueTitle = "Payment day"
    static let body = "Open the wallet when you can."
}

public struct ScheduledReminder: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        case allowanceDue
        case paymentDue
    }

    public let id: String
    public let kind: Kind
    public let fireDate: Date

    public init(id: String, kind: Kind, fireDate: Date) {
        self.id = id
        self.kind = kind
        self.fireDate = fireDate
    }

    public var title: String {
        switch kind {
        case .allowanceDue: ScheduledReminderCopy.allowanceDueTitle
        case .paymentDue: ScheduledReminderCopy.paymentDueTitle
        }
    }

    public var body: String { ScheduledReminderCopy.body }
}

enum ScheduledReminderPlanner {
    static let dueHour = 8
    static let dueIdentifierPrefix = "ew.due."

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
    func replaceDueReminders(
        _ reminders: [ScheduledReminder],
        stillAuthorized: @escaping @MainActor () -> Bool
    ) async
    func clearPendingReminders()
}

@MainActor
final class NoOpScheduledReminderCenter: ScheduledReminderCentering {
    func replaceDueReminders(
        _ reminders: [ScheduledReminder],
        stillAuthorized: @escaping @MainActor () -> Bool
    ) async {}
    func clearPendingReminders() {}
}

@MainActor
final class RecordingScheduledReminderCenter: ScheduledReminderCentering {
    private(set) var dueReminders: [ScheduledReminder] = []
    private(set) var askedForAuthorization = false
    private(set) var didClearPending = false
    var pauseBeforeAuthorizationCheck = false
    private(set) var isPausedForAuthorizationCheck = false
    private var authorizationPause: CheckedContinuation<Void, Never>?

    func replaceDueReminders(
        _ reminders: [ScheduledReminder],
        stillAuthorized: @escaping @MainActor () -> Bool
    ) async {
        dueReminders = reminders
        if pauseBeforeAuthorizationCheck {
            isPausedForAuthorizationCheck = true
            await withCheckedContinuation { authorizationPause = $0 }
            isPausedForAuthorizationCheck = false
        }
        askedForAuthorization = stillAuthorized()
    }

    func continueAuthorizationCheck() {
        authorizationPause?.resume()
        authorizationPause = nil
    }

    func clearPendingReminders() {
        dueReminders = []
        didClearPending = true
    }
}

@MainActor
final class UserNotificationsReminderCenter: ScheduledReminderCentering {
    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    func replaceDueReminders(
        _ reminders: [ScheduledReminder],
        stillAuthorized: @escaping @MainActor () -> Bool
    ) async {
        if stillAuthorized() {
            let settings = await center.notificationSettings()
            if settings.authorizationStatus == .notDetermined, stillAuthorized() {
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

    func clearPendingReminders() {
        center.removePendingNotificationRequests(
            withIdentifiers: [
                ScheduledReminderPlanner.dueIdentifierPrefix + "allowance",
                ScheduledReminderPlanner.dueIdentifierPrefix + "payment",
            ]
        )
    }

    private func add(_ reminder: ScheduledReminder) async {
        let content = UNMutableNotificationContent()
        content.title = reminder.title
        content.body = reminder.body
        content.sound = .default
        let trigger = UNCalendarNotificationTrigger(
            dateMatching: Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute],
                from: reminder.fireDate
            ),
            repeats: false
        )
        let request = UNNotificationRequest(identifier: reminder.id, content: content, trigger: trigger)
        try? await center.add(request)
    }
}
