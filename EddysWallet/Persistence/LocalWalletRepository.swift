import Foundation

struct LocalWalletMetadata: Codable, Sendable {
    var schemaVersion = 1
    var lineageID: UUID
    var authority = "local"
    var serverHouseholdID: String?
    var serverRevision: Int64 = 0
    var lastServerSync: Date?
    var migrationState = "complete"
    var pendingCloudCommand: WalletCommand?
}

private struct LocalWalletAggregate: Codable, Sendable {
    var metadata: LocalWalletMetadata
    var snapshot: WalletSnapshot
}

/// Free authority. It deliberately does not hold a session or call the
/// backend. Every parent mutation validates and persists accepted state in a
/// single Core Data save, then returns Recorded.
@MainActor
public final class LocalWalletRepository: WalletRepository {
    private let persistence: any LocalWalletPersisting
    private var aggregate: LocalWalletAggregate?
    private var readOnlyReason: String?
    /// A pre-Core-Data marker/cache is a migration input only. It stays
    /// read-only and is never promoted to local authority because it may hold
    /// only ten recent events.
    private var legacySnapshot: WalletSnapshot?

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
            }
        } else if hasLegacyMarker || legacySnapshot != nil {
            self.legacySnapshot = legacySnapshot
        }
    }

    public convenience init() throws {
        let cache = UserDefaultsWalletSnapshotCache().load()
        try self.init(legacySnapshot: cache, hasLegacyMarker: UserDefaultsConfiguredKidStore().isConfigured)
    }

    public var isAuthenticated: Bool { aggregate != nil || legacySnapshot != nil || readOnlyReason != nil }
    public var hasConfiguredKid: Bool { aggregate != nil || legacySnapshot != nil || readOnlyReason != nil }
    public var hasLegacyInputs: Bool { aggregate == nil && legacySnapshot != nil }
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

    public func clearAuthentication() {}
    public func clearSession() throws {
        try persistence.erase()
        aggregate = nil
        legacySnapshot = nil
        readOnlyReason = nil
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
