import Foundation

/// Accepted authority for a Cloud household.
///
/// Every mutation carries the retained household revision as `If-Match`, and an
/// accepted mutation is followed by a `/v1/cloud/changes` refresh, so the
/// device only ever renders server-accepted state. The local protected store is
/// kept as the offline replica; it is never treated as authoritative while
/// Cloud owns the lineage.
@MainActor
public final class CloudWalletRepository: WalletRepository {
    public private(set) var revision: Int64
    public let lineageID: UUID
    /// Set when the server refused a write because another device moved first.
    public private(set) var lastConflictRevision: Int64?

    private let client: CloudAPIClient
    private let replica: LocalWalletRepository
    private var inMemoryAcceptedCommand: AcceptedCommand?

    private struct AcceptedCommand {
        let command: WalletCommand
        let acceptedRevision: Int64?
        let event: WalletEvent
    }

    public init(client: CloudAPIClient, replica: LocalWalletRepository, lineageID: UUID, revision: Int64) {
        self.client = client
        self.replica = replica
        self.lineageID = lineageID
        self.revision = revision
    }

    public var isAuthenticated: Bool { client.hasSession }
    public var hasConfiguredKid: Bool { true }
    public var localReplica: LocalWalletRepository { replica }
    var hasUnreconciledAcceptedCommand: Bool {
        inMemoryAcceptedCommand != nil || replica.pendingCloudCommand != nil
    }

    public func snapshot() -> WalletSnapshot {
        var snapshot = replica.snapshot()
        if let event = inMemoryAcceptedCommand?.event,
           !snapshot.pendingEvents.contains(where: { $0.syncState == .acceptedAwaitingReplica }) {
            snapshot.pendingEvents.insert(event, at: 0)
        }
        return snapshot
    }
    public func childSnapshot() -> WalletSnapshot { replica.childSnapshot() }

    public func refresh(for _: UserRole) async throws -> WalletSnapshot {
        let changes = try await client.changes(afterRevision: revision)
        try apply(changes, merging: true)
        return snapshot()
    }

    /// Complete replica download for a second device, or a first sync after
    /// activation. Every page is collected before anything is written.
    public func bootstrap() async throws -> WalletSnapshot {
        var page = try await client.bootstrap()
        var entries = page.entries
        var guardrail = 0
        while let cursor = page.nextCursor, guardrail < 200 {
            guardrail += 1
            page = try await client.bootstrap(cursor: cursor)
            entries += page.entries
        }
        let complete = CloudReplica(
            household: page.household,
            family: page.family,
            child: page.child,
            wallet: page.wallet,
            entries: entries,
            loans: page.loans,
            allowanceRule: page.allowanceRule,
            nextCursor: nil
        )
        try apply(complete, merging: false)
        return snapshot()
    }

    public func activity(limit: Int) async throws -> [WalletEvent] { try await replica.activity(limit: limit) }
    public func activityDetail(remoteID: String) async throws -> WalletEvent { try await replica.activityDetail(remoteID: remoteID) }
    public func loanDetail(remoteID: String) async throws -> LoanDetail { try await replica.loanDetail(remoteID: remoteID) }

    public func submit(_ command: WalletCommand) async throws -> CommandResult {
        guard !hasUnreconciledAcceptedCommand else {
            return .rejected(
                WalletEvent(
                    type: activityType(for: command.kind),
                    amountCents: command.amountCents,
                    reason: command.reason,
                    syncState: .rejected,
                    explanation: "This device is still catching up with Cloud. Refresh before recording another action.",
                    rejectionReason: "This device is still catching up with Cloud. Refresh before recording another action."
                )
            )
        }
        let priorEventIDs = Set(replica.snapshot().activities.map(\.id))
        let request = try await commandRequest(for: command)
        do {
            try await accept(
                path: request.path,
                body: request.body,
                idempotencyKey: command.idempotencyKey,
                acceptedCommand: command
            )
        } catch WalletAPIError.acceptedStateUnavailable {
            return acceptedAwaitingReplicaEvent(for: command)
        }
        guard let accepted = replica.snapshot().activities.first(where: {
            !priorEventIDs.contains($0.id) &&
                $0.type == activityType(for: command.kind) &&
                $0.amountCents == command.amountCents
        }) else {
            return acceptedAwaitingReplicaEvent(for: command)
        }
        return .accepted(accepted)
    }

    public func setAllowance(_ command: AllowanceRuleCommand) async throws -> WalletSnapshot {
        _ = try await accept(
            path: "/v1/allowance-rule",
            body: [
                "amountCents": command.amountCents,
                "cadence": "weekly",
                "weekday": command.weekday,
                "startDate": CloudDayFormat.string(from: command.startDate),
            ].merging(command.endDate.map { ["endDate": CloudDayFormat.string(from: $0)] } ?? [:]) { current, _ in current },
            idempotencyKey: command.idempotencyKey,
            method: "PUT"
        )
        return replica.snapshot()
    }

    public func setup(_: ParentSetup) async throws -> WalletSnapshot {
        throw WalletAPIError.invalidResponse("This wallet is already set up.")
    }

    public func updateChildProfile(_ update: ChildProfileUpdate) async throws -> WalletSnapshot {
        guard let nickname = update.validatedNickname else { throw WalletAPIError.invalidResponse("Enter a child nickname.") }
        _ = try await accept(
            path: "/v1/child/profile",
            body: ["nickname": nickname],
            idempotencyKey: update.idempotencyKey,
            method: "PATCH"
        )
        return replica.snapshot()
    }

    public func clearAuthentication() { client.clearLocalSession() }

    /// Authority-aware sign-out. The server session is revoked and this device
    /// stops syncing; the mirrored Cloud history is deliberately left in place.
    public func clearSession() throws {
        Task { [client] in
            try? await client.revokeCurrentSession()
        }
        client.clearLocalSession()
    }

    // MARK: - Private

    private struct CommandRequest {
        let path: String
        let body: [String: Any]
    }

    private func commandRequest(for command: WalletCommand) async throws -> CommandRequest {
        switch command.kind {
        case .deposit:
            return CommandRequest(path: "/v1/wallet/deposits", body: money(command))
        case .withdrawal:
            return CommandRequest(path: "/v1/wallet/withdrawals", body: money(command))
        case .loan:
            var body: [String: Any] = ["principalCents": command.amountCents]
            if let purpose = command.reason { body["purpose"] = purpose }
            if let dueDate = command.dueDate { body["dueDate"] = CloudDayFormat.string(from: dueDate) }
            return CommandRequest(path: "/v1/loans", body: body)
        case .repayment:
            guard let loanID = replica.snapshot().loan?.remoteID, !loanID.isEmpty else {
                throw WalletAPIError.invalidResponse("There is no open loan to repay in the Cloud wallet.")
            }
            return CommandRequest(path: "/v1/loans/\(loanID)/repayments", body: money(command))
        case .allowance:
            let schedule = try await client.allowanceSchedule()
            guard let ruleID = schedule.allowanceRule?.id,
                  let occurrenceID = schedule.allowanceRule?.nextOccurrenceID else {
                throw WalletAPIError.invalidResponse("There is no allowance due to record right now.")
            }
            var body: [String: Any] = [:]
            if let reason = command.reason { body["reason"] = reason }
            return CommandRequest(path: "/v1/allowance-rule/\(ruleID)/occurrences/\(occurrenceID)/record", body: body)
        }
    }

    private func money(_ command: WalletCommand) -> [String: Any] {
        var body: [String: Any] = ["amountCents": command.amountCents]
        if let reason = command.reason { body["reason"] = reason }
        return body
    }

    private func acceptedAwaitingReplicaEvent(for command: WalletCommand) -> CommandResult {
        if let event = inMemoryAcceptedCommand?.event ??
            replica.snapshot().pendingEvents.first(where: { $0.syncState == .acceptedAwaitingReplica }) {
            return .acceptedAwaitingReplica(event)
        }
        return .acceptedAwaitingReplica(awaitingEvent(for: command))
    }

    private func awaitingEvent(for command: WalletCommand) -> WalletEvent {
        WalletEvent(
            id: UUID(uuidString: command.idempotencyKey) ?? UUID(),
            type: activityType(for: command.kind),
            amountCents: command.amountCents,
            reason: command.reason,
            syncState: .acceptedAwaitingReplica,
            explanation: "Cloud recorded this action. This device has not shown it yet and will refresh."
        )
    }

    /// Sends one revision-guarded command and re-reads accepted state. A stale
    /// revision refreshes the replica first, so the parent reviews the latest
    /// accepted balance before retrying.
    @discardableResult
    private func accept(
        path: String,
        body: [String: Any],
        idempotencyKey: String,
        method: String = "POST",
        acceptedCommand: WalletCommand? = nil
    ) async throws -> CloudAPIClient.CommandAcceptance {
        guard !hasUnreconciledAcceptedCommand else {
            throw WalletAPIError.invalidResponse("This device is still catching up with Cloud. Refresh before making another change.")
        }
        let previousRevision = revision
        do {
            let acceptance = try await client.command(
                path: path,
                body: body,
                expectedRevision: revision,
                idempotencyKey: idempotencyKey,
                method: method
            )
            lastConflictRevision = nil
            if let acceptedCommand {
                inMemoryAcceptedCommand = AcceptedCommand(
                    command: acceptedCommand,
                    acceptedRevision: acceptance.revision,
                    event: awaitingEvent(for: acceptedCommand)
                )
                do {
                    try replica.markCloudCommandAcceptedAwaitingReplica(
                        acceptedCommand,
                        acceptedRevision: acceptance.revision
                    )
                } catch {
                    throw WalletAPIError.acceptedStateUnavailable
                }
            }
            do {
                try await syncChanges(after: previousRevision)
            } catch {
                throw WalletAPIError.acceptedStateUnavailable
            }
            return acceptance
        } catch WalletAPIError.revisionConflict(let currentRevision) {
            lastConflictRevision = currentRevision
            try? await syncChanges(after: previousRevision)
            throw WalletAPIError.revisionConflict(currentRevision: currentRevision)
        }
    }

    private func syncChanges(after previousRevision: Int64) async throws {
        let changes = try await client.changes(afterRevision: previousRevision)
        try apply(changes, merging: true)
    }

    private func apply(_ replicaPayload: CloudReplica, merging: Bool) throws {
        try replica.applyCloudReplica(replicaPayload, merging: merging)
        revision = max(revision, replicaPayload.household.revision)
        if let accepted = inMemoryAcceptedCommand,
           let acceptedRevision = accepted.acceptedRevision,
           replicaPayload.entries.contains(where: {
               $0.acceptedRevision == acceptedRevision &&
                   $0.type == activityType(for: accepted.command.kind).rawValue &&
                   $0.amountCents == accepted.command.amountCents
           }) {
            inMemoryAcceptedCommand = nil
        }
    }

    private func activityType(for kind: WalletCommandKind) -> ActivityType {
        switch kind {
        case .allowance: .allowance
        case .deposit: .deposit
        case .withdrawal: .withdrawal
        case .loan: .loan
        case .repayment: .repayment
        }
    }
}
