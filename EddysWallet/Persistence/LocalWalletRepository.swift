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
public final class LocalWalletRepository: WalletRepository, WalletRecoveryProviding {
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
        guard command.amountCents > 0 else { return .rejected(rejected(command, "Enter an amount greater than US$0.00.")) }
        var wallet = candidate.snapshot
        switch command.kind {
        case .withdrawal:
            guard command.amountCents <= wallet.acceptedBalanceCents else { return .rejected(rejected(command, "The amount is greater than the accepted balance.")) }
            wallet.acceptedBalanceCents -= command.amountCents
        case .repayment:
            guard let loan = wallet.loan, command.amountCents <= loan.remainingCents else { return .rejected(rejected(command, "The repayment is greater than the amount left to repay.")) }
            guard command.amountCents <= wallet.acceptedBalanceCents else { return .rejected(rejected(command, "The repayment is greater than the accepted balance.")) }
            wallet.acceptedBalanceCents -= command.amountCents
            wallet.loan?.remainingCents -= command.amountCents
        case .loan:
            guard wallet.loan == nil || wallet.loan?.isPaid == true else { return .rejected(rejected(command, "Finish the open loan before creating another one.")) }
            wallet.acceptedBalanceCents += command.amountCents
            wallet.loan = Loan(remoteID: "local-loan", originalCents: command.amountCents, remainingCents: command.amountCents, purpose: command.reason, dueDate: command.dueDate)
        case .deposit, .allowance:
            wallet.acceptedBalanceCents += command.amountCents
        }
        let event = WalletEvent(id: UUID(uuidString: command.idempotencyKey) ?? UUID(), remoteID: command.idempotencyKey, type: activityType(command.kind), amountCents: command.amountCents, balanceBeforeCents: candidate.snapshot.acceptedBalanceCents, balanceAfterCents: wallet.acceptedBalanceCents, reason: command.reason, syncState: .recorded, explanation: explanation(command))
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
    public func continueLocallyAfterCloud() throws {
        var candidate = try writableAggregate()
        guard candidate.metadata.unsettledCloudMutation == nil else {
            throw WalletAPIError.cloudMutationAwaitingReconciliation
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
        aggregate = nil
        legacySnapshot = nil
        legacyMarkerPresent = false
        readOnlyReason = nil
        recoveryState = nil
    }

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
        switch kind { case .allowance: .allowance; case .deposit: .deposit; case .withdrawal: .withdrawal; case .loan: .loan; case .repayment: .repayment }
    }

    private func rejected(_ command: WalletCommand, _ reason: String) -> WalletEvent {
        WalletEvent(type: activityType(command.kind), amountCents: command.amountCents, reason: command.reason, syncState: .rejected, explanation: "This action was not recorded and did not change the accepted balance.", rejectionReason: reason)
    }

    private func explanation(_ command: WalletCommand) -> String {
        let amount = Money(cents: command.amountCents).display
        return switch command.kind {
        case .allowance: "Your parent added \(amount) as your allowance."
        case .deposit: "Your parent added \(amount) to your wallet."
        case .withdrawal: "Your parent recorded that \(amount) was used."
        case .loan: "Your parent gave you \(amount) to use now and give back over time."
        case .repayment: "Your parent recorded \(amount) returned toward the loan."
        }
    }
}
