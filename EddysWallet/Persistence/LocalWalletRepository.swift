import Foundation

struct LocalWalletMetadata: Codable, Sendable {
    var schemaVersion = 1
    var lineageID: UUID
    var authority = "local"
    var confirmedCloudLineageID: UUID? = nil
    var serverHouseholdID: String?
    var serverRevision: Int64 = 0
    var lastServerSync: Date?
    var migrationState = "complete"
    /// Stable identity of the one-time local-to-Cloud upload, so an interrupted
    /// import replays instead of creating a second household.
    var cloudImportOperationID: UUID?
    var cloudImportCompleted = false
    /// At most one exact Cloud request can be unresolved. It is stored beside
    /// replica provenance so relaunch cannot mint a second idempotency key.
    var unsettledCloudMutation: PendingCloudMutation? = nil
}

private struct LocalWalletAggregate: Codable, Sendable {
    var metadata: LocalWalletMetadata
    var snapshot: WalletSnapshot
}

/// Free authority. It deliberately does not hold a session or call the
/// backend. Every parent mutation validates and persists accepted state in a
/// single Core Data save, then returns Recorded.
@MainActor
public final class LocalWalletRepository: WalletRepository, WalletRecoveryProviding, AccountDeletionLocalRetiring {
    private let persistence: any LocalWalletPersisting
    private var aggregate: LocalWalletAggregate?
    private var readOnlyReason: String?
    private var cloudHandoffGeneration = 0
    public private(set) var recoveryState: WalletRecoveryState?
    /// A pre-Core-Data marker/cache is a migration input only. It stays
    /// read-only and is never promoted to local authority because it may hold
    /// only ten recent events.
    private var legacySnapshot: WalletSnapshot?
    private var legacyMarkerPresent = false

    public init(directory: URL? = nil, inMemory: Bool = false, legacySnapshot: WalletSnapshot? = nil, hasLegacyMarker: Bool = false) throws {
        let persistence = try LocalWalletPersistence(directory: directory, inMemory: inMemory)
        self.persistence = persistence
        try load(legacySnapshot: legacySnapshot, hasLegacyMarker: hasLegacyMarker)
    }

    init(persistence: any LocalWalletPersisting, legacySnapshot: WalletSnapshot? = nil, hasLegacyMarker: Bool = false) throws {
        self.persistence = persistence
        try load(legacySnapshot: legacySnapshot, hasLegacyMarker: hasLegacyMarker)
    }

    private func load(legacySnapshot: WalletSnapshot?, hasLegacyMarker: Bool) throws {
        if let data = try persistence.load() {
            do {
                let decoded = try JSONDecoder().decode(LocalWalletAggregate.self, from: data)
                try Self.validate(decoded.snapshot)
                aggregate = decoded
            } catch {
                // Never replace questionable history with an empty wallet.
                readOnlyReason = "This wallet history needs recovery before it can be changed."
                recoveryState = .historyUnavailable
            }
        } else if hasLegacyMarker || legacySnapshot != nil {
            self.legacySnapshot = legacySnapshot
            legacyMarkerPresent = hasLegacyMarker
        }
    }

    public convenience init() throws {
        let cache = UserDefaultsWalletSnapshotCache().load()
        try self.init(legacySnapshot: cache, hasLegacyMarker: UserDefaultsConfiguredKidStore().isConfigured)
    }

    public var isAuthenticated: Bool { aggregate != nil || legacySnapshot != nil || legacyMarkerPresent || readOnlyReason != nil }
    public var hasConfiguredKid: Bool { aggregate != nil || legacySnapshot != nil || legacyMarkerPresent || readOnlyReason != nil }
    public var hasLegacyInputs: Bool { aggregate == nil && (legacySnapshot != nil || legacyMarkerPresent) }
    public var lineageID: UUID? { aggregate?.metadata.lineageID }
    public var isReadOnly: Bool { readOnlyReason != nil }

    public func snapshot() -> WalletSnapshot { aggregate?.snapshot ?? legacySnapshot ?? .empty() }
    public func childSnapshot() -> WalletSnapshot { snapshot() }
    public func refresh(for _: UserRole) async throws -> WalletSnapshot { snapshot() }
    public func activity(limit: Int) async throws -> [WalletEvent] { Array(snapshot().activities.prefix(max(1, min(limit, 100)))) }

    public func activityDetail(remoteID: String) async throws -> WalletEvent {
        guard let event = snapshot().activities.first(where: { $0.remoteID == remoteID || $0.id.uuidString == remoteID }) else {
            throw WalletAPIError.server(statusCode: 404, code: "ACTIVITY_NOT_FOUND", message: "The activity entry was not found.")
        }
        return event
    }

    public func loanDetail(remoteID: String) async throws -> LoanDetail {
        guard let loan = snapshot().loan, loan.remoteID == remoteID || remoteID == "local-loan" else {
            throw WalletAPIError.server(statusCode: 404, code: "LOAN_NOT_FOUND", message: "The loan was not found.")
        }
        return LoanDetail(loan: loan, entries: snapshot().activities.filter { $0.type == .loan || $0.type == .repayment })
    }

    public func setup(_ setup: ParentSetup) async throws -> WalletSnapshot {
        if let readOnlyReason { throw WalletAPIError.invalidResponse(readOnlyReason) }
        guard aggregate == nil else { return snapshot() }
        guard legacySnapshot == nil else {
            throw WalletAPIError.invalidResponse("A parent needs one connection to move this existing wallet. Starting a new wallet requires the explicit destructive migration choice.")
        }
        guard let nickname = ChildProfileCopy.configuredNickname(from: setup.nickname) else {
            throw WalletAPIError.invalidResponse("Enter a child nickname.")
        }
        let fresh = WalletSnapshot(acceptedBalanceCents: 0, activities: [], loan: nil, allowance: nil, pendingEvents: [], lastUpdated: .now, isStale: false, childNickname: nickname)
        try persist(LocalWalletAggregate(metadata: LocalWalletMetadata(lineageID: UUID()), snapshot: fresh))
        return fresh
    }

    public func updateChildProfile(_ update: ChildProfileUpdate) async throws -> WalletSnapshot {
        guard let nickname = update.validatedNickname else { throw WalletAPIError.invalidResponse("Enter a child nickname.") }
        var candidate = try writableAggregate()
        candidate.snapshot.childNickname = nickname
        candidate.snapshot.lastUpdated = .now
        candidate.snapshot.isStale = false
        try persist(candidate)
        return candidate.snapshot
    }

    public func setAllowance(_ command: AllowanceRuleCommand) async throws -> WalletSnapshot {
        guard command.amountCents > 0, (0...6).contains(command.weekday) else {
            throw WalletAPIError.invalidResponse("Enter a valid weekly allowance.")
        }
        var candidate = try writableAggregate()
        candidate.snapshot.allowance = AllowancePlan(remoteID: "local-allowance", amountCents: command.amountCents, cadence: "every week", weekday: command.weekday, nextDate: command.startDate, endDate: command.endDate, nextOccurrenceID: command.idempotencyKey, syncState: .recorded)
        candidate.snapshot.lastUpdated = .now
        candidate.snapshot.isStale = false
        try persist(candidate)
        return candidate.snapshot
    }

    public func submit(_ command: WalletCommand) async throws -> CommandResult {
        var candidate = try writableAggregate()
        // An installment names no amount: the plan and the remaining balance
        // decide it, so it is the one command that legitimately arrives at
        // zero. Every other command still needs a positive amount.
        guard command.amountCents > 0 || command.kind == .loanInstallment else {
            return .rejected(rejected(command, "Enter an amount greater than US$0.00."))
        }
        var wallet = candidate.snapshot
        var settledAmountCents = command.amountCents
        var settledDate = Date.now
        // The service names an unlabelled installment "Loan payment", so every
        // authority puts the same words on the same accepted entry.
        let settledReason = command.kind == .loanInstallment
            ? (command.reason ?? LoanSchedule.defaultInstallmentReason)
            : command.reason
        // One identity for the accepted entry, minted before the switch so a
        // recorded installment and the ledger entry that pays it name the same
        // event even when the idempotency key is not itself a UUID.
        let eventID = UUID(uuidString: command.idempotencyKey) ?? UUID()
        switch command.kind {
        case .withdrawal:
            guard command.amountCents <= wallet.acceptedBalanceCents else { return .rejected(rejected(command, "The amount is greater than the accepted balance.")) }
            wallet.acceptedBalanceCents -= command.amountCents
        case .repayment:
            guard let loan = wallet.loan, command.amountCents <= loan.remainingCents else { return .rejected(rejected(command, "The repayment is greater than the amount left to repay.")) }
            guard command.amountCents <= wallet.acceptedBalanceCents else { return .rejected(rejected(command, "The repayment is greater than the accepted balance.")) }
            wallet.acceptedBalanceCents -= command.amountCents
            wallet.loan?.remainingCents -= command.amountCents
            // A free-amount repayment that clears the balance must leave no
            // payment reminder standing, exactly as the service cancels the
            // pending occurrence in the same transaction.
            wallet.loan?.retireScheduleIfSettled()
        case .loanInstallment:
            // One scheduled payment at a time, advanced only in the same atomic
            // save as its ledger entry, so an interrupted catch-up resumes at
            // the first unrecorded payment and can never record one twice.
            guard let loan = wallet.loan, let schedule = loan.schedule, let dueDate = schedule.nextDueDate else {
                return .rejected(rejected(command, "There is no scheduled loan payment due."))
            }
            let calendar = Calendar.current
            guard calendar.startOfDay(for: dueDate) <= calendar.startOfDay(for: .now) else {
                return .rejected(rejected(command, "There is no scheduled loan payment due."))
            }
            if let expectedDueDate = command.dueDate {
                guard calendar.startOfDay(for: expectedDueDate) == calendar.startOfDay(for: dueDate),
                      calendar.startOfDay(for: expectedDueDate) < calendar.startOfDay(for: .now) else {
                    return .rejected(rejected(command, "The loan payment schedule changed. Review the remaining payments before paying them."))
                }
            }
            // The final payment is the rest of the loan, never the full named
            // amount, so the outstanding balance never falls below zero.
            let payment = Loan.installmentPaymentCents(named: schedule.amountCents, remainingCents: loan.remainingCents)
            guard payment > 0 else { return .rejected(rejected(command, "There is no scheduled loan payment due.")) }
            guard payment <= wallet.acceptedBalanceCents else {
                return .rejected(rejected(command, "The loan payment is greater than the accepted balance."))
            }
            guard let settled = loan.recordingInstallment(
                paymentCents: payment,
                nextOccurrenceID: UUID().uuidString,
                entryID: eventID,
                calendar: calendar
            ) else {
                return .rejected(rejected(command, "The next loan payment could not be scheduled."))
            }
            wallet.acceptedBalanceCents -= payment
            wallet.loan = settled
            settledAmountCents = payment
        case .loan:
            guard wallet.loan == nil || wallet.loan?.isPaid == true else { return .rejected(rejected(command, "Finish the open loan before creating another one.")) }
            if let plan = command.installmentPlan, plan.amountCents <= 0 {
                return .rejected(rejected(command, "Enter a payment amount greater than US$0.00."))
            }
            wallet.acceptedBalanceCents += command.amountCents
            wallet.loan = Loan(
                remoteID: "local-loan",
                originalCents: command.amountCents,
                remainingCents: command.amountCents,
                purpose: command.reason,
                dueDate: command.dueDate,
                schedule: command.installmentPlan.map { LoanSchedule.opening($0) }
            )
        case .deposit:
            wallet.acceptedBalanceCents += command.amountCents
        case .allowance:
            // A local allowance is still one scheduled occurrence at a time.
            // Advance only in the same atomic save as its ledger entry, so an
            // interrupted record-all can resume at the first unrecorded week.
            guard let plan = wallet.allowance else {
                return .rejected(rejected(command, "There is no scheduled allowance occurrence to record."))
            }
            let calendar = Calendar.current
            guard calendar.startOfDay(for: plan.nextDate) <= calendar.startOfDay(for: .now) else {
                return .rejected(rejected(command, "There is no scheduled allowance occurrence to record."))
            }
            guard command.amountCents == plan.amountCents else {
                return .rejected(rejected(command, "The allowance amount no longer matches the weekly plan."))
            }
            guard plan.endDate.map({ plan.nextDate <= $0 }) ?? true else {
                return .rejected(rejected(command, "There is no scheduled allowance occurrence to record."))
            }
            guard let followingDate = calendar.date(byAdding: .day, value: 7, to: plan.nextDate) else {
                return .rejected(rejected(command, "The next allowance occurrence could not be scheduled."))
            }
            wallet.allowance = AllowancePlan(
                remoteID: plan.remoteID,
                amountCents: plan.amountCents,
                cadence: plan.cadence,
                weekday: plan.weekday,
                nextDate: followingDate,
                endDate: plan.endDate,
                nextOccurrenceID: UUID().uuidString,
                syncState: plan.syncState
            )
            wallet.acceptedBalanceCents += command.amountCents
        }
        let event = WalletEvent(
            id: eventID,
            remoteID: command.idempotencyKey,
            type: activityType(command.kind),
            amountCents: settledAmountCents,
            balanceBeforeCents: candidate.snapshot.acceptedBalanceCents,
            balanceAfterCents: wallet.acceptedBalanceCents,
            reason: settledReason,
            date: settledDate,
            syncState: .recorded,
            explanation: explanation(command, amountCents: settledAmountCents)
        )
        wallet.activities.insert(event, at: 0)
        wallet.lastUpdated = .now
        wallet.isStale = false
        candidate.snapshot = wallet
        try persist(candidate)
        return .accepted(event)
    }

    // MARK: - Cloud authority

    /// The accepted Cloud household this device is mirroring, when Cloud owns
    /// the lineage. A missing or non-Cloud authority never reports a revision.
    public var cloudRevision: Int64? {
        guard let aggregate, aggregate.metadata.authority == "cloud" else { return nil }
        return aggregate.metadata.serverRevision
    }

    public var cloudAuthorityLineageID: UUID? {
        guard let aggregate, aggregate.metadata.authority == "cloud" else { return nil }
        return aggregate.metadata.confirmedCloudLineageID ?? aggregate.metadata.lineageID
    }

    public var isCloudAuthority: Bool { cloudRevision != nil }
    var unsettledCloudMutation: PendingCloudMutation? { aggregate?.metadata.unsettledCloudMutation }
    var cloudApplicationLease: Int { cloudHandoffGeneration }
    public var cloudImportOperationID: UUID? { aggregate?.metadata.cloudImportOperationID }
    public var hasCompletedCloudImport: Bool { aggregate?.metadata.cloudImportCompleted == true }
    /// Reserves the one-time import identity before the upload starts, so a
    /// retry after an interrupted upload reuses the same operation and key.
    @discardableResult
    public func reserveCloudImportOperation() throws -> UUID {
        var candidate = try writableAggregate()
        if let existing = candidate.metadata.cloudImportOperationID { return existing }
        let operationID = UUID()
        candidate.metadata.cloudImportOperationID = operationID
        try persist(candidate)
        return operationID
    }

    public func markCloudAuthorityConfirmed(lineageID: UUID, revision: Int64) throws {
        var candidate = aggregate ?? LocalWalletAggregate(
            metadata: LocalWalletMetadata(lineageID: lineageID),
            snapshot: .empty()
        )
        if let readOnlyReason { throw WalletAPIError.invalidResponse(readOnlyReason) }
        if candidate.metadata.authority != "cloud" {
            candidate.metadata.lastServerSync = nil
        }
        candidate.metadata.authority = "cloud"
        candidate.metadata.confirmedCloudLineageID = lineageID
        candidate.metadata.serverRevision = revision
        candidate.metadata.unsettledCloudMutation = nil
        try persist(candidate)
    }

    public func markCloudImportAccepted(lineageID: UUID, revision: Int64) throws {
        guard var candidate = aggregate, candidate.metadata.lineageID == lineageID else {
            throw WalletAPIError.invalidResponse("Cloud confirmed a different wallet history. Nothing was changed.")
        }
        if let readOnlyReason { throw WalletAPIError.invalidResponse(readOnlyReason) }
        candidate.metadata.authority = "cloud"
        candidate.metadata.confirmedCloudLineageID = lineageID
        candidate.metadata.serverRevision = revision
        candidate.metadata.lastServerSync = .now
        candidate.metadata.cloudImportCompleted = true
        candidate.metadata.unsettledCloudMutation = nil
        try persist(candidate)
    }

    public func hasAcceptedCloudReplica(lineageID: UUID) -> Bool {
        guard let aggregate,
              aggregate.metadata.authority == "cloud",
              cloudAuthorityLineageID == lineageID,
              aggregate.metadata.lineageID == lineageID,
              aggregate.metadata.lastServerSync != nil else { return false }
        return true
    }

    func stageCloudMutation(_ mutation: PendingCloudMutation) throws {
        var candidate = try writableAggregate()
        guard candidate.metadata.authority == "cloud" else {
            throw WalletAPIError.invalidResponse("Cloud does not own this wallet.")
        }
        guard candidate.metadata.unsettledCloudMutation == nil else {
            throw WalletAPIError.cloudMutationAwaitingReconciliation
        }
        candidate.metadata.unsettledCloudMutation = mutation
        try persist(candidate)
    }

    func markCloudMutationAccepted(_ mutation: PendingCloudMutation) throws {
        var candidate = try writableAggregate()
        guard candidate.metadata.unsettledCloudMutation?.operationID == mutation.operationID else {
            throw WalletAPIError.invalidResponse("The pending Cloud change could not be matched.")
        }
        candidate.metadata.unsettledCloudMutation = mutation
        try persist(candidate)
    }

    func clearCloudMutation(operationID: UUID) throws {
        var candidate = try writableAggregate()
        guard candidate.metadata.unsettledCloudMutation?.operationID == operationID else { return }
        candidate.metadata.unsettledCloudMutation = nil
        try persist(candidate)
    }

    /// Cloud ended (expiry, refund, revocation, or an explicit parent choice):
    /// the mirrored history stays and this device becomes the accepted authority
    /// again. Nothing is deleted.
    ///
    /// `allowance` is the service-owned chain head from the in-memory overlay
    /// (`GET /v1/allowance-rule`). The persisted replica's rule start date is
    /// not that fact; writing the overlay here, behind the unresolved-write
    /// gate and in the same save as the authority change, is what stops
    /// already-paid weeks from reappearing as missed.
    public func continueLocallyAfterCloud(allowance: AllowancePlan? = nil) throws {
        var candidate = try writableAggregate()
        guard candidate.metadata.unsettledCloudMutation == nil else {
            throw WalletAPIError.cloudMutationAwaitingReconciliation
        }
        if let persistedAllowance = candidate.snapshot.allowance {
            guard let allowance,
                  allowance.remoteID == persistedAllowance.remoteID,
                  allowance.amountCents == persistedAllowance.amountCents,
                  allowance.nextOccurrenceID?.isEmpty == false else {
                throw WalletAPIError.invalidResponse("Cloud did not provide a complete current allowance schedule.")
            }
            candidate.snapshot.allowance = allowance
        }
        candidate.metadata.authority = "local"
        candidate.metadata.confirmedCloudLineageID = nil
        candidate.metadata.serverRevision = 0
        candidate.metadata.lastServerSync = nil
        try persist(candidate)
        cloudHandoffGeneration += 1
    }

    /// Applies an accepted Cloud replica in one transactional save. A malformed
    /// or non-Cloud household is refused instead of replacing local history.
    @discardableResult
    func applyCloudReplica(
        _ replica: CloudReplica,
        merging: Bool,
        resolving mutation: PendingCloudMutation? = nil,
        applicationLease: Int
    ) throws -> Bool {
        let lineageID = try validateCloudReplicaAuthority(
            replica,
            applicationLease: applicationLease
        )
        var metadata = aggregate?.metadata ?? LocalWalletMetadata(lineageID: lineageID)
        if metadata.authority == "cloud",
           metadata.confirmedCloudLineageID == lineageID,
           replica.household.revision < metadata.serverRevision {
            throw WalletAPIError.invalidResponse("An older Cloud wallet response was ignored.")
        }
        let existingReplicaMatches = hasAcceptedCloudReplica(lineageID: lineageID)
        let fallbackNickname = metadata.lineageID == lineageID ? aggregate?.snapshot.childNickname : nil
        metadata.lineageID = lineageID
        metadata.authority = "cloud"
        metadata.confirmedCloudLineageID = lineageID
        metadata.serverRevision = replica.household.revision
        metadata.lastServerSync = .now
        metadata.cloudImportCompleted = true
        let existingEvents = merging && existingReplicaMatches ? (aggregate?.snapshot.activities ?? []) : []
        let snapshot = CloudReplicaMapper.snapshot(from: replica, mergingInto: existingEvents, fallbackNickname: fallbackNickname)
        let candidateMutation = mutation ?? metadata.unsettledCloudMutation
        let observed = candidateMutation?.isObserved(in: replica, mappedSnapshot: snapshot) == true
        if observed {
            metadata.unsettledCloudMutation = nil
        }
        try persist(LocalWalletAggregate(metadata: metadata, snapshot: snapshot))
        return observed
    }

    func validateCloudReplicaAuthority(
        _ replica: CloudReplica,
        applicationLease: Int
    ) throws -> UUID {
        guard applicationLease == cloudHandoffGeneration else {
            throw WalletAPIError.cancelled
        }
        guard replica.household.isCloudAuthoritative, let lineageID = replica.household.lineageID else {
            throw WalletAPIError.invalidResponse("The Cloud wallet did not report a usable household.")
        }
        if let readOnlyReason { throw WalletAPIError.invalidResponse(readOnlyReason) }
        if let confirmedLineageID = cloudAuthorityLineageID, confirmedLineageID != lineageID {
            throw WalletAPIError.invalidResponse("This Cloud wallet belongs to a different wallet history.")
        }
        return lineageID
    }

    /// The complete local household as an upload manifest. Loans are rebuilt
    /// from the accepted event chain so historical loans are never dropped.
    public func cloudImportManifest(familyName: String, operationID: UUID) throws -> CloudImportManifest {
        let aggregate = try writableAggregate()
        guard let nickname = ChildProfileCopy.configuredNickname(from: aggregate.snapshot.childNickname) else {
            throw WalletAPIError.invalidResponse("Add your child's nickname before turning on Cloud.")
        }
        return try CloudImportManifestBuilder.manifest(
            lineageID: aggregate.metadata.lineageID,
            operationID: operationID,
            familyName: familyName,
            nickname: nickname,
            snapshot: aggregate.snapshot
        )
    }

    public func clearAuthentication() {}
    public func clearSession() throws {
        try persistence.erase()
        cloudHandoffGeneration += 1
        aggregate = nil
        legacySnapshot = nil
        legacyMarkerPresent = false
        readOnlyReason = nil
        recoveryState = nil
    }

    public func retireLocalWalletForAccountDeletion() throws { try clearSession() }

    private func persist(_ candidate: LocalWalletAggregate) throws {
        try Self.validate(candidate.snapshot)
        try persistence.save(JSONEncoder().encode(candidate))
        aggregate = candidate
    }

    private func writableAggregate() throws -> LocalWalletAggregate {
        if let readOnlyReason { throw WalletAPIError.invalidResponse(readOnlyReason) }
        guard let aggregate else { throw WalletAPIError.familyNotSetup }
        return aggregate
    }

    private static func validate(_ snapshot: WalletSnapshot) throws {
        guard snapshot.acceptedBalanceCents >= 0 else { throw WalletAPIError.invalidResponse("The wallet history has an invalid balance.") }
        var running = 0
        for event in snapshot.activities.reversed() where event.syncState == .recorded {
            guard event.amountCents > 0 else { throw WalletAPIError.invalidResponse("The wallet history has an invalid event.") }
            let next = event.isPositive ? running + event.amountCents : running - event.amountCents
            guard next >= 0 else { throw WalletAPIError.invalidResponse("The wallet history does not balance.") }
            if let before = event.balanceBeforeCents, before != running { throw WalletAPIError.invalidResponse("The wallet history does not balance.") }
            if let after = event.balanceAfterCents, after != next { throw WalletAPIError.invalidResponse("The wallet history does not balance.") }
            running = next
        }
        // A legacy fixture may not hold a full event chain. Newly persisted local
        // events always do, so only check a nonempty complete chain with balances.
        if snapshot.activities.allSatisfy({ $0.balanceAfterCents != nil }) && running != snapshot.acceptedBalanceCents {
            throw WalletAPIError.invalidResponse("The wallet history does not match its balance.")
        }
    }

    private func activityType(_ kind: WalletCommandKind) -> ActivityType {
        switch kind { case .allowance: .allowance; case .deposit: .deposit; case .withdrawal: .withdrawal; case .loan: .loan; case .repayment, .loanInstallment: .repayment }
    }

    private func rejected(_ command: WalletCommand, _ reason: String) -> WalletEvent {
        WalletEvent(type: activityType(command.kind), amountCents: command.amountCents, reason: command.reason, syncState: .rejected, explanation: "This action was not recorded and did not change the accepted balance.", rejectionReason: reason)
    }

    /// A recorded installment carries the amount the plan actually settled,
    /// which is not the amount the command named.
    private func explanation(_ command: WalletCommand, amountCents: Int) -> String {
        AcceptedEventCopy.explanation(for: activityType(command.kind), amountCents: amountCents)
    }
}
