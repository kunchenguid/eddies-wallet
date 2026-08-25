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
        XCTAssertGreaterThan(fire, now)
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
        let fire = try XCTUnwrap(reminders.first?.fireDate)
        XCTAssertEqual(utc.component(.hour, from: fire), 8)
        XCTAssertGreaterThan(fire, now)
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

    func testForegroundSettlementDoesNotScheduleARecordedReminder() async throws {
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
        XCTAssertFalse(reminders.dueReminders.contains { $0.kind != .allowanceDue && $0.kind != .paymentDue })
        XCTAssertFalse(reminders.askedForAuthorization)
        assertGenericCopy(reminders.dueReminders)
    }

    func testLaterReadReschedulesTheNextDueDayAfterSettlement() async throws {
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
        XCTAssertEqual(reminders.dueReminders.map(\.kind), [.allowanceDue])
        let fire = try XCTUnwrap(reminders.dueReminders.first?.fireDate)
        XCTAssertEqual(calendar.startOfDay(for: fire), nextWeek)
        assertGenericCopy(reminders.dueReminders)
        XCTAssertFalse(reminders.dueReminders.contains { $0.title.contains("Maya") || $0.body.contains("Maya") })
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
        enterParentArea(store)

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
        assertGenericCopy(reminders.dueReminders)
    }

    func testAuthorizationIsNotRequestedIfElevationDropsDuringSettingsWait() async throws {
        let repository = try LocalWalletRepository(inMemory: true)
        _ = try await repository.setup(ParentSetup(nickname: "Maya"))
        let calendar = Calendar.current
        let nextWeek = try XCTUnwrap(calendar.date(byAdding: .day, value: 7, to: calendar.startOfDay(for: .now)))
        let reminders = RecordingScheduledReminderCenter()
        reminders.pauseBeforeAuthorizationCheck = true
        let store = WalletStore(
            repository: repository,
            initiallySignedIn: true,
            pinStore: InMemoryParentPINStore(pin: "1234"),
            identityStore: InMemoryParentIdentityStore(appleUserID: "owner"),
            reminderCenter: reminders
        )
        enterParentArea(store)

        let save = Task {
            await store.setAllowance(
                AllowanceRuleCommand(
                    amountCents: 500,
                    weekday: calendar.component(.weekday, from: nextWeek) - 1,
                    startDate: nextWeek
                )
            )
        }
        let paused = await waitUntil { reminders.isPausedForAuthorizationCheck }
        XCTAssertTrue(paused)
        store.handleAppBackgrounded()
        XCTAssertEqual(store.elevation, .none)
        reminders.continueAuthorizationCheck()
        _ = await save.value
        XCTAssertFalse(reminders.askedForAuthorization)
    }

    func testSignOutClearsPendingDueReminders() async throws {
        let reminders = RecordingScheduledReminderCenter()
        let store = WalletStore(
            repository: MockWalletRepository(snapshot: .fixture()),
            initiallySignedIn: true,
            pinStore: InMemoryParentPINStore(pin: "1234"),
            identityStore: InMemoryParentIdentityStore(appleUserID: "owner"),
            reminderCenter: reminders
        )
        await store.refresh()
        XCTAssertEqual(reminders.dueReminders.map(\.kind), [.allowanceDue])
        enterParentArea(store)
        store.signOut()
        XCTAssertTrue(reminders.didClearPending)
        XCTAssertTrue(reminders.dueReminders.isEmpty)
        XCTAssertFalse(store.isSignedIn)
    }

    func testAccountDeletionClearsPendingDueReminders() async throws {
        let reminders = RecordingScheduledReminderCenter()
        let store = WalletStore(
            repository: MockWalletRepository(snapshot: .fixture()),
            initiallySignedIn: true,
            pinStore: InMemoryParentPINStore(pin: "1234"),
            identityStore: InMemoryParentIdentityStore(appleUserID: "owner"),
            accountDeletionService: SucceedingAccountDeletionService(),
            reminderCenter: reminders
        )
        await store.refresh()
        XCTAssertEqual(reminders.dueReminders.map(\.kind), [.allowanceDue])
        enterParentArea(store)
        let outcome = await store.deleteAccount(idempotencyKey: "22222222-2222-4222-8222-222222222222")
        XCTAssertEqual(outcome, .deleted)
        XCTAssertTrue(reminders.didClearPending)
        XCTAssertTrue(reminders.dueReminders.isEmpty)
    }

    private func enterParentArea(_ store: WalletStore) {
        store.openParentGate()
        for digit in ["1", "2", "3", "4"] { store.appendPINDigit(digit) }
        XCTAssertEqual(store.elevation, .active)
    }

    private func waitUntil(_ probe: @escaping () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if probe() { return true }
            await Task.yield()
        }
        return probe()
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

@MainActor
private final class SucceedingAccountDeletionService: AccountDeletionPerforming {
    func preflightAccountDeletion() async throws {}
    func deleteAccount(idempotencyKey: String) async throws -> AccountDeletionResult { .deleted }
}
