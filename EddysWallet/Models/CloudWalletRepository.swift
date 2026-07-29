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

    public init(client: CloudAPIClient, replica: LocalWalletRepository, lineageID: UUID, revision: Int64) {
        self.client = client
        self.replica = replica
        self.lineageID = lineageID
        self.revision = revision
    }

    public var isAuthenticated: Bool { client.hasSession }
    public var hasConfiguredKid: Bool { true }
    public var localReplica: LocalWalletRepository { replica }

    public func snapshot() -> WalletSnapshot { replica.snapshot() }
    public func childSnapshot() -> WalletSnapshot { replica.childSnapshot() }

    public func refresh(for _: UserRole) async throws -> WalletSnapshot {
        let changes = try await client.changes(afterRevision: revision)
        try apply(changes, merging: true)
        return replica.snapshot()
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
        return replica.snapshot()
    }

    public func activity(limit: Int) async throws -> [WalletEvent] { try await replica.activity(limit: limit) }
    public func activityDetail(remoteID: String) async throws -> WalletEvent { try await replica.activityDetail(remoteID: remoteID) }
    public func loanDetail(remoteID: String) async throws -> LoanDetail { try await replica.loanDetail(remoteID: remoteID) }

    public func submit(_ command: WalletCommand) async throws -> CommandResult {
        let request = try commandRequest(for: command)
        try await accept(path: request.path, body: request.body, idempotencyKey: command.idempotencyKey)
        let accepted = replica.snapshot().activities.first {
            $0.type == activityType(for: command.kind) && $0.amountCents == command.amountCents
        }
        return .accepted(
            accepted ?? WalletEvent(
                type: activityType(for: command.kind),
                amountCents: command.amountCents,
                reason: command.reason,
                syncState: .recorded,
                explanation: AcceptedEventCopy.explanation(for: activityType(for: command.kind), amountCents: command.amountCents)
            )
        )
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

    private func commandRequest(for command: WalletCommand) throws -> CommandRequest {
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
            let allowance = replica.snapshot().allowance
            guard let ruleID = allowance?.remoteID, let occurrenceID = allowance?.nextOccurrenceID else {
                throw WalletAPIError.invalidResponse("Set the weekly allowance in the Cloud wallet before recording it.")
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

    /// Sends one revision-guarded command and re-reads accepted state. A stale
    /// revision refreshes the replica first, so the parent reviews the latest
    /// accepted balance before retrying.
    @discardableResult
    private func accept(path: String, body: [String: Any], idempotencyKey: String, method: String = "POST") async throws -> CloudAPIClient.CommandAcceptance {
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
            if let accepted = acceptance.revision { revision = accepted }
            try? await syncChanges(after: previousRevision)
            return acceptance
        } catch WalletAPIError.revisionConflict(let currentRevision) {
            lastConflictRevision = currentRevision
            revision = currentRevision
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
