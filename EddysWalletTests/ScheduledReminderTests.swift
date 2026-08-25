import XCTest
@testable import EddysWallet

@MainActor
final class ScheduledReminderTests: XCTestCase {
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    func testDueReminderFiresAtEightOnAFutureDueDay() throws {
        let due = try XCTUnwrap(utc.date(from: DateComponents(year: 2026, month: 9, day: 4)))
        let now = try XCTUnwrap(utc.date(from: DateComponents(year: 2026, month: 8, day: 25, hour: 15)))
        let reminders = ScheduledReminderPlanner.dueReminders(
            allowanceDue: due,
            paymentDue: nil,
            now: now,
            calendar: utc
        )
        XCTAssertEqual(reminders.map(\.id), ["ew.due.allowance"])
        XCTAssertEqual(reminders.map(\.kind), [.allowanceDue])
        let fire = try XCTUnwrap(reminders.first?.fireDate)
        XCTAssertEqual(utc.component(.hour, from: fire), 8)
        XCTAssertEqual(utc.startOfDay(for: fire), due)
        assertGenericCopy(reminders)
    }

    func testDueReminderOmitsTodayAfterEight() throws {
        let today = try XCTUnwrap(utc.date(from: DateComponents(year: 2026, month: 8, day: 25)))
        let now = try XCTUnwrap(utc.date(from: DateComponents(year: 2026, month: 8, day: 25, hour: 9)))
        XCTAssertTrue(
            ScheduledReminderPlanner.dueReminders(
                allowanceDue: today,
                paymentDue: nil,
                now: now,
                calendar: utc
            ).isEmpty
        )
    }

    func testDueReminderKeepsTodayBeforeEight() throws {
        let today = try XCTUnwrap(utc.date(from: DateComponents(year: 2026, month: 8, day: 25)))
        let now = try XCTUnwrap(utc.date(from: DateComponents(year: 2026, month: 8, day: 25, hour: 7, minute: 59)))
        let reminders = ScheduledReminderPlanner.dueReminders(
            allowanceDue: today,
            paymentDue: nil,
            now: now,
            calendar: utc
        )
        XCTAssertEqual(reminders.map(\.kind), [.allowanceDue])
        XCTAssertEqual(utc.component(.hour, from: try XCTUnwrap(reminders.first?.fireDate)), 8)
    }

    func testDueRemindersScheduleAllowanceAndPaymentSeparately() throws {
        let allowance = try XCTUnwrap(utc.date(from: DateComponents(year: 2026, month: 9, day: 4)))
        let payment = try XCTUnwrap(utc.date(from: DateComponents(year: 2026, month: 9, day: 11)))
        let now = try XCTUnwrap(utc.date(from: DateComponents(year: 2026, month: 8, day: 25, hour: 12)))
        let reminders = ScheduledReminderPlanner.dueReminders(
            allowanceDue: allowance,
            paymentDue: payment,
            now: now,
            calendar: utc
        )
        XCTAssertEqual(reminders.map(\.id), ["ew.due.allowance", "ew.due.payment"])
        XCTAssertEqual(reminders.map(\.kind), [.allowanceDue, .paymentDue])
        assertGenericCopy(reminders)
        XCTAssertFalse(reminders.contains { $0.title.localizedCaseInsensitiveContains("loan") })
    }

    func testSettledRemindersCoverLocalAutoPayAndIgnoreParentEntries() {
        let localAllowance = WalletEvent(type: .allowance, amountCents: 500, explanation: "Weekly allowance")
        let localPayment = WalletEvent(type: .repayment, amountCents: 400, explanation: "Scheduled payment")
        let parentAllowance = WalletEvent(
            type: .allowance,
            amountCents: 500,
            recordedBy: "parent",
            explanation: "Weekly allowance"
        )
        let deposit = WalletEvent(type: .deposit, amountCents: 1_000, explanation: "Chores")
        let cloudSettled = WalletEvent(
            type: .allowance,
            amountCents: 500,
            recordedBy: AcceptedEventCopy.scheduleActor,
            explanation: "Your allowance of US$5.00 was added."
        )
        let reminders = ScheduledReminderPlanner.settledReminders(
            locallySettled: [localAllowance, localPayment],
            newlyArrived: [parentAllowance, deposit, cloudSettled]
        )
        XCTAssertEqual(reminders.map(\.kind), [.allowanceRecorded, .paymentRecorded, .allowanceRecorded])
        XCTAssertTrue(reminders.contains { $0.id == "ew.recorded." + localAllowance.id.uuidString.lowercased() })
        XCTAssertTrue(reminders.contains { $0.id == "ew.recorded." + cloudSettled.id.uuidString.lowercased() })
        XCTAssertFalse(reminders.contains { $0.id.contains(parentAllowance.id.uuidString.lowercased()) })
        assertGenericCopy(reminders)
        XCTAssertFalse(reminders.contains { $0.title.contains("US$") || $0.body.contains("US$") })
        XCTAssertFalse(reminders.contains { $0.title.contains("$") || $0.body.contains("$") })
    }

    func testLocalReadStillSettlesWhenRemindersAreANoOp() async throws {
        let repository = try LocalWalletRepository(inMemory: true)
        _ = try await repository.setup(ParentSetup(nickname: "Maya"))
        let today = Calendar.current.startOfDay(for: .now)
        _ = try await repository.setAllowance(
            AllowanceRuleCommand(
                amountCents: 500,
                weekday: Calendar.current.component(.weekday, from: today) - 1,
                startDate: today
            )
        )
        let store = WalletStore(
            repository: repository,
            initiallySignedIn: true,
            pinStore: InMemoryParentPINStore(pin: "1234"),
            identityStore: InMemoryParentIdentityStore(appleUserID: "owner")
        )
        XCTAssertEqual(store.elevation, .none)
        await store.refresh()
        XCTAssertEqual(store.snapshot.acceptedBalanceCents, 500)
        XCTAssertEqual(store.snapshot.activities.filter { $0.type == .allowance }.count, 1)
    }

    func testFirstReachedReadDoesNotDeliverRecordedRemindersForLaunchSettlement() async throws {
        let repository = try LocalWalletRepository(inMemory: true)
        _ = try await repository.setup(ParentSetup(nickname: "Maya"))
        let today = Calendar.current.startOfDay(for: .now)
        _ = try await repository.setAllowance(
            AllowanceRuleCommand(
                amountCents: 500,
                weekday: Calendar.current.component(.weekday, from: today) - 1,
                startDate: today
            )
        )
        let reminders = RecordingScheduledReminderCenter()
        let store = WalletStore(
            repository: repository,
            initiallySignedIn: true,
            pinStore: InMemoryParentPINStore(pin: "1234"),
            identityStore: InMemoryParentIdentityStore(appleUserID: "owner"),
            reminderCenter: reminders
        )
        await store.refresh()
        XCTAssertEqual(store.snapshot.acceptedBalanceCents, 500)
        XCTAssertTrue(reminders.immediateReminders.isEmpty)
        XCTAssertFalse(reminders.askedForAuthorization)
        assertGenericCopy(reminders.dueReminders)
    }

    func testLaterReadDeliversRecordedReminderForNewlySettledAllowance() async throws {
        let repository = try LocalWalletRepository(inMemory: true)
        _ = try await repository.setup(ParentSetup(nickname: "Maya"))
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let nextWeek = try XCTUnwrap(calendar.date(byAdding: .day, value: 7, to: today))
        _ = try await repository.setAllowance(
            AllowanceRuleCommand(
                amountCents: 500,
                weekday: calendar.component(.weekday, from: nextWeek) - 1,
                startDate: nextWeek
            )
        )
        let reminders = RecordingScheduledReminderCenter()
        let store = WalletStore(
            repository: repository,
            initiallySignedIn: true,
            pinStore: InMemoryParentPINStore(pin: "1234"),
            identityStore: InMemoryParentIdentityStore(appleUserID: "owner"),
            reminderCenter: reminders
        )
        await store.refresh()
        XCTAssertEqual(store.snapshot.acceptedBalanceCents, 0)
        XCTAssertTrue(reminders.immediateReminders.isEmpty)
        XCTAssertEqual(reminders.dueReminders.map(\.kind), [.allowanceDue])

        _ = try await repository.setAllowance(
            AllowanceRuleCommand(
                amountCents: 500,
                weekday: calendar.component(.weekday, from: today) - 1,
                startDate: today
            )
        )
        await store.refresh()
        XCTAssertEqual(store.snapshot.acceptedBalanceCents, 500)
        XCTAssertEqual(reminders.immediateReminders.map(\.kind), [.allowanceRecorded])
        assertGenericCopy(reminders.immediateReminders)
        XCTAssertFalse(reminders.immediateReminders.contains { $0.title.contains("Maya") || $0.body.contains("Maya") })
        XCTAssertFalse(reminders.askedForAuthorization)
    }

    func testParentAllowanceEditAsksForAuthorizationAndReschedulesDueReminder() async throws {
        let repository = try LocalWalletRepository(inMemory: true)
        _ = try await repository.setup(ParentSetup(nickname: "Maya"))
        let calendar = Calendar.current
        let nextWeek = try XCTUnwrap(calendar.date(byAdding: .day, value: 7, to: calendar.startOfDay(for: .now)))
        let reminders = RecordingScheduledReminderCenter()
        let store = WalletStore(
            repository: repository,
            initiallySignedIn: true,
            pinStore: InMemoryParentPINStore(pin: "1234"),
            identityStore: InMemoryParentIdentityStore(appleUserID: "owner"),
            reminderCenter: reminders
        )
        store.openParentGate()
        for digit in ["1", "2", "3", "4"] { store.appendPINDigit(digit) }
        XCTAssertEqual(store.elevation, .active)

        let saved = await store.setAllowance(
            AllowanceRuleCommand(
                amountCents: 500,
                weekday: calendar.component(.weekday, from: nextWeek) - 1,
                startDate: nextWeek
            )
        )
        XCTAssertTrue(saved)
        XCTAssertTrue(reminders.askedForAuthorization)
        XCTAssertEqual(reminders.dueReminders.map(\.kind), [.allowanceDue])
        XCTAssertTrue(reminders.immediateReminders.isEmpty)
        assertGenericCopy(reminders.dueReminders)
    }

    private func assertGenericCopy(_ reminders: [ScheduledReminder]) {
        for reminder in reminders {
            XCTAssertFalse(reminder.title.isEmpty)
            XCTAssertEqual(reminder.body, ScheduledReminderCopy.body)
            XCTAssertFalse(reminder.title.contains("US$"))
            XCTAssertFalse(reminder.body.contains("US$"))
            XCTAssertFalse(reminder.title.contains("$"))
            XCTAssertFalse(reminder.body.contains("$"))
            XCTAssertFalse(reminder.title.contains("Maya"))
            XCTAssertFalse(reminder.body.contains("Maya"))
        }
    }
}
