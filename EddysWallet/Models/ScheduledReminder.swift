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
    private(set) var pausedAuthorizationCheckCount = 0
    var isPausedForAuthorizationCheck: Bool { pausedAuthorizationCheckCount > 0 }
    private var authorizationPauses: [CheckedContinuation<Void, Never>] = []
    private var generation = 0
    private let now: () -> Date

    init(now: @escaping () -> Date = { .now }) {
        self.now = now
    }

    func replaceDueReminders(
        _ reminders: [ScheduledReminder],
        stillAuthorized: @escaping @MainActor () -> Bool
    ) async {
        generation += 1
        let replacementGeneration = generation
        if pauseBeforeAuthorizationCheck {
            pausedAuthorizationCheckCount += 1
            await withCheckedContinuation { continuation in
                guard replacementGeneration == generation else {
                    continuation.resume()
                    return
                }
                authorizationPauses.append(continuation)
            }
            pausedAuthorizationCheckCount -= 1
            guard replacementGeneration == generation else { return }
        }
        askedForAuthorization = stillAuthorized()
        guard replacementGeneration == generation else { return }
        dueReminders = reminders.filter { $0.fireDate > now() }
    }

    func continueAuthorizationCheck() {
        resumeAuthorizationPause()
    }

    func clearPendingReminders() {
        generation += 1
        dueReminders = []
        didClearPending = true
        resumeAuthorizationPause()
    }

    private func resumeAuthorizationPause() {
        let pauses = authorizationPauses
        authorizationPauses = []
        for pause in pauses { pause.resume() }
    }
}

@MainActor
final class UserNotificationsReminderCenter: ScheduledReminderCentering {
    private static let dueIdentifiers = [
        ScheduledReminderPlanner.dueIdentifierPrefix + "allowance",
        ScheduledReminderPlanner.dueIdentifierPrefix + "payment",
    ]

    private let center: UNUserNotificationCenter
    private let now: () -> Date
    private var generation = 0
    private var replacementInFlight = false
    private var replacementWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        center: UNUserNotificationCenter = .current(),
        now: @escaping () -> Date = { .now }
    ) {
        self.center = center
        self.now = now
    }

    func replaceDueReminders(
        _ reminders: [ScheduledReminder],
        stillAuthorized: @escaping @MainActor () -> Bool
    ) async {
        generation += 1
        let replacementGeneration = generation
        while replacementInFlight {
            await withCheckedContinuation { continuation in
                guard replacementGeneration == generation else {
                    continuation.resume()
                    return
                }
                replacementWaiters.append(continuation)
            }
            guard replacementGeneration == generation else { return }
        }
        replacementInFlight = true
        defer { finishReplacement() }

        if stillAuthorized() {
            let settings = await center.notificationSettings()
            guard replacementGeneration == generation else { return }
            if settings.authorizationStatus == .notDetermined, stillAuthorized() {
                _ = try? await center.requestAuthorization(options: [.alert, .sound])
                guard replacementGeneration == generation else {
                    removeDueReminders()
                    return
                }
            }
        }
        guard replacementGeneration == generation else { return }
        removeDueReminders()
        for reminder in reminders {
            guard replacementGeneration == generation else { break }
            await add(reminder)
            guard replacementGeneration == generation else {
                removeDueReminders()
                return
            }
        }
    }

    func clearPendingReminders() {
        generation += 1
        removeDueReminders()
        resumeReplacementWaiters()
    }

    private func finishReplacement() {
        replacementInFlight = false
        resumeReplacementWaiters()
    }

    private func resumeReplacementWaiters() {
        let waiters = replacementWaiters
        replacementWaiters = []
        for waiter in waiters { waiter.resume() }
    }

    private func removeDueReminders() {
        center.removePendingNotificationRequests(withIdentifiers: Self.dueIdentifiers)
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
        guard reminder.fireDate > now() else { return }
        try? await center.add(request)
    }
}
