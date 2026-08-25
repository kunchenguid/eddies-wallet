import XCTest
@testable import EddysWallet

@MainActor
final class LocalWalletPersistenceTests: XCTestCase {
    func testFreeLocalWalletRecordsEveryCoreMoneyFlowWithoutNetwork() async throws {
        let repository = try LocalWalletRepository(inMemory: true)
        _ = try await repository.setup(ParentSetup(nickname: "Test Kid"))
        _ = try await repository.setAllowance(AllowanceRuleCommand(amountCents: 500, weekday: 1, startDate: .now))
        _ = try await repository.submit(WalletCommand(kind: .deposit, amountCents: 1_000))
        _ = try await repository.submit(WalletCommand(kind: .withdrawal, amountCents: 200))
        _ = try await repository.submit(WalletCommand(kind: .loan, amountCents: 400, reason: "Practice"))
        let repayment = try await repository.submit(WalletCommand(kind: .repayment, amountCents: 100))

        guard case .accepted(let event) = repayment else { return XCTFail("Local repayment should be recorded") }
        XCTAssertEqual(event.syncState, .recorded)
        XCTAssertEqual(repository.snapshot().acceptedBalanceCents, 1_100)
        XCTAssertEqual(repository.snapshot().loan?.remainingCents, 300)
        XCTAssertEqual(repository.snapshot().allowance?.amountCents, 500)
        XCTAssertFalse(repository.snapshot().isStale)
        XCTAssertTrue(repository.snapshot().pendingEvents.isEmpty)
    }

    func testLocalMissedAllowanceRecordAllSettlesOnlyPastWeeksAndLeavesTodayForTheSinglePath() async throws {
        let repository = try LocalWalletRepository(inMemory: true)
        _ = try await repository.setup(ParentSetup(nickname: "Test Kid"))
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let firstMissed = try XCTUnwrap(calendar.date(byAdding: .day, value: -28, to: today))
        _ = try await repository.setAllowance(
            AllowanceRuleCommand(amountCents: 500, weekday: calendar.component(.weekday, from: firstMissed) - 1, startDate: firstMissed)
        )
        let store = WalletStore(
            repository: repository,
            initiallySignedIn: true,
            pinStore: InMemoryParentPINStore(pin: "1234"),
            identityStore: InMemoryParentIdentityStore(appleUserID: "owner")
        )
        store.openParentGate()
        for digit in ["1", "2", "3", "4"] { store.appendPINDigit(digit) }

        XCTAssertEqual(store.missedAllowancePayouts.count, 4)
        XCTAssertEqual(store.missedAllowancePayouts.totalCents, 2_000)
        XCTAssertEqual(store.missedAllowancePayouts.occurrences.map(\.dueDate), [
            firstMissed,
            try XCTUnwrap(calendar.date(byAdding: .day, value: 7, to: firstMissed)),
            try XCTUnwrap(calendar.date(byAdding: .day, value: 14, to: firstMissed)),
            try XCTUnwrap(calendar.date(byAdding: .day, value: 21, to: firstMissed)),
        ])
        XCTAssertEqual(
            calendar.startOfDay(for: try XCTUnwrap(store.snapshot.allowance?.nextCurrentOrFuturePayout(calendar: calendar))),
            today
        )

        let outcome = await store.recordAllMissedAllowance()
        XCTAssertEqual(outcome, .recorded(count: 4, totalCents: 2_000))
        XCTAssertEqual(store.snapshot.acceptedBalanceCents, 2_000)
        XCTAssertEqual(store.snapshot.activities.filter { $0.type == .allowance }.count, 4)
        XCTAssertEqual(calendar.startOfDay(for: try XCTUnwrap(store.snapshot.allowance?.nextDate)), today)
        XCTAssertTrue(store.missedAllowancePayouts.isEmpty)

        let noOpBalance = store.snapshot.acceptedBalanceCents
        let noOp = await store.recordAllMissedAllowance()
        XCTAssertEqual(noOp, .noMissed)
        XCTAssertEqual(store.snapshot.acceptedBalanceCents, noOpBalance)
    }

    func testLocalAllowanceRecordingNamesTheAcceptedEntryAndKeepsOneScheduledHead() async throws {
        let repository = try LocalWalletRepository(inMemory: true)
        _ = try await repository.setup(ParentSetup(nickname: "Test Kid"))
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let firstMissed = try XCTUnwrap(calendar.date(byAdding: .day, value: -28, to: today))
        _ = try await repository.setAllowance(
            AllowanceRuleCommand(
                amountCents: 500,
                weekday: calendar.component(.weekday, from: firstMissed) - 1,
                startDate: firstMissed,
                idempotencyKey: "allowance-head"
            )
        )
        let seeded = try XCTUnwrap(repository.snapshot().allowance)
        XCTAssertEqual(seeded.occurrences.map(\.id), ["allowance-head"])
        XCTAssertEqual(seeded.occurrences.map(\.status), [.scheduled])

        let store = WalletStore(
            repository: repository,
            initiallySignedIn: true,
            pinStore: InMemoryParentPINStore(pin: "1234"),
            identityStore: InMemoryParentIdentityStore(appleUserID: "owner")
        )
        store.openParentGate()
        for digit in ["1", "2", "3", "4"] { store.appendPINDigit(digit) }

        let outcome = await store.recordAllMissedAllowance()
        XCTAssertEqual(outcome, .recorded(count: 4, totalCents: 2_000))

        let plan = try XCTUnwrap(store.snapshot.allowance)
        XCTAssertEqual(plan.occurrences.filter { $0.status == .scheduled }.count, 1)
        XCTAssertEqual(calendar.startOfDay(for: try XCTUnwrap(plan.nextOccurrence?.dueDate)), today)
        XCTAssertEqual(plan.occurrences.filter { $0.status == .recorded }.count, 4)
        let recorded = plan.occurrences.filter { $0.status == .recorded }
        let allowanceEntries = store.snapshot.activities.filter { $0.type == .allowance }
        XCTAssertEqual(recorded.map(\.entryID), allowanceEntries.reversed().map(\.id))
        XCTAssertEqual(recorded.map(\.amountCents), [500, 500, 500, 500])
        XCTAssertEqual(
            recorded.map { calendar.startOfDay(for: $0.dueDate) },
            [
                firstMissed,
                try XCTUnwrap(calendar.date(byAdding: .day, value: 7, to: firstMissed)),
                try XCTUnwrap(calendar.date(byAdding: .day, value: 14, to: firstMissed)),
                try XCTUnwrap(calendar.date(byAdding: .day, value: 21, to: firstMissed)),
            ]
        )
    }

    func testAllowancePlanRejectsMultipleScheduledOccurrences() throws {
        let firstDate = Calendar.current.startOfDay(for: .now)
        let secondDate = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: 7, to: firstDate))
        let occurrences: [AllowancePlan.Occurrence] = [
            .init(id: "stale-head", dueDate: firstDate, status: .scheduled),
            .init(id: "current-head", dueDate: secondDate, status: .scheduled),
        ]
        struct EncodedAllowance: Encodable {
            let amountCents: Int
            let cadence: String
            let weekday: Int
            let nextDate: Date
            let nextOccurrenceID: String
            let syncState: SyncState
            let occurrences: [AllowancePlan.Occurrence]
        }
        let encoded = EncodedAllowance(
            amountCents: 500,
            cadence: "every week",
            weekday: 5,
            nextDate: secondDate,
            nextOccurrenceID: "current-head",
            syncState: .recorded,
            occurrences: occurrences
        )

        XCTAssertThrowsError(
            try AllowancePlan(
                amountCents: 500,
                cadence: "every week",
                nextDate: secondDate,
                nextOccurrenceID: "current-head",
                occurrences: occurrences
            )
        )
        XCTAssertThrowsError(
            try JSONDecoder().decode(AllowancePlan.self, from: JSONEncoder().encode(encoded))
        )
    }

    func testAllowancePlanRejectsRecordedOccurrenceWithoutEntry() throws {
        let dueDate = Calendar.current.startOfDay(for: .now)
        let occurrences: [AllowancePlan.Occurrence] = [
            .init(id: "recorded", dueDate: dueDate, status: .recorded, amountCents: 500),
        ]
        struct EncodedAllowance: Encodable {
            let amountCents: Int
            let cadence: String
            let weekday: Int
            let nextDate: Date
            let syncState: SyncState
            let occurrences: [AllowancePlan.Occurrence]
        }
        let encoded = EncodedAllowance(
            amountCents: 500,
            cadence: "every week",
            weekday: 5,
            nextDate: dueDate,
            syncState: .recorded,
            occurrences: occurrences
        )

        XCTAssertThrowsError(
            try AllowancePlan(
                amountCents: 500,
                cadence: "every week",
                nextDate: dueDate,
                isExhausted: true,
                occurrences: occurrences
            )
        )
        XCTAssertThrowsError(
            try JSONDecoder().decode(AllowancePlan.self, from: JSONEncoder().encode(encoded))
        )
    }

    func testAllowancePlanRejectsDuplicateOccurrenceIDs() throws {
        let calendar = Calendar.current
        let firstDate = calendar.startOfDay(for: .now)
        let secondDate = try XCTUnwrap(calendar.date(byAdding: .day, value: 7, to: firstDate))
        let entryID = UUID()
        struct EncodedAllowance: Encodable {
            let amountCents: Int
            let cadence: String
            let weekday: Int
            let nextDate: Date
            let nextOccurrenceID: String
            let syncState: SyncState
            let occurrences: [AllowancePlan.Occurrence]
        }
        let encoded = EncodedAllowance(
            amountCents: 500,
            cadence: "every week",
            weekday: 5,
            nextDate: secondDate,
            nextOccurrenceID: "duplicate",
            syncState: .recorded,
            occurrences: [
                .init(
                    id: "duplicate",
                    dueDate: firstDate,
                    status: .recorded,
                    amountCents: 500,
                    entryID: entryID
                ),
                .init(id: "duplicate", dueDate: secondDate, status: .scheduled),
            ]
        )

        XCTAssertThrowsError(
            try JSONDecoder().decode(AllowancePlan.self, from: JSONEncoder().encode(encoded))
        )

        XCTAssertThrowsError(
            try AllowancePlan(
                amountCents: 500,
                cadence: "every week",
                nextDate: secondDate,
                nextOccurrenceID: "duplicate",
                occurrences: encoded.occurrences
            )
        )
    }

    func testAllowancePlanRejectsServiceHeadCollidingWithRecordedOccurrence() throws {
        let firstDate = Calendar.current.startOfDay(for: .now)
        let secondDate = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: 7, to: firstDate))
        let plan = try AllowancePlan(
            amountCents: 500,
            cadence: "every week",
            nextDate: secondDate,
            nextOccurrenceID: "current-head",
            occurrences: [
                .init(
                    id: "recorded",
                    dueDate: firstDate,
                    status: .recorded,
                    amountCents: 500,
                    entryID: UUID()
                ),
                .init(id: "current-head", dueDate: secondDate, status: .scheduled),
            ]
        )

        XCTAssertThrowsError(
            try plan.applyingServiceHead(
                nextDate: secondDate,
                nextOccurrenceID: "recorded",
                isExhausted: false
            )
        )
        XCTAssertThrowsError(
            try plan.applyingServiceHead(
                nextDate: nil,
                nextOccurrenceID: nil,
                isExhausted: false
            )
        )
    }

    func testAllowancePlanRejectsHeadExhaustionMismatches() throws {
        let dueDate = Calendar.current.startOfDay(for: .now)
        let entryID = UUID()

        XCTAssertThrowsError(
            try AllowancePlan(
                amountCents: 500,
                cadence: "every week",
                nextDate: dueDate,
                isExhausted: true,
                occurrences: [.init(id: "head", dueDate: dueDate, status: .scheduled)]
            )
        )
        let recordedOnly = try AllowancePlan(
            amountCents: 500,
            cadence: "every week",
            nextDate: dueDate,
            occurrences: [
                .init(
                    id: "recorded",
                    dueDate: dueDate,
                    status: .recorded,
                    amountCents: 500,
                    entryID: entryID
                ),
            ]
        )
        XCTAssertNil(recordedOnly.nextOccurrence)
        XCTAssertTrue(recordedOnly.missedPayouts().isEmpty)
        let suppressed = try AllowancePlan(
            amountCents: 500,
            cadence: "every week",
            nextDate: dueDate,
            occurrences: []
        )
        XCTAssertTrue(suppressed.occurrences.isEmpty)
        XCTAssertNil(suppressed.nextOccurrence)
        XCTAssertTrue(suppressed.missedPayouts().isEmpty)
        let exhausted = try AllowancePlan(
            amountCents: 500,
            cadence: "every week",
            nextDate: dueDate,
            isExhausted: true,
            occurrences: []
        )
        XCTAssertTrue(exhausted.occurrences.isEmpty)
        XCTAssertNil(exhausted.nextOccurrence)
    }

    func testAllowancePlanRejectsEmptyOccurrenceID() throws {
        let dueDate = Calendar.current.startOfDay(for: .now)
        let occurrences: [AllowancePlan.Occurrence] = [
            .init(id: "", dueDate: dueDate, status: .scheduled),
        ]
        struct EncodedAllowance: Encodable {
            let amountCents: Int
            let cadence: String
            let weekday: Int
            let nextDate: Date
            let syncState: SyncState
            let occurrences: [AllowancePlan.Occurrence]
        }
        let encoded = EncodedAllowance(
            amountCents: 500,
            cadence: "every week",
            weekday: 5,
            nextDate: dueDate,
            syncState: .recorded,
            occurrences: occurrences
        )

        XCTAssertThrowsError(
            try AllowancePlan(
                amountCents: 500,
                cadence: "every week",
                nextDate: dueDate,
                occurrences: occurrences
            )
        )
        XCTAssertThrowsError(
            try JSONDecoder().decode(AllowancePlan.self, from: JSONEncoder().encode(encoded))
        )
    }

    func testAllowancePlanDecodingAcceptsExplicitEmptyLiveChainAsSuppressedHead() throws {
        let dueDate = Calendar.current.startOfDay(for: .now)
        struct EncodedAllowance: Encodable {
            let amountCents: Int
            let cadence: String
            let weekday: Int
            let nextDate: Date
            let syncState: SyncState
            let occurrences: [AllowancePlan.Occurrence]
        }
        let encoded = EncodedAllowance(
            amountCents: 500,
            cadence: "every week",
            weekday: 5,
            nextDate: dueDate,
            syncState: .recorded,
            occurrences: []
        )

        let plan = try JSONDecoder().decode(AllowancePlan.self, from: JSONEncoder().encode(encoded))
        XCTAssertTrue(plan.occurrences.isEmpty)
        XCTAssertNil(plan.nextOccurrence)
        XCTAssertNil(plan.nextOccurrenceID)
        XCTAssertTrue(plan.missedPayouts().isEmpty)
        XCTAssertNil(plan.nextCurrentOrFuturePayout())
    }

    func testMockAllowanceRecordingLinksOccurrenceToAcceptedEvent() async throws {
        let dueDate = Calendar.current.startOfDay(for: .now)
        let repository = MockWalletRepository(
            snapshot: WalletSnapshot(
                acceptedBalanceCents: 0,
                activities: [],
                loan: nil,
                allowance: try AllowancePlan(
                    amountCents: 500,
                    cadence: "every week",
                    weekday: 5,
                    nextDate: dueDate,
                    nextOccurrenceID: "allowance-head"
                ),
                pendingEvents: [],
                lastUpdated: .now,
                isStale: false
            )
        )

        let result = try await repository.submit(
            WalletCommand(kind: .allowance, amountCents: 500, dueDate: dueDate)
        )
        guard case .accepted(let event) = result else {
            return XCTFail("The scheduled allowance should be accepted")
        }
        let plan = try XCTUnwrap(repository.snapshot().allowance)
        let recorded = try XCTUnwrap(plan.occurrences.first { $0.status == .recorded })

        XCTAssertEqual(recorded.entryID, event.id)
        XCTAssertEqual(repository.snapshot().activities.first?.id, event.id)
        XCTAssertEqual(plan.occurrences.filter { $0.status == .scheduled }.count, 1)
    }

    func testMockRejectsAllowanceAmountThatDoesNotMatchPlan() async throws {
        let dueDate = Calendar.current.startOfDay(for: .now)
        let repository = MockWalletRepository(
            snapshot: WalletSnapshot(
                acceptedBalanceCents: 100,
                activities: [],
                loan: nil,
                allowance: try AllowancePlan(
                    amountCents: 500,
                    cadence: "every week",
                    weekday: 5,
                    nextDate: dueDate,
                    nextOccurrenceID: "allowance-head"
                ),
                pendingEvents: [],
                lastUpdated: .now,
                isStale: false
            )
        )

        let result = try await repository.submit(
            WalletCommand(kind: .allowance, amountCents: 400, dueDate: dueDate)
        )
        guard case .rejected = result else {
            return XCTFail("A mismatched allowance amount should be rejected")
        }

        XCTAssertEqual(repository.snapshot().acceptedBalanceCents, 100)
        XCTAssertTrue(repository.snapshot().activities.isEmpty)
        XCTAssertEqual(repository.snapshot().allowance?.nextOccurrence?.id, "allowance-head")
    }

    func testLegacyAllowanceSnapshotWithoutOccurrencesStillDerivesTheSameMissedWeeks() throws {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let firstMissed = try XCTUnwrap(calendar.date(byAdding: .day, value: -21, to: today))
        struct LegacyAllowance: Encodable {
            let amountCents: Int
            let cadence: String
            let weekday: Int
            let nextDate: Date
            let nextOccurrenceID: String
            let syncState: SyncState
        }
        let data = try JSONEncoder().encode(
            LegacyAllowance(
                amountCents: 500,
                cadence: "every week",
                weekday: 5,
                nextDate: firstMissed,
                nextOccurrenceID: "legacy-head",
                syncState: .recorded
            )
        )
        let plan = try JSONDecoder().decode(AllowancePlan.self, from: data)

        XCTAssertEqual(plan.occurrences.map(\.id), ["legacy-head"])
        XCTAssertEqual(plan.occurrences.map(\.status), [.scheduled])
        XCTAssertEqual(plan.missedPayouts(asOf: today, calendar: calendar).count, 3)
        XCTAssertEqual(
            plan.missedPayouts(asOf: today, calendar: calendar).occurrences.map { calendar.startOfDay(for: $0.dueDate) },
            [
                firstMissed,
                try XCTUnwrap(calendar.date(byAdding: .day, value: 7, to: firstMissed)),
                try XCTUnwrap(calendar.date(byAdding: .day, value: 14, to: firstMissed)),
            ]
        )
        XCTAssertEqual(plan.nextCurrentOrFuturePayout(asOf: today, calendar: calendar), today)
    }

    func testInterruptedLocalRecordAllKeepsAcceptedPrefixAndResumesWithoutDuplicates() async throws {
        let persistence = ControllableLocalWalletPersistence()
        let repository = try LocalWalletRepository(persistence: persistence)
        _ = try await repository.setup(ParentSetup(nickname: "Test Kid"))
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let firstMissed = try XCTUnwrap(calendar.date(byAdding: .day, value: -28, to: today))
        _ = try await repository.setAllowance(
            AllowanceRuleCommand(amountCents: 500, weekday: calendar.component(.weekday, from: firstMissed) - 1, startDate: firstMissed)
        )
        let store = WalletStore(
            repository: repository,
            initiallySignedIn: true,
            pinStore: InMemoryParentPINStore(pin: "1234"),
            identityStore: InMemoryParentIdentityStore(appleUserID: "owner")
        )
        store.openParentGate()
        for digit in ["1", "2", "3", "4"] { store.appendPINDigit(digit) }
        persistence.failOnNextSaveNumber = persistence.saveCount + 2

        let interrupted = await store.recordAllMissedAllowance()
        guard case .partial(let recordedCount, let recordedTotalCents, let remaining) = interrupted else {
            return XCTFail("a failed second save must leave a partial settlement")
        }
        XCTAssertEqual(recordedCount, 1)
        XCTAssertEqual(recordedTotalCents, 500)
        XCTAssertEqual(remaining.count, 3)
        XCTAssertEqual(store.snapshot.acceptedBalanceCents, 500)
        XCTAssertEqual(store.snapshot.activities.filter { $0.type == .allowance }.count, 1)
        XCTAssertEqual(store.missedAllowancePayouts.count, 3)

        let resumed = await store.recordAllMissedAllowance()
        XCTAssertEqual(resumed, .recorded(count: 3, totalCents: 1_500))
        XCTAssertEqual(store.snapshot.acceptedBalanceCents, 2_000)
        XCTAssertEqual(store.snapshot.activities.filter { $0.type == .allowance }.count, 4)
        XCTAssertTrue(store.missedAllowancePayouts.isEmpty)
    }

    func testDueScheduledPayoutsIncludeTodayAndMissedPayoutsDoNot() throws {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let firstMissed = try XCTUnwrap(calendar.date(byAdding: .day, value: -14, to: today))
        let plan = try AllowancePlan(
            amountCents: 500,
            cadence: "every week",
            weekday: calendar.component(.weekday, from: firstMissed) - 1,
            nextDate: firstMissed,
            nextOccurrenceID: "head"
        )

        XCTAssertEqual(plan.missedPayouts(asOf: today, calendar: calendar).count, 2)
        XCTAssertEqual(plan.dueScheduledPayouts(asOf: today, calendar: calendar).count, 3)
        XCTAssertEqual(
            plan.dueScheduledPayouts(asOf: today, calendar: calendar).map { calendar.startOfDay(for: $0.dueDate) }.last,
            today
        )
    }

    func testLocalReadAutoSettlesTodayAllowanceWithoutParentElevation() async throws {
        let repository = try LocalWalletRepository(inMemory: true)
        _ = try await repository.setup(ParentSetup(nickname: "Test Kid"))
        let today = Calendar.current.startOfDay(for: .now)
        _ = try await repository.setAllowance(
            AllowanceRuleCommand(amountCents: 500, weekday: Calendar.current.component(.weekday, from: today) - 1, startDate: today)
        )

        let store = WalletStore(
            repository: repository,
            initiallySignedIn: true,
            pinStore: InMemoryParentPINStore(pin: "1234"),
            identityStore: InMemoryParentIdentityStore(appleUserID: "owner")
        )
        XCTAssertEqual(store.elevation, .none)

        await store.refresh()

        XCTAssertEqual(store.elevation, .none)
        XCTAssertEqual(store.snapshot.acceptedBalanceCents, 500)
        XCTAssertEqual(store.snapshot.activities.filter { $0.type == .allowance }.count, 1)
        XCTAssertEqual(
            Calendar.current.startOfDay(for: try XCTUnwrap(store.snapshot.allowance?.nextDate)),
            try XCTUnwrap(Calendar.current.date(byAdding: .day, value: 7, to: today))
        )

        let rejected = await store.submit(WalletCommand(kind: .deposit, amountCents: 100))
        guard case .rejected(let event) = rejected else {
            return XCTFail("manual submit still requires parent elevation")
        }
        XCTAssertEqual(event.rejectionReason, "Only a parent in the Parent area can record virtual money events.")
    }

    func testLocalReadAutoSettlesSmallAllowanceBacklogIncludingToday() async throws {
        let repository = try LocalWalletRepository(inMemory: true)
        _ = try await repository.setup(ParentSetup(nickname: "Test Kid"))
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let firstDue = try XCTUnwrap(calendar.date(byAdding: .day, value: -14, to: today))
        _ = try await repository.setAllowance(
            AllowanceRuleCommand(amountCents: 500, weekday: calendar.component(.weekday, from: firstDue) - 1, startDate: firstDue)
        )
        XCTAssertEqual(repository.snapshot().allowance?.dueScheduledPayouts().count, 3)

        await repository.applyDueScheduledSettlements()

        XCTAssertEqual(repository.snapshot().acceptedBalanceCents, 1_500)
        XCTAssertEqual(repository.snapshot().activities.filter { $0.type == .allowance }.count, 3)
        XCTAssertTrue(repository.snapshot().allowance?.missedPayouts().isEmpty ?? false)
        XCTAssertEqual(
            calendar.startOfDay(for: try XCTUnwrap(repository.snapshot().allowance?.nextDate)),
            try XCTUnwrap(calendar.date(byAdding: .day, value: 7, to: today))
        )
    }

    func testLocalReadSkipsAllowanceAutoSettleWhenBacklogExceedsCap() async throws {
        let repository = try LocalWalletRepository(inMemory: true)
        _ = try await repository.setup(ParentSetup(nickname: "Test Kid"))
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let firstDue = try XCTUnwrap(calendar.date(byAdding: .day, value: -28, to: today))
        _ = try await repository.setAllowance(
            AllowanceRuleCommand(amountCents: 500, weekday: calendar.component(.weekday, from: firstDue) - 1, startDate: firstDue)
        )
        XCTAssertEqual(repository.snapshot().allowance?.dueScheduledPayouts().count, 5)

        await repository.applyDueScheduledSettlements()

        XCTAssertEqual(repository.snapshot().acceptedBalanceCents, 0)
        XCTAssertTrue(repository.snapshot().activities.isEmpty)
        XCTAssertEqual(repository.snapshot().allowance?.missedPayouts().count, 4)
    }

    func testLocalReadSettlesSameDayAllowanceBeforeLoanInstallment() async throws {
        let repository = try LocalWalletRepository(inMemory: true)
        _ = try await repository.setup(ParentSetup(nickname: "Test Kid"))
        let today = Calendar.current.startOfDay(for: .now)
        _ = try await repository.setAllowance(
            AllowanceRuleCommand(amountCents: 500, weekday: Calendar.current.component(.weekday, from: today) - 1, startDate: today)
        )
        _ = try await repository.submit(WalletCommand(
            kind: .loan,
            amountCents: 400,
            reason: "Bike helmet",
            installmentPlan: LoanInstallmentPlan(cadence: .weekly, amountCents: 400, firstDueDate: today)
        ))
        _ = try await repository.submit(WalletCommand(kind: .withdrawal, amountCents: 400))
        XCTAssertEqual(repository.snapshot().acceptedBalanceCents, 0)

        await repository.applyDueScheduledSettlements()

        XCTAssertEqual(repository.snapshot().acceptedBalanceCents, 100)
        XCTAssertEqual(repository.snapshot().loan?.remainingCents, 0)
        XCTAssertEqual(repository.snapshot().activities.filter { $0.type == .allowance }.count, 1)
        XCTAssertEqual(repository.snapshot().activities.filter { $0.type == .repayment }.count, 1)
    }

    func testLocalReadSkipsLoanInstallmentWhenBalanceIsInsufficient() async throws {
        let repository = try LocalWalletRepository(inMemory: true)
        _ = try await repository.setup(ParentSetup(nickname: "Test Kid"))
        let today = Calendar.current.startOfDay(for: .now)
        _ = try await repository.submit(WalletCommand(
            kind: .loan,
            amountCents: 400,
            reason: "Bike helmet",
            installmentPlan: LoanInstallmentPlan(cadence: .weekly, amountCents: 400, firstDueDate: today)
        ))
        _ = try await repository.submit(WalletCommand(kind: .withdrawal, amountCents: 400))
        XCTAssertEqual(repository.snapshot().acceptedBalanceCents, 0)

        await repository.applyDueScheduledSettlements()

        XCTAssertEqual(repository.snapshot().acceptedBalanceCents, 0)
        XCTAssertEqual(repository.snapshot().loan?.remainingCents, 400)
        XCTAssertEqual(
            Calendar.current.startOfDay(for: try XCTUnwrap(repository.snapshot().loan?.schedule?.nextDueDate)),
            today
        )
        XCTAssertTrue(repository.snapshot().activities.filter { $0.type == .repayment }.isEmpty)

        _ = try await repository.submit(WalletCommand(kind: .deposit, amountCents: 400))
        await repository.applyDueScheduledSettlements()

        XCTAssertEqual(repository.snapshot().acceptedBalanceCents, 0)
        XCTAssertEqual(repository.snapshot().loan?.remainingCents, 0)
        XCTAssertEqual(repository.snapshot().activities.filter { $0.type == .repayment }.count, 1)
    }

    func testCloudReplicaDoesNotAutoSettleDueAllowance() async throws {
        let repository = try LocalWalletRepository(inMemory: true)
        _ = try await repository.setup(ParentSetup(nickname: "Test Kid"))
        let today = Calendar.current.startOfDay(for: .now)
        _ = try await repository.setAllowance(
            AllowanceRuleCommand(amountCents: 500, weekday: Calendar.current.component(.weekday, from: today) - 1, startDate: today)
        )
        try repository.markCloudAuthorityConfirmed(
            lineageID: try XCTUnwrap(repository.lineageID),
            revision: 1
        )
        XCTAssertTrue(repository.isCloudAuthority)

        await repository.applyDueScheduledSettlements()

        XCTAssertEqual(repository.snapshot().acceptedBalanceCents, 0)
        XCTAssertTrue(repository.snapshot().activities.isEmpty)
        XCTAssertEqual(
            Calendar.current.startOfDay(for: try XCTUnwrap(repository.snapshot().allowance?.nextDate)),
            today
        )
    }

    func testLocalAutoSettleCapsTheFinalLoanPayment() async throws {
        let repository = try LocalWalletRepository(inMemory: true)
        _ = try await repository.setup(ParentSetup(nickname: "Test Kid"))
        _ = try await repository.submit(WalletCommand(kind: .deposit, amountCents: 10_000))
        let firstDue = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: -14, to: Calendar.current.startOfDay(for: .now)))
        _ = try await repository.submit(WalletCommand(
            kind: .loan,
            amountCents: 1_000,
            reason: "Bike helmet",
            installmentPlan: LoanInstallmentPlan(cadence: .weekly, amountCents: 400, firstDueDate: firstDue)
        ))
        XCTAssertEqual(repository.snapshot().loan?.dueScheduledInstallments().map(\.amountCents), [400, 400, 200])

        await repository.applyDueScheduledSettlements()

        XCTAssertEqual(repository.snapshot().loan?.remainingCents, 0)
        XCTAssertEqual(repository.snapshot().activities.filter { $0.type == .repayment }.map(\.amountCents).reduce(0, +), 1_000)
        XCTAssertNil(repository.snapshot().loan?.nextCurrentOrFutureInstallment())
    }

    // MARK: - Loan installments

    /// Builds an elevated parent store over a local wallet that already holds a
    /// scheduled loan whose first payment is `weeksOverdue` weeks in the past.
    private func scheduledLoanStore(
        principalCents: Int,
        paymentCents: Int,
        weeksOverdue: Int,
        depositCents: Int = 10_000,
        persistence: LocalWalletPersisting? = nil
    ) async throws -> (store: WalletStore, repository: LocalWalletRepository, firstDueDate: Date) {
        let repository = try persistence.map { try LocalWalletRepository(persistence: $0) }
            ?? LocalWalletRepository(inMemory: true)
        _ = try await repository.setup(ParentSetup(nickname: "Test Kid"))
        _ = try await repository.submit(WalletCommand(kind: .deposit, amountCents: depositCents))
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let firstDueDate = try XCTUnwrap(calendar.date(byAdding: .day, value: -7 * weeksOverdue, to: today))
        _ = try await repository.submit(WalletCommand(
            kind: .loan,
            amountCents: principalCents,
            reason: "Bike helmet",
            installmentPlan: LoanInstallmentPlan(cadence: .weekly, amountCents: paymentCents, firstDueDate: firstDueDate)
        ))
        let store = WalletStore(
            repository: repository,
            initiallySignedIn: true,
            pinStore: InMemoryParentPINStore(pin: "1234"),
            identityStore: InMemoryParentIdentityStore(appleUserID: "owner")
        )
        store.openParentGate()
        for digit in ["1", "2", "3", "4"] { store.appendPINDigit(digit) }
        return (store, repository, firstDueDate)
    }

    func testLocalMissedInstallmentsListPastDuePaymentsAndLeaveTodayForTheSinglePath() async throws {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let (store, _, firstDueDate) = try await scheduledLoanStore(
            principalCents: 2_000,
            paymentCents: 400,
            weeksOverdue: 4
        )

        XCTAssertEqual(store.missedLoanInstallments.count, 4)
        XCTAssertEqual(store.missedLoanInstallments.totalCents, 1_600)
        XCTAssertEqual(store.missedLoanInstallments.installments.map(\.dueDate), [
            firstDueDate,
            try XCTUnwrap(calendar.date(byAdding: .day, value: 7, to: firstDueDate)),
            try XCTUnwrap(calendar.date(byAdding: .day, value: 14, to: firstDueDate)),
            try XCTUnwrap(calendar.date(byAdding: .day, value: 21, to: firstDueDate)),
        ])
        XCTAssertEqual(store.missedLoanInstallments.installments.map(\.amountCents), [400, 400, 400, 400])
        // Today's payment is the ordinary next one, never part of the batch.
        XCTAssertEqual(store.nextLoanInstallment?.dueDate, today)
        XCTAssertEqual(store.nextLoanInstallment?.amountCents, 400)
    }

    func testLocalCatchUpRecordsExactlyTheMissedSetAndCapsTheFinalPayment() async throws {
        let (store, _, _) = try await scheduledLoanStore(
            principalCents: 1_800,
            paymentCents: 400,
            weeksOverdue: 5
        )
        let balanceBefore = store.snapshot.acceptedBalanceCents

        // Five past-due payments exceed the auto-settle cap, so the parent
        // missed-set path still records them. US$4.00 four times leaves
        // US$2.00, so the last missed payment settles the rest of the loan.
        XCTAssertEqual(store.missedLoanInstallments.installments.map(\.amountCents), [400, 400, 400, 400, 200])
        XCTAssertEqual(store.missedLoanInstallments.totalCents, 1_800)

        let settlementStartedAt = Date.now
        let outcome = await store.recordAllMissedLoanInstallments()

        XCTAssertEqual(outcome, .recorded(count: 5, totalCents: 1_800))
        XCTAssertEqual(store.snapshot.loan?.remainingCents, 0)
        XCTAssertEqual(store.snapshot.acceptedBalanceCents, balanceBefore - 1_800)
        let repayments = store.snapshot.activities.filter { $0.type == .repayment }
        XCTAssertEqual(repayments.count, 5)
        XCTAssertEqual(repayments.map(\.amountCents).reduce(0, +), 1_800)
        XCTAssertTrue(repayments.allSatisfy { $0.date >= settlementStartedAt })
        XCTAssertNil(store.nextLoanInstallment)
        XCTAssertTrue(store.missedLoanInstallments.isEmpty)

        let balanceAfter = store.snapshot.acceptedBalanceCents
        let noOp = await store.recordAllMissedLoanInstallments()
        XCTAssertEqual(noOp, .noMissed)
        XCTAssertEqual(store.snapshot.acceptedBalanceCents, balanceAfter)
        XCTAssertEqual(store.snapshot.loan?.remainingCents, 0)
    }

    func testLocalMissedOwedTotalNeverExceedsTheOutstandingBalance() async throws {
        // A long-abandoned plan: twenty weekly payments are past due, but the
        // loan can only ever owe its remaining balance. Five due installments
        // exceed the auto-settle cap, so the parent missed-set path remains.
        let (store, _, _) = try await scheduledLoanStore(
            principalCents: 1_000,
            paymentCents: 200,
            weeksOverdue: 20
        )

        XCTAssertEqual(store.missedLoanInstallments.count, 5)
        XCTAssertEqual(store.missedLoanInstallments.totalCents, 1_000)
        XCTAssertEqual(store.missedLoanInstallments.installments.map(\.amountCents), [200, 200, 200, 200, 200])

        let outcome = await store.recordAllMissedLoanInstallments()

        XCTAssertEqual(outcome, .recorded(count: 5, totalCents: 1_000))
        XCTAssertEqual(store.snapshot.loan?.remainingCents, 0)
    }

    func testInterruptedLocalCatchUpKeepsRecordedPaymentsAndNeverDoubleRecords() async throws {
        let persistence = ControllableLocalWalletPersistence()
        let (store, _, _) = try await scheduledLoanStore(
            principalCents: 4_000,
            paymentCents: 400,
            weeksOverdue: 4,
            persistence: persistence
        )
        let balanceBefore = store.snapshot.acceptedBalanceCents
        persistence.failOnNextSaveNumber = persistence.saveCount + 2

        let interrupted = await store.recordAllMissedLoanInstallments()

        guard case .partial(let recordedCount, let recordedTotalCents, let remaining) = interrupted else {
            return XCTFail("a failed second save must leave a partial settlement")
        }
        XCTAssertEqual(recordedCount, 1)
        XCTAssertEqual(recordedTotalCents, 400)
        XCTAssertEqual(remaining.count, 3)
        XCTAssertEqual(store.snapshot.loan?.remainingCents, 3_600)
        XCTAssertEqual(store.snapshot.acceptedBalanceCents, balanceBefore - 400)
        XCTAssertEqual(store.snapshot.activities.filter { $0.type == .repayment }.count, 1)

        let resumed = await store.recordAllMissedLoanInstallments()

        XCTAssertEqual(resumed, .recorded(count: 3, totalCents: 1_200))
        XCTAssertEqual(store.snapshot.loan?.remainingCents, 2_400)
        XCTAssertEqual(store.snapshot.acceptedBalanceCents, balanceBefore - 1_600)
        XCTAssertEqual(store.snapshot.activities.filter { $0.type == .repayment }.count, 4)
        XCTAssertTrue(store.missedLoanInstallments.isEmpty)
    }

    func testLocalSingleInstallmentPathRecordsOnlyTheCurrentPayment() async throws {
        let repository = try LocalWalletRepository(inMemory: true)
        _ = try await repository.setup(ParentSetup(nickname: "Test Kid"))
        _ = try await repository.submit(WalletCommand(kind: .deposit, amountCents: 10_000))
        let today = Calendar.current.startOfDay(for: .now)
        _ = try await repository.submit(WalletCommand(
            kind: .loan,
            amountCents: 2_000,
            reason: "Bike helmet",
            installmentPlan: LoanInstallmentPlan(cadence: .weekly, amountCents: 400, firstDueDate: today)
        ))
        let balanceBefore = repository.snapshot().acceptedBalanceCents

        let result = try await repository.submit(WalletCommand(kind: .loanInstallment, amountCents: 400))

        guard case .accepted(let event) = result else { return XCTFail("a due installment must be recorded") }
        XCTAssertEqual(event.amountCents, 400)
        XCTAssertEqual(repository.snapshot().loan?.remainingCents, 1_600)
        XCTAssertEqual(repository.snapshot().acceptedBalanceCents, balanceBefore - 400)
        XCTAssertEqual(
            repository.snapshot().loan?.schedule?.nextDueDate,
            Calendar.current.date(byAdding: .day, value: 7, to: today)
        )
    }

    func testLocalInstallmentRejectsAPaymentThatIsNotDueYet() async throws {
        let repository = try LocalWalletRepository(inMemory: true)
        _ = try await repository.setup(ParentSetup(nickname: "Test Kid"))
        let calendar = Calendar.current
        let futureDate = try XCTUnwrap(calendar.date(byAdding: .day, value: 7, to: calendar.startOfDay(for: .now)))
        _ = try await repository.submit(WalletCommand(
            kind: .loan,
            amountCents: 1_000,
            installmentPlan: LoanInstallmentPlan(cadence: .weekly, amountCents: 400, firstDueDate: futureDate)
        ))
        let balanceBefore = repository.snapshot().acceptedBalanceCents

        let result = try await repository.submit(WalletCommand(kind: .loanInstallment, amountCents: 400))

        guard case .rejected(let event) = result else { return XCTFail("a future installment must be rejected") }
        XCTAssertEqual(event.rejectionReason, "There is no scheduled loan payment due.")
        XCTAssertEqual(repository.snapshot().acceptedBalanceCents, balanceBefore)
        XCTAssertEqual(repository.snapshot().loan?.remainingCents, 1_000)
    }

    func testScheduledLoanKeepsTheOneShotRepaymentPathAndRetiresItsReminderWhenCleared() async throws {
        let repository = try LocalWalletRepository(inMemory: true)
        _ = try await repository.setup(ParentSetup(nickname: "Test Kid"))
        _ = try await repository.submit(WalletCommand(kind: .deposit, amountCents: 10_000))
        let firstDueDate = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: -7, to: Calendar.current.startOfDay(for: .now)))
        _ = try await repository.submit(WalletCommand(
            kind: .loan,
            amountCents: 1_000,
            reason: "Bike helmet",
            installmentPlan: LoanInstallmentPlan(cadence: .weekly, amountCents: 400, firstDueDate: firstDueDate)
        ))

        // A free-amount repayment that clears the balance must leave no
        // payment reminder standing.
        _ = try await repository.submit(WalletCommand(kind: .repayment, amountCents: 1_000))

        XCTAssertEqual(repository.snapshot().loan?.remainingCents, 0)
        XCTAssertNil(repository.snapshot().loan?.nextCurrentOrFutureInstallment())
        XCTAssertTrue(repository.snapshot().loan?.missedInstallments().isEmpty ?? false)
    }

    func testScheduleslessLoanShowsNoReminderAndKeepsTheOneShotRepayment() async throws {
        let repository = try LocalWalletRepository(inMemory: true)
        _ = try await repository.setup(ParentSetup(nickname: "Test Kid"))
        _ = try await repository.submit(WalletCommand(kind: .deposit, amountCents: 5_000))
        _ = try await repository.submit(WalletCommand(kind: .loan, amountCents: 1_000, reason: "Bike helmet"))
        let store = WalletStore(
            repository: repository,
            initiallySignedIn: true,
            pinStore: InMemoryParentPINStore(pin: "1234"),
            identityStore: InMemoryParentIdentityStore(appleUserID: "owner")
        )
        store.openParentGate()
        for digit in ["1", "2", "3", "4"] { store.appendPINDigit(digit) }

        XCTAssertNil(store.snapshot.loan?.schedule)
        XCTAssertNil(store.nextLoanInstallment)
        XCTAssertTrue(store.missedLoanInstallments.isEmpty)
        let outcome = await store.recordAllMissedLoanInstallments()
        XCTAssertEqual(outcome, .noMissed)

        // The ordinary repayment path is untouched.
        let repayment = try await repository.submit(WalletCommand(kind: .repayment, amountCents: 250))
        guard case .accepted = repayment else { return XCTFail("a scheduleless loan keeps its one-shot repayment") }
        XCTAssertEqual(repository.snapshot().loan?.remainingCents, 750)

        let installment = try await repository.submit(WalletCommand(kind: .loanInstallment, amountCents: 250))
        guard case .rejected(let event) = installment else {
            return XCTFail("a scheduleless loan has no installment to record")
        }
        XCTAssertEqual(event.rejectionReason, "There is no scheduled loan payment due.")
    }

    func testMonthlyInstallmentsStayOnTheirAnchorDayAcrossShortMonths() async throws {
        let repository = try LocalWalletRepository(inMemory: true)
        _ = try await repository.setup(ParentSetup(nickname: "Test Kid"))
        _ = try await repository.submit(WalletCommand(kind: .deposit, amountCents: 10_000))
        var components = DateComponents()
        components.year = 2026
        components.month = 1
        components.day = 31
        let calendar = Calendar.current
        let anchor = try XCTUnwrap(calendar.date(from: components))
        _ = try await repository.submit(WalletCommand(
            kind: .loan,
            amountCents: 3_000,
            installmentPlan: LoanInstallmentPlan(cadence: .monthly, amountCents: 500, firstDueDate: anchor)
        ))
        let loan = try XCTUnwrap(repository.snapshot().loan)

        // Measured from the anchor, never from the previously produced date, so
        // February's clamped 28th does not drag March down with it.
        let missed = loan.missedInstallments(
            asOf: try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 4, day: 15))),
            calendar: calendar
        )
        XCTAssertEqual(missed.count, 3)
        XCTAssertEqual(missed.installments.map { calendar.component(.day, from: $0.dueDate) }, [31, 28, 31])
    }

    func testLocalAllowanceRequiresAWeeklyRule() async throws {
        let repository = try LocalWalletRepository(inMemory: true)
        _ = try await repository.setup(ParentSetup(nickname: "Test Kid"))

        let result = try await repository.submit(WalletCommand(kind: .allowance, amountCents: 500))

        guard case .rejected(let event) = result else {
            return XCTFail("an unscheduled allowance must be rejected")
        }
        XCTAssertEqual(event.rejectionReason, "There is no scheduled allowance occurrence to record.")
        XCTAssertEqual(repository.snapshot().acceptedBalanceCents, 0)
        XCTAssertTrue(repository.snapshot().activities.isEmpty)
    }

    func testLocalAllowanceRejectsAFutureScheduledOccurrence() async throws {
        let repository = try LocalWalletRepository(inMemory: true)
        _ = try await repository.setup(ParentSetup(nickname: "Test Kid"))
        let calendar = Calendar.current
        let futureDate = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: .now)))
        _ = try await repository.setAllowance(
            AllowanceRuleCommand(amountCents: 500, weekday: calendar.component(.weekday, from: futureDate) - 1, startDate: futureDate)
        )

        let result = try await repository.submit(WalletCommand(kind: .allowance, amountCents: 500))

        guard case .rejected(let event) = result else {
            return XCTFail("a future allowance occurrence must be rejected")
        }
        XCTAssertEqual(event.rejectionReason, "There is no scheduled allowance occurrence to record.")
        XCTAssertEqual(repository.snapshot().acceptedBalanceCents, 0)
        XCTAssertTrue(repository.snapshot().activities.isEmpty)
        XCTAssertEqual(repository.snapshot().allowance?.nextDate, futureDate)
    }

    func testChangedScheduleRequiresReviewWithoutClaimingConfirmedWeeksRemain() async throws {
        let repository = try LocalWalletRepository(inMemory: true)
        _ = try await repository.setup(ParentSetup(nickname: "Test Kid"))
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let firstMissed = try XCTUnwrap(calendar.date(byAdding: .day, value: -14, to: today))
        _ = try await repository.setAllowance(
            AllowanceRuleCommand(amountCents: 500, weekday: 1, startDate: firstMissed)
        )
        let store = WalletStore(
            repository: repository,
            initiallySignedIn: true,
            pinStore: InMemoryParentPINStore(pin: "1234"),
            identityStore: InMemoryParentIdentityStore(appleUserID: "owner")
        )
        store.openParentGate()
        for digit in ["1", "2", "3", "4"] { store.appendPINDigit(digit) }
        let confirmed = store.missedAllowancePayouts
        let replacementStart = try XCTUnwrap(calendar.date(byAdding: .day, value: -7, to: today))
        let scheduleChanged = await store.setAllowance(
            AllowanceRuleCommand(amountCents: 600, weekday: 1, startDate: replacementStart)
        )
        XCTAssertTrue(scheduleChanged)

        let outcome = await store.recordAllMissedAllowance(confirmed)

        XCTAssertEqual(outcome, .reviewRequired(recordedCount: 0, recordedTotalCents: 0))
        XCTAssertEqual(store.snapshot.acceptedBalanceCents, 0)
        XCTAssertTrue(store.snapshot.activities.isEmpty)
    }

    func testLocalRejectedDebitNeverChangesAcceptedBalance() async throws {
        let repository = try LocalWalletRepository(inMemory: true)
        _ = try await repository.setup(ParentSetup(nickname: "Test Kid"))
        let result = try await repository.submit(WalletCommand(kind: .withdrawal, amountCents: 1))
        guard case .rejected = result else { return XCTFail("Overdraft should be rejected") }
        XCTAssertEqual(repository.snapshot().acceptedBalanceCents, 0)
    }

    func testFailedSaveDoesNotPublishCandidateState() async throws {
        let persistence = ControllableLocalWalletPersistence()
        let repository = try LocalWalletRepository(persistence: persistence)
        _ = try await repository.setup(ParentSetup(nickname: "Test Kid"))
        persistence.saveError = TestPersistenceError.failed

        await XCTAssertThrowsErrorAsync {
            _ = try await repository.submit(WalletCommand(kind: .deposit, amountCents: 500))
        }

        XCTAssertEqual(repository.snapshot().acceptedBalanceCents, 0)
        XCTAssertTrue(repository.snapshot().activities.isEmpty)
    }

    func testCorruptPersistedWalletIsConfiguredAndCannotBeReplaced() async throws {
        let persistence = ControllableLocalWalletPersistence(payload: Data("not-json".utf8))
        let repository = try LocalWalletRepository(persistence: persistence)

        XCTAssertTrue(repository.hasConfiguredKid)
        XCTAssertTrue(repository.isReadOnly)
        await XCTAssertThrowsErrorAsync {
            _ = try await repository.setup(ParentSetup(nickname: "Replacement"))
        }
        XCTAssertEqual(persistence.saveCount, 0)
    }

    func testCorruptPersistedWalletRoutesToRecoveryInsteadOfZeroBalance() throws {
        let persistence = ControllableLocalWalletPersistence(payload: Data("not-json".utf8))
        let repository = try LocalWalletRepository(persistence: persistence)
        let store = WalletStore(
            repository: repository,
            pinStore: InMemoryParentPINStore(pin: "1234"),
            identityStore: InMemoryParentIdentityStore(appleUserID: "owner")
        )

        XCTAssertEqual(store.rootRoute, .recovery)
        XCTAssertEqual(store.recoveryState, .historyUnavailable)
        XCTAssertEqual(store.authorityState, .localRecovery(.historyUnavailable))
    }

    func testFailedEraseKeepsWalletInMemory() async throws {
        let persistence = ControllableLocalWalletPersistence()
        let repository = try LocalWalletRepository(persistence: persistence)
        _ = try await repository.setup(ParentSetup(nickname: "Test Kid"))
        persistence.eraseError = TestPersistenceError.failed

        XCTAssertThrowsError(try repository.clearSession())
        XCTAssertTrue(repository.hasConfiguredKid)
        XCTAssertEqual(repository.snapshot().configuredChildNickname, "Test Kid")
    }

    func testLegacyInputsSelectCompatibilityRepository() throws {
        let legacySnapshot = WalletSnapshot.fixture()
        let local = try LocalWalletRepository(inMemory: true, legacySnapshot: legacySnapshot, hasLegacyMarker: true)
        let compatibility = MockWalletRepository(snapshot: legacySnapshot)

        let selected = WalletRepositoryFactory.select(local: local, legacy: compatibility)

        XCTAssertTrue(selected === compatibility)
        XCTAssertTrue(local.hasLegacyInputs)
    }

    func testLocalAggregateTakesPrecedenceOverLegacyCompatibility() async throws {
        let persistence = ControllableLocalWalletPersistence()
        let original = try LocalWalletRepository(persistence: persistence)
        _ = try await original.setup(ParentSetup(nickname: "Test Kid"))
        let local = try LocalWalletRepository(persistence: persistence, legacySnapshot: WalletSnapshot.fixture(), hasLegacyMarker: true)
        let compatibility = MockWalletRepository()

        let selected = WalletRepositoryFactory.select(local: local, legacy: compatibility)

        XCTAssertTrue(selected === local)
        XCTAssertFalse(local.hasLegacyInputs)
    }

    func testLocalPersistenceOpenFailureRoutesToRecovery() {
        let selected = WalletRepositoryFactory.makeDefault(
            localProvider: { throw TestPersistenceError.failed },
            legacyProvider: { MockWalletRepository() }
        )
        let store = WalletStore(
            repository: selected,
            pinStore: InMemoryParentPINStore(pin: "1234"),
            identityStore: InMemoryParentIdentityStore(appleUserID: "owner")
        )

        XCTAssertTrue(selected is LocalWalletRecoveryRepository)
        XCTAssertEqual(store.rootRoute, .recovery)
        XCTAssertEqual(store.recoveryState, .storageUnavailable)
    }
}

private enum TestPersistenceError: Error {
    case failed
}

private final class ControllableLocalWalletPersistence: LocalWalletPersisting {
    var payload: Data?
    var saveError: Error?
    var eraseError: Error?
    var failOnNextSaveNumber: Int?
    private(set) var saveCount = 0

    init(payload: Data? = nil) {
        self.payload = payload
    }

    func load() throws -> Data? {
        payload
    }

    func save(_ payload: Data) throws {
        if let saveError { throw saveError }
        let nextSaveNumber = saveCount + 1
        if failOnNextSaveNumber == nextSaveNumber {
            failOnNextSaveNumber = nil
            throw TestPersistenceError.failed
        }
        saveCount = nextSaveNumber
        self.payload = payload
    }

    func erase() throws {
        if let eraseError { throw eraseError }
        payload = nil
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected an error", file: file, line: line)
    } catch {}
}
