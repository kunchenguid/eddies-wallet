import Foundation

/// Accepted authority for a Cloud household.
///
/// The protected local store is always a replica. Runtime writes use one
/// durable unresolved-request slot: the request body, If-Match revision, and
/// idempotency key are saved before transport starts and survive relaunch.
/// Until a stable server entry id or accepted revision is observed in a reread,
/// no second mutation or Cloud-to-local authority handoff is allowed.
@MainActor
public final class CloudWalletRepository: WalletRepository, CloudMutationStatusProviding {
    public private(set) var revision: Int64
    public let lineageID: UUID

    private let client: CloudAPIClient
    private let replica: LocalWalletRepository
    private let replicaApplicationLease: Int
    private var requiresBootstrap: Bool
    private var activeMutation: PendingCloudMutation?
    private var isPreparingMutation = false
    /// The one revision a completed server read has vouched for in this
    /// process, or `nil` while nothing current has. Set by every applied read,
    /// left alone by a benign overtaken answer, and withdrawn by a settled
    /// read that reached an answer it could not use or by an explicit
    /// revision refusal. This is the whole in-memory read state: everything
    /// else the read path publishes is derived from it and from the persisted
    /// replica's accepted revision.
    private var confirmedRevision: Int64?
    /// The tail of the serialized read pipeline. Server reads run strictly one
    /// at a time, in the order they were requested, so a settling read is by
    /// construction the newest observation this process has - there is no
    /// arbitration between in-flight reads because reads are never in flight
    /// together.
    private var lastQueuedRead: Task<Void, Never>?
    private var mutationLifecycleGeneration = 0
    private var activeSettlement: ActiveSettlement?
    /// `/v1/cloud/changes` contains the rule but not its pending occurrence.
    /// This service-authoritative read gives parent presentation the actual
    /// earliest due week instead of inferring it from activity timestamps.
    private var allowanceSchedule: CloudAllowanceSchedule.Rule?
    private var allowanceScheduleRevision: Int64?
    /// A persisted replica is readable immediately, but a new process may not
    /// write from it until one successful server read confirms its revision.
    /// Derived, not stored: readiness is exactly "the accepted replica's
    /// revision remains confirmed". A benign overtaken answer changes nothing;
    /// a meaningful failed read withdraws confirmation, so no separate flag can
    /// drift away from the fact it represents.
    public var isReadyForRuntimeMutations: Bool {
        confirmedRevision != nil && confirmedRevision == revision
    }

    public init(
        client: CloudAPIClient,
        replica: LocalWalletRepository,
        lineageID: UUID,
        revision: Int64,
        requiresBootstrap: Bool = false
    ) {
        self.client = client
        self.replica = replica
        self.replicaApplicationLease = replica.cloudApplicationLease
        self.lineageID = lineageID
        self.revision = revision
        self.requiresBootstrap = requiresBootstrap || !replica.hasAcceptedCloudReplica(lineageID: lineageID)
        self.activeMutation = replica.unsettledCloudMutation
    }

    public var isAuthenticated: Bool { client.hasSession }
    public var hasConfiguredKid: Bool { true }
    public var supportsRuntimeMutations: Bool { true }
    public var localReplica: LocalWalletRepository { replica }
    public var hasValidReplica: Bool { replica.hasAcceptedCloudReplica(lineageID: lineageID) }
    public var hasUnsettledMutation: Bool { activeMutation != nil }
    var unsettledMutationPhase: CloudMutationPhase? { activeMutation?.phase }
    var unsettledMutationMessage: String? { activeMutation?.waitingMessage }

    public func snapshot() -> WalletSnapshot {
        guard hasValidReplica else { return .empty() }
        var snapshot = replica.snapshot()
        if let plan = snapshot.allowance, let schedule = allowanceSchedule,
           allowanceScheduleRevision == revision,
           plan.remoteID == schedule.id, plan.amountCents == schedule.amountCents,
           let nextDate = schedule.nextDueDate.flatMap(CloudDayFormat.date(from:)) {
            snapshot.allowance = AllowancePlan(
                remoteID: plan.remoteID,
                amountCents: plan.amountCents,
                cadence: plan.cadence,
                weekday: plan.weekday,
                nextDate: nextDate,
                endDate: plan.endDate,
                nextOccurrenceID: schedule.nextOccurrenceID,
                syncState: plan.syncState
            )
        }
        if let pending = activeMutation?.pendingEvent() {
            snapshot.pendingEvents = [pending]
        }
        return snapshot
    }

    public func childSnapshot() -> WalletSnapshot {
        guard hasValidReplica else { return .empty() }
        // The schedule is read-only parent metadata, but keeping the same next
        // occurrence in both snapshots prevents a parent elevation from
        // momentarily falling back to the rule's original start date.
        var snapshot = self.snapshot()
        snapshot.pendingEvents = []
        return snapshot
    }

    public func refresh(for role: UserRole) async throws -> WalletSnapshot {
        if let activeMutation {
            let reconciledMutation = activeMutation
            switch try await settle(reconciledMutation) {
            case .observed:
                guard role == .parent, hasAllowancePlan else { return snapshot() }
                do {
                    try await refreshAllowanceSchedule()
                } catch let error as WalletAPIError where reconciledMutationNeedsSchedule(reconciledMutation) {
                    throw WalletAPIError.cloudAcceptedScheduleUnavailable.carrying(error.transportDiagnostic)
                } catch where reconciledMutationNeedsSchedule(reconciledMutation) {
                    throw WalletAPIError.cloudAcceptedScheduleUnavailable
                }
                return snapshot()
            case .waiting(let error, let diagnostic):
                switch error.operationError {
                case .noSession, .unauthorized:
                    throw error
                default:
                    throw WalletAPIError.cloudMutationAwaitingReconciliation.carrying(diagnostic)
                }
            case .acceptedAwaitingReplica(_, let diagnostic):
                throw WalletAPIError.cloudAcceptedAwaitingReplica.carrying(diagnostic)
            }
        }
        if requiresBootstrap {
            _ = try await bootstrap()
            if role == .parent, hasAllowancePlan { try await refreshAllowanceSchedule() }
            return snapshot()
        }
        let refreshed = try await serializedRead { [self] in
            do {
                let changes = try await client.changes(afterRevision: revision)
                try apply(changes, merging: true)
                return snapshot()
            } catch {
                // Reads are serialized, so this failure is the newest settled
                // observation and may truthfully withdraw the confirmation an
                // earlier read earned - but only if it observed an answer. A
                // read refused by the Cloud-to-local hand-off lease, or an
                // attempt deliberately retired by a lifecycle change, reports
                // exactly nothing about whether the confirmed revision is
                // still current, which is the same rule the legacy repository
                // applies before marking its cached child view stale. Write
                // safety never rests on this alone: a write still carries the
                // confirmed revision as `If-Match`, so a replica that has
                // silently fallen behind is refused and routed into review.
                if observedAnAnswer(error) { confirmedRevision = nil }
                throw error
            }
        }
        if role == .parent, hasAllowancePlan { try await refreshAllowanceSchedule() }
        _ = refreshed
        return snapshot()
    }

    /// Whether a failed read learned anything about the accepted replica.
    /// Only an answer this device actually saw - an unreachable authority, an
    /// unreadable body, a wrong lineage, a conflict - can call an earlier
    /// read's confirmation into question. A cancelled or lease-refused read
    /// saw nothing and must change nothing.
    private func observedAnAnswer(_ error: Error) -> Bool {
        if error is CancellationError { return false }
        guard let walletError = error as? WalletAPIError else { return true }
        if walletError.operationError == .cancelled { return false }
        if let diagnostic = walletError.transportDiagnostic { return diagnostic.connection != nil }
        return true
    }

    /// Runs one server read at a time, in request order. Serialization is the
    /// whole concurrency design of the Cloud read path: a settling read is
    /// always the newest observation this process has, so no generation or
    /// start-order bookkeeping is needed to decide which of several in-flight
    /// answers "wins" - none are ever in flight together. A waiting caller
    /// that is itself cancelled does not cancel the read: the read belongs to
    /// this repository, runs to completion, and applies what it saw.
    private func serializedRead<T>(_ read: @escaping @MainActor () async throws -> T) async throws -> T {
        let previous = lastQueuedRead
        let next = Task { @MainActor () -> Result<T, Error> in
            await previous?.value
            do {
                return .success(try await read())
            } catch {
                return .failure(error)
            }
        }
        lastQueuedRead = Task { _ = await next.value }
        return try await next.value.get()
    }

    public func bootstrap() async throws -> WalletSnapshot {
        try await serializedRead { [self] in
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
            requiresBootstrap = false
            return snapshot()
        }
    }

    public func activity(limit: Int) async throws -> [WalletEvent] {
        guard hasValidReplica else { return [] }
        return try await replica.activity(limit: limit)
    }

    public func activityDetail(remoteID: String) async throws -> WalletEvent {
        guard hasValidReplica else {
            throw WalletAPIError.server(statusCode: 404, code: "ACTIVITY_NOT_FOUND", message: "The activity entry is not available on this device.")
        }
        return try await replica.activityDetail(remoteID: remoteID)
    }

    public func loanDetail(remoteID: String) async throws -> LoanDetail {
        guard hasValidReplica else {
            throw WalletAPIError.server(statusCode: 404, code: "LOAN_NOT_FOUND", message: "The loan is not available on this device.")
        }
        return try await replica.loanDetail(remoteID: remoteID)
    }

    public func submit(_ command: WalletCommand) async throws -> CommandResult {
        guard activeMutation == nil, !isPreparingMutation else {
            return .rejected(blockedEvent(for: command))
        }
        guard client.hasSession else { throw WalletAPIError.noSession }
        guard isReadyForRuntimeMutations else {
            throw WalletAPIError.revisionRequired.anchoredToRefusedRevision(revision)
        }
        isPreparingMutation = true
        defer { isPreparingMutation = false }
        let mutation = try await moneyMutation(for: command)
        guard activeMutation == nil else {
            return .rejected(blockedEvent(for: command))
        }
        try stage(mutation)
        switch try await settle(mutation) {
        case .observed(let event):
            guard let event else {
                return .acceptedAwaitingReplica(try pendingEvent(for: mutation, phase: .acceptedAwaitingReplica))
            }
            if command.kind == .allowance {
                do {
                    try await refreshAllowanceSchedule(reservingMutationSlot: false)
                } catch let error as WalletAPIError {
                    return .acceptedScheduleUnavailable(event, error: error)
                } catch {
                    return .acceptedScheduleUnavailable(
                        event,
                        error: .invalidResponse("Cloud accepted the allowance payout, but the latest allowance schedule could not be loaded.")
                    )
                }
            }
            return .accepted(event)
        case .waiting(_, let diagnostic):
            if activeMutation?.phase == .rejected {
                throw WalletAPIError.cloudMutationAwaitingReconciliation
            }
            return .pending(
                try pendingEvent(for: mutation, phase: activeMutation?.phase ?? .staged),
                diagnostic: diagnostic
            )
        case .acceptedAwaitingReplica(_, let diagnostic):
            return .acceptedAwaitingReplica(
                try pendingEvent(for: mutation, phase: .acceptedAwaitingReplica),
                diagnostic: diagnostic
            )
        }
    }

    public func setAllowance(_ command: AllowanceRuleCommand) async throws -> WalletSnapshot {
        var body: [String: Any] = [
            "amountCents": command.amountCents,
            "cadence": "weekly",
            "weekday": command.weekday,
            "startDate": CloudDayFormat.string(from: command.startDate),
        ]
        if let endDate = command.endDate {
            body["endDate"] = CloudDayFormat.string(from: endDate)
        }
        let mutation = PendingCloudMutation(
            kind: .setAllowance,
            method: "PUT",
            path: "/v1/allowance-rule",
            body: try encodedBody(body),
            idempotencyKey: command.idempotencyKey,
            expectedRevision: revision
        )
        _ = try await performNonMoneyMutation(mutation)
        do {
            try await refreshAllowanceSchedule()
            return snapshot()
        } catch let error as WalletAPIError {
            throw WalletAPIError.cloudAcceptedScheduleUnavailable.carrying(error.transportDiagnostic)
        } catch {
            throw WalletAPIError.cloudAcceptedScheduleUnavailable
        }
    }

    public func setup(_: ParentSetup) async throws -> WalletSnapshot {
        throw WalletAPIError.invalidResponse("This wallet is already set up.")
    }

    public func updateChildProfile(_ update: ChildProfileUpdate) async throws -> WalletSnapshot {
        guard let nickname = update.validatedNickname else {
            throw WalletAPIError.invalidResponse("Enter a child nickname.")
        }
        let mutation = PendingCloudMutation(
            kind: .childProfile,
            method: "PUT",
            path: "/v1/child",
            body: try encodedBody(["nickname": nickname]),
            idempotencyKey: update.idempotencyKey,
            expectedRevision: revision
        )
        return try await performNonMoneyMutation(mutation)
    }

    public func clearAuthentication() {
        mutationLifecycleGeneration += 1
        client.clearLocalSession()
    }

    public func clearAuthenticationForAccountDeletion() throws {
        mutationLifecycleGeneration += 1
        try client.clearLocalSessionForAccountDeletion()
    }

    public func clearSession() throws {
        mutationLifecycleGeneration += 1
        Task { [client] in
            try? await client.revokeCurrentSession()
        }
        client.clearLocalSession()
    }

    /// Retires the protected local replica before DELETE. It intentionally
    /// keeps the bearer session alive until the service command is sent.
    public func retireReplicaForAccountDeletion() throws {
        try replica.clearSession()
        mutationLifecycleGeneration += 1
        activeMutation = nil
        activeSettlement?.task.cancel()
        activeSettlement = nil
    }

    // MARK: - Mutation construction

    private func moneyMutation(for command: WalletCommand) async throws -> PendingCloudMutation {
        guard hasValidReplica else {
            throw WalletAPIError.invalidResponse("Reconnect before recording a Cloud change.")
        }
        var path: String
        var kind: CloudMutationKind
        var body: [String: Any]
        var authoritativeAmountCents = command.amountCents
        switch command.kind {
        case .deposit:
            kind = .deposit
            path = "/v1/wallet/deposits"
            body = ["amountCents": command.amountCents]
        case .withdrawal:
            kind = .withdrawal
            path = "/v1/wallet/withdrawals"
            body = ["amountCents": command.amountCents]
        case .loan:
            kind = .loan
            path = "/v1/loans"
            body = ["principalCents": command.amountCents]
            if let dueDate = command.dueDate { body["dueDate"] = CloudDayFormat.string(from: dueDate) }
        case .repayment:
            guard let loanID = replica.snapshot().loan?.remoteID else {
                throw WalletAPIError.server(statusCode: 409, code: "LOAN_NOT_FOUND", message: "There is no open loan to repay.")
            }
            kind = .repayment
            path = "/v1/loans/\(pathComponent(loanID))/repayments"
            body = ["amountCents": command.amountCents]
        case .allowance:
            try await refreshAllowanceSchedule(reservingMutationSlot: false)
            guard let rule = allowanceSchedule, let occurrenceID = rule.nextOccurrenceID else {
                throw WalletAPIError.server(statusCode: 409, code: "ALLOWANCE_NOT_SCHEDULED", message: "There is no scheduled allowance occurrence to record.")
            }
            guard command.amountCents == rule.amountCents else {
                throw WalletAPIError.invalidResponse("The allowance amount changed. Review the current schedule before recording it.")
            }
            let calendar = Calendar.current
            let today = calendar.startOfDay(for: .now)
            guard let nextDueDate = rule.nextDueDate.flatMap(CloudDayFormat.date(from:)),
                  calendar.startOfDay(for: nextDueDate) <= today else {
                throw WalletAPIError.invalidResponse("The next allowance occurrence is not due yet.")
            }
            if let expectedDueDate = command.dueDate {
                guard rule.nextDueDate == CloudDayFormat.string(from: expectedDueDate),
                      calendar.startOfDay(for: expectedDueDate) < today else {
                    throw WalletAPIError.invalidResponse("The missed allowance schedule changed. Review the remaining weeks before paying them out.")
                }
            }
            authoritativeAmountCents = rule.amountCents
            kind = .recordAllowance
            path = "/v1/allowance-rule/\(pathComponent(rule.id))/occurrences/\(pathComponent(occurrenceID))/record"
            body = [:]
        }
        if let reason = command.reason {
            body[command.kind == .loan ? "purpose" : "reason"] = reason
        }
        return PendingCloudMutation(
            kind: kind,
            method: "POST",
            path: path,
            body: try encodedBody(body),
            idempotencyKey: command.idempotencyKey,
            expectedRevision: revision,
            amountCents: authoritativeAmountCents,
            reason: command.reason
        )
    }

    private var hasAllowancePlan: Bool {
        replica.snapshot().allowance != nil
    }

    private func reconciledMutationNeedsSchedule(_ mutation: PendingCloudMutation) -> Bool {
        switch mutation.kind {
        case .recordAllowance, .setAllowance: true
        default: false
        }
    }

    /// A schedule read supplements parent presentation only. It never changes
    /// accepted wallet data or weakens the revision proof a Cloud write needs.
    /// A failed read clears the cached occurrence instead of leaving a stale
    /// guessed backlog visible.
    private func refreshAllowanceSchedule(reservingMutationSlot: Bool = true) async throws {
        try await serializedRead { [self] in
            if reservingMutationSlot {
                guard activeMutation == nil, !isPreparingMutation else {
                    throw WalletAPIError.cloudMutationAwaitingReconciliation
                }
                isPreparingMutation = true
            }
            defer {
                if reservingMutationSlot { isPreparingMutation = false }
            }
            let requestedRevision = revision
            do {
                let schedule = try await client.allowanceSchedule()
                guard revision == requestedRevision, confirmedRevision == requestedRevision else {
                    allowanceScheduleRevision = nil
                    throw WalletAPIError.revisionRequired.anchoredToRefusedRevision(requestedRevision)
                }
                allowanceSchedule = schedule.allowanceRule
                allowanceScheduleRevision = requestedRevision
            } catch {
                allowanceScheduleRevision = nil
                if revision == requestedRevision, confirmedRevision == requestedRevision {
                    confirmedRevision = nil
                }
                throw error
            }
        }
    }

    private func performNonMoneyMutation(_ mutation: PendingCloudMutation) async throws -> WalletSnapshot {
        guard activeMutation == nil, !isPreparingMutation else { throw WalletAPIError.cloudMutationAwaitingReconciliation }
        guard client.hasSession else { throw WalletAPIError.noSession }
        guard isReadyForRuntimeMutations else {
            throw WalletAPIError.revisionRequired.anchoredToRefusedRevision(mutation.expectedRevision)
        }
        guard hasValidReplica else {
            throw WalletAPIError.invalidResponse("Reconnect before changing this Cloud wallet.")
        }
        try stage(mutation)
        switch try await settle(mutation) {
        case .observed:
            return snapshot()
        case .waiting(_, let diagnostic):
            throw WalletAPIError.cloudMutationAwaitingReconciliation.carrying(diagnostic)
        case .acceptedAwaitingReplica(_, let diagnostic):
            throw WalletAPIError.cloudAcceptedAwaitingReplica.carrying(diagnostic)
        }
    }

    private func stage(_ mutation: PendingCloudMutation) throws {
        try replica.stageCloudMutation(mutation)
        activeMutation = mutation
    }

    // MARK: - Settlement

    private enum Settlement {
        case observed(WalletEvent?)
        case waiting(WalletAPIError, TransportDiagnostic?)
        case acceptedAwaitingReplica(WalletAPIError?, TransportDiagnostic?)
    }

    private struct ActiveSettlement {
        let token: UUID
        let operationID: UUID
        let task: Task<Settlement, Error>
    }

    private func settle(_ original: PendingCloudMutation) async throws -> Settlement {
        if let activeSettlement {
            guard activeSettlement.operationID == original.operationID else {
                return .waiting(.cloudMutationAwaitingReconciliation, nil)
            }
            return try await activeSettlement.task.value
        }
        let token = UUID()
        let lifecycleGeneration = mutationLifecycleGeneration
        let task = Task { @MainActor [self] in
            try await performSettlement(
                original,
                token: token,
                lifecycleGeneration: lifecycleGeneration
            )
        }
        activeSettlement = ActiveSettlement(
            token: token,
            operationID: original.operationID,
            task: task
        )
        do {
            let result = try await task.value
            clearSettlement(token: token)
            return result
        } catch {
            clearSettlement(token: token)
            throw error
        }
    }

    private func performSettlement(
        _ original: PendingCloudMutation,
        token: UUID,
        lifecycleGeneration: Int
    ) async throws -> Settlement {
        var mutation = original
        if mutation.phase == .rejected {
            let rejection = rejectionError(from: mutation)
            do {
                try clear(mutation)
            } catch {
                activeMutation = mutation
                return .waiting(.cloudMutationAwaitingReconciliation, nil)
            }
            throw rejection
        }
        if mutation.phase == .staged {
            mutation.phase = .awaitingOutcome
            do {
                try replica.markCloudMutationAccepted(mutation)
                activeMutation = mutation
            } catch {
                activeMutation = original
                return .waiting(.cloudMutationAwaitingReconciliation, nil)
            }
        }
        let attemptedMutation = mutation
        if mutation.phase == .awaitingOutcome {
            guard isActive(
                operationID: mutation.operationID,
                token: token,
                lifecycleGeneration: lifecycleGeneration
            ) else {
                return .waiting(.cancelled, nil)
            }
            do {
                let acceptance = try await client.mutate(mutation)
                guard isActive(
                    operationID: mutation.operationID,
                    token: token,
                    lifecycleGeneration: lifecycleGeneration
                ) else {
                    return .waiting(.cancelled, nil)
                }
                mutation.phase = .acceptedAwaitingReplica
                mutation.acceptedEntryID = acceptance.entryID
                mutation.acceptedRevision = acceptance.revision
                activeMutation = mutation
                try? replica.markCloudMutationAccepted(mutation)
            } catch let rejection as WalletAPIError {
                guard isActive(
                    operationID: mutation.operationID,
                    token: token,
                    lifecycleGeneration: lifecycleGeneration
                ) else {
                    return .waiting(.cancelled, nil)
                }
                if isDefinitiveRejection(rejection) {
                    if case .revisionConflict = rejection.operationError {
                        // The service proved the confirmed revision is behind.
                        confirmedRevision = nil
                    } else if case .revisionRequired = rejection.operationError {
                        confirmedRevision = nil
                    }
                    do {
                        try clear(mutation)
                    } catch {
                        mutation.phase = .rejected
                        storeRejection(rejection, in: &mutation)
                        activeMutation = mutation
                        do {
                            try replica.markCloudMutationAccepted(mutation)
                        } catch {
                            activeMutation = attemptedMutation
                            return .waiting(.cloudMutationAwaitingReconciliation, nil)
                        }
                    }
                    throw rejection.anchoredToRefusedRevision(mutation.expectedRevision)
                }
                return .waiting(rejection, diagnostic(for: rejection))
            } catch {
                guard isActive(
                    operationID: mutation.operationID,
                    token: token,
                    lifecycleGeneration: lifecycleGeneration
                ) else {
                    return .waiting(.cancelled, nil)
                }
                return .waiting(
                    .network("Cloud is unavailable right now. The previous change will be checked again."),
                    nil
                )
            }
        }
        return await observeAcceptedMutation(
            mutation,
            token: token,
            lifecycleGeneration: lifecycleGeneration
        )
    }

    private func observeAcceptedMutation(
        _ accepted: PendingCloudMutation,
        token: UUID,
        lifecycleGeneration: Int
    ) async -> Settlement {
        do {
            return try await serializedRead { [self] in
                let changes = try await client.changes(afterRevision: accepted.expectedRevision)
                guard isActive(
                    operationID: accepted.operationID,
                    token: token,
                    lifecycleGeneration: lifecycleGeneration
                ) else {
                    return .waiting(.cancelled, nil)
                }
                var resolving = accepted
                if resolving.acceptedEntryID == nil,
                   resolving.kind.isMoney,
                   let acceptedRevision = resolving.acceptedRevision {
                    let matchingEntries = changes.entries.filter { $0.acceptedRevision == acceptedRevision }
                    if matchingEntries.count == 1 {
                        resolving.acceptedEntryID = matchingEntries[0].id
                        activeMutation = resolving
                        try? replica.markCloudMutationAccepted(resolving)
                    }
                }
                let observed = try apply(changes, merging: true, resolving: resolving)
                guard observed else { return .acceptedAwaitingReplica(nil, nil) }
                let event = resolving.acceptedEntryID.flatMap { entryID in
                    replica.snapshot().activities.first { $0.remoteID == entryID }
                }
                return .observed(event)
            }
        } catch let error as WalletAPIError {
            return .acceptedAwaitingReplica(error, diagnostic(for: error))
        } catch {
            return .acceptedAwaitingReplica(nil, nil)
        }
    }

    private func diagnostic(for error: WalletAPIError) -> TransportDiagnostic? {
        error.transportDiagnostic
    }

    private func isActive(
        operationID: UUID,
        token: UUID,
        lifecycleGeneration: Int
    ) -> Bool {
        activeSettlement?.token == token
            && mutationLifecycleGeneration == lifecycleGeneration
            && activeMutation?.operationID == operationID
            && replica.cloudApplicationLease == replicaApplicationLease
            && replica.isCloudAuthority
            && replica.unsettledCloudMutation?.operationID == operationID
    }

    private func clearSettlement(token: UUID) {
        if activeSettlement?.token == token {
            activeSettlement = nil
        }
    }

    private func isDefinitiveRejection(_ error: WalletAPIError) -> Bool {
        switch error.operationError {
        case .revisionConflict, .revisionRequired, .cloudEntitlementRequired:
            true
        case .server(let statusCode, let code, _):
            statusCode != 408
                && code != "COMMAND_IN_PROGRESS"
                && (400..<500).contains(statusCode)
        case .noSession, .unauthorized, .familyNotSetup, .identityMismatch,
             .invalidConfiguration, .network, .transportFailure, .requestFailure,
             .cloudRevisionRefusal, .invalidResponse, .cancelled, .timedOut,
             .cloudMutationAwaitingReconciliation, .cloudAcceptedAwaitingReplica,
             .cloudAcceptedScheduleUnavailable:
            false
        }
    }

    private func clear(_ mutation: PendingCloudMutation) throws {
        try replica.clearCloudMutation(operationID: mutation.operationID)
        activeMutation = nil
    }

    /// Applies a Cloud answer under the one arbitration rule the read path
    /// has: compare the answer's revision with the accepted replica's.
    ///
    /// Authority is validated first, so a wrong lineage or a retired hand-off
    /// lease stays an error. After that, an answer older than the accepted
    /// replica is one this device has already overtaken - the service may
    /// answer a fresh request from a lagging snapshot - and it is a benign
    /// no-op: it publishes nothing, proves nothing, and takes nothing away,
    /// including the confirmation a current read already earned. An answer at
    /// or past the accepted revision applies and becomes the confirmed one.
    ///
    /// Because the rule compares values instead of tracking which request
    /// started when, no ordering of arrivals can regress accepted state.
    /// `LocalWalletRepository.applyCloudReplica`'s monotonic revision guard
    /// remains the last defence beneath this for anything that bypasses it.
    @discardableResult
    private func apply(
        _ replicaPayload: CloudReplica,
        merging: Bool,
        resolving mutation: PendingCloudMutation? = nil
    ) throws -> Bool {
        _ = try replica.validateCloudReplicaAuthority(
            replicaPayload,
            applicationLease: replicaApplicationLease
        )
        if let accepted = replica.cloudRevision, replicaPayload.household.revision < accepted {
            return false
        }
        let observed = try replica.applyCloudReplica(
            replicaPayload,
            merging: merging,
            resolving: mutation,
            applicationLease: replicaApplicationLease
        )
        revision = replicaPayload.household.revision
        confirmedRevision = replicaPayload.household.revision
        if observed {
            activeMutation = nil
        } else {
            activeMutation = replica.unsettledCloudMutation ?? activeMutation
        }
        return observed
    }

    private func storeRejection(_ error: WalletAPIError, in mutation: inout PendingCloudMutation) {
        switch error.operationError {
        case .revisionConflict(let currentRevision):
            mutation.rejectionStatusCode = 409
            mutation.rejectionCode = "REVISION_CONFLICT"
            mutation.rejectionCurrentRevision = currentRevision
            mutation.rejectionMessage = "The wallet changed elsewhere. Refresh and review before trying again."
        case .revisionRequired:
            mutation.rejectionStatusCode = 428
            mutation.rejectionCode = "REVISION_REQUIRED"
            mutation.rejectionMessage = "Cloud changes require the current household revision."
        case .cloudEntitlementRequired:
            mutation.rejectionStatusCode = 403
            mutation.rejectionCode = "CLOUD_ENTITLEMENT_REQUIRED"
            mutation.rejectionMessage = "Cloud access is required for this change."
        case .server(let statusCode, let code, let message):
            mutation.rejectionStatusCode = statusCode
            mutation.rejectionCode = code
            mutation.rejectionMessage = message
        default:
            mutation.rejectionMessage = "Cloud did not record this change."
        }
    }

    private func rejectionError(from mutation: PendingCloudMutation) -> WalletAPIError {
        let rejection: WalletAPIError
        switch mutation.rejectionCode {
        case "REVISION_CONFLICT":
            rejection = .revisionConflict(currentRevision: mutation.rejectionCurrentRevision ?? mutation.expectedRevision)
        case "REVISION_REQUIRED":
            rejection = .revisionRequired
        default:
            rejection = .server(
                statusCode: mutation.rejectionStatusCode ?? 409,
                code: mutation.rejectionCode ?? "COMMAND_REJECTED",
                message: mutation.rejectionMessage ?? "Cloud did not record this change."
            )
        }
        return rejection.anchoredToRefusedRevision(mutation.expectedRevision)
    }

    // MARK: - Presentation helpers

    private func pendingEvent(for mutation: PendingCloudMutation, phase: CloudMutationPhase) throws -> WalletEvent {
        var copy = activeMutation ?? mutation
        copy.phase = phase
        guard let event = copy.pendingEvent() else {
            throw WalletAPIError.invalidResponse("The pending Cloud money change could not be shown.")
        }
        return event
    }

    private func blockedEvent(for command: WalletCommand) -> WalletEvent {
        WalletEvent(
            type: activityType(for: command.kind),
            amountCents: max(command.amountCents, 0),
            reason: command.reason,
            syncState: .rejected,
            explanation: "This new action was not sent.",
            rejectionReason: "Check the previous Cloud change before recording another action."
        )
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

    private func encodedBody(_ body: [String: Any]) throws -> Data {
        guard JSONSerialization.isValidJSONObject(body) else {
            throw WalletAPIError.invalidResponse("The Cloud request could not be encoded.")
        }
        return try JSONSerialization.data(withJSONObject: body)
    }

    private func pathComponent(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? value
    }
}
