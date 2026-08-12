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
    private var nextReadGeneration = 0
    private var lastAppliedReadGeneration = 0
    /// The server revision of the newest read this instance actually applied,
    /// or `nil` while the persisted replica is still unconfirmed. It is
    /// deliberately not `revision`, which starts at the persisted value: a
    /// server answer older than a revision no read has confirmed in this
    /// process is an unexplained regression, not a race, and stays an error.
    private var lastAppliedRevision: Int64?
    private var mutationLifecycleGeneration = 0
    private var activeSettlement: ActiveSettlement?
    /// A persisted replica is readable immediately, but a new process may not
    /// write from it until one successful server read confirms its revision.
    public private(set) var isReadyForRuntimeMutations = false

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
        if let pending = activeMutation?.pendingEvent() {
            snapshot.pendingEvents = [pending]
        }
        return snapshot
    }

    public func childSnapshot() -> WalletSnapshot {
        hasValidReplica ? replica.childSnapshot() : .empty()
    }

    public func refresh(for _: UserRole) async throws -> WalletSnapshot {
        let attemptedReadGeneration = nextReadGeneration + 1
        if let activeMutation {
            switch try await settle(activeMutation) {
            case .observed:
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
        do {
            if requiresBootstrap {
                return try await bootstrap()
            }
            let readGeneration = beginRead()
            let changes = try await client.changes(afterRevision: revision)
            // A lower-revision answer this device may have overtaken is not a
            // failure once its authority is validated. It publishes nothing
            // and reports the newer wallet it arrived behind.
            if isObsolete(changes, readGeneration: readGeneration) {
                try replica.validateCloudReplicaAuthority(
                    changes,
                    applicationLease: replicaApplicationLease
                )
                return snapshot()
            }
            try apply(changes, merging: true, readGeneration: readGeneration)
            return snapshot()
        } catch {
            if lastAppliedReadGeneration < attemptedReadGeneration, observedAnAnswer(error) {
                isReadyForRuntimeMutations = false
            }
            throw error
        }
    }

    /// Whether a failed read learned anything about the accepted replica.
    ///
    /// Write readiness records that one successful read confirmed this
    /// replica's revision in this process. Only a read that actually observed
    /// something - an unreachable authority, an unreadable answer, a wrong
    /// lineage, a conflict - can call that confirmation into question, and it
    /// still does. A read that observed no answer at all cannot: a
    /// pull-to-refresh SwiftUI ends, a read retired by a newer one, and a read
    /// refused by the Cloud-to-local hand-off lease all report exactly nothing
    /// about whether the confirmed revision is still current.
    ///
    /// Withdrawing readiness for those was the whole 0.1.14 parent-area defect.
    /// SwiftUI ends the task behind a pull-to-refresh, so an ordinary parent
    /// pull killed its own read in flight; readiness was dropped here while
    /// `WalletStore.refresh` correctly published nothing for an attempt that
    /// observed nothing. The parent was left with every money action disabled
    /// beside a green "syncing with Cloud" line, no error, and - because no
    /// review was actually pending - no way to clear it.
    ///
    /// This is the same rule the legacy repository already applies to its
    /// cached child view, which will not mark a wallet stale on a cancelled
    /// attempt either. Write safety is untouched: the write itself still
    /// carries the confirmed revision as `If-Match`, so a replica that has
    /// silently fallen behind is refused by the service and routed into review.
    private func observedAnAnswer(_ error: Error) -> Bool {
        if error is CancellationError { return false }
        guard let walletError = error as? WalletAPIError else { return true }
        if walletError.operationError == .cancelled { return false }
        if let diagnostic = walletError.transportDiagnostic { return diagnostic.connection != nil }
        return true
    }

    public func bootstrap() async throws -> WalletSnapshot {
        let readGeneration = beginRead()
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
        try apply(complete, merging: false, readGeneration: readGeneration)
        requiresBootstrap = false
        return snapshot()
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
        guard activeMutation == nil else {
            return .rejected(blockedEvent(for: command))
        }
        guard client.hasSession else { throw WalletAPIError.noSession }
        guard isReadyForRuntimeMutations else { throw WalletAPIError.revisionRequired }
        let mutation = try await moneyMutation(for: command)
        try stage(mutation)
        switch try await settle(mutation) {
        case .observed(let event):
            guard let event else {
                return .acceptedAwaitingReplica(try pendingEvent(for: mutation, phase: .acceptedAwaitingReplica))
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
        return try await performNonMoneyMutation(mutation)
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
            let schedule = try await client.allowanceSchedule()
            guard let rule = schedule.allowanceRule, let occurrenceID = rule.nextOccurrenceID else {
                throw WalletAPIError.server(statusCode: 409, code: "ALLOWANCE_NOT_SCHEDULED", message: "There is no scheduled allowance occurrence to record.")
            }
            guard command.amountCents == rule.amountCents else {
                throw WalletAPIError.invalidResponse("The allowance amount changed. Review the current schedule before recording it.")
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

    private func performNonMoneyMutation(_ mutation: PendingCloudMutation) async throws -> WalletSnapshot {
        guard activeMutation == nil else { throw WalletAPIError.cloudMutationAwaitingReconciliation }
        guard client.hasSession else { throw WalletAPIError.noSession }
        guard isReadyForRuntimeMutations else { throw WalletAPIError.revisionRequired }
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
                        isReadyForRuntimeMutations = false
                    } else if case .revisionRequired = rejection.operationError {
                        isReadyForRuntimeMutations = false
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
                    throw rejection
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
            let readGeneration = beginRead()
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
            let observed = try apply(
                changes,
                merging: true,
                resolving: resolving,
                readGeneration: readGeneration
            )
            guard observed else { return .acceptedAwaitingReplica(nil, nil) }
            let event = resolving.acceptedEntryID.flatMap { entryID in
                replica.snapshot().activities.first { $0.remoteID == entryID }
            }
            return .observed(event)
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
             .invalidConfiguration, .network, .transportFailure, .requestFailure, .invalidResponse,
             .cancelled, .timedOut,
             .cloudMutationAwaitingReconciliation, .cloudAcceptedAwaitingReplica:
            false
        }
    }

    private func clear(_ mutation: PendingCloudMutation) throws {
        try replica.clearCloudMutation(operationID: mutation.operationID)
        activeMutation = nil
    }

    @discardableResult
    private func apply(
        _ replicaPayload: CloudReplica,
        merging: Bool,
        resolving mutation: PendingCloudMutation? = nil,
        readGeneration: Int
    ) throws -> Bool {
        guard readGeneration >= lastAppliedReadGeneration else {
            throw WalletAPIError.cancelled
        }
        let observed = try replica.applyCloudReplica(
            replicaPayload,
            merging: merging,
            resolving: mutation,
            applicationLease: replicaApplicationLease
        )
        lastAppliedReadGeneration = readGeneration
        revision = replicaPayload.household.revision
        lastAppliedRevision = replicaPayload.household.revision
        isReadyForRuntimeMutations = true
        if observed {
            activeMutation = nil
        } else {
            activeMutation = replica.unsettledCloudMutation ?? activeMutation
        }
        return observed
    }

    private func beginRead() -> Int {
        nextReadGeneration += 1
        return nextReadGeneration
    }

    /// Whether an arriving Cloud answer has already been overtaken.
    ///
    /// Reads overlap by design - the store starts one, the kid home starts
    /// another, and a pull starts a third - and the service may answer a
    /// later-started request from an older snapshot than one that already
    /// landed. Ordering reads only by when they started cannot see that: the
    /// later request wins the generation test, reaches the replica, and is
    /// refused there for regressing the accepted revision. For an answer from
    /// the expected Cloud authority, nothing was wrong with the request or
    /// connection, so publication is ordered by observed revision as well and
    /// the overtaken answer becomes a benign no-op. The caller validates that
    /// authority before accepting the no-op.
    ///
    /// The opposite ordering - a read that *started* earlier arriving after a
    /// later one applied - is a retired read, and `apply` still refuses it as
    /// cancelled. Neither case may reach replica application, whose monotonic
    /// revision guard remains the last defence for accepted state.
    private func isObsolete(_ replicaPayload: CloudReplica, readGeneration: Int) -> Bool {
        guard readGeneration >= lastAppliedReadGeneration, let lastAppliedRevision else { return false }
        return replicaPayload.household.revision < lastAppliedRevision
    }

    private func storeRejection(_ error: WalletAPIError, in mutation: inout PendingCloudMutation) {
        switch error.operationError {
        case .revisionConflict:
            mutation.rejectionStatusCode = 409
            mutation.rejectionCode = "REVISION_CONFLICT"
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
        .server(
            statusCode: mutation.rejectionStatusCode ?? 409,
            code: mutation.rejectionCode ?? "COMMAND_REJECTED",
            message: mutation.rejectionMessage ?? "Cloud did not record this change."
        )
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
