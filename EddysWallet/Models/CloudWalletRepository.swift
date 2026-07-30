import Foundation

/// Read-only accepted authority for a Cloud household.
///
/// The local protected store remains an offline replica and is never treated
/// as authoritative while Cloud owns the lineage. Runtime mutations are
/// intentionally unavailable in this vertical slice.
@MainActor
public final class CloudWalletRepository: WalletRepository {
    public private(set) var revision: Int64
    public let lineageID: UUID

    private let client: CloudAPIClient
    private let replica: LocalWalletRepository
    private var requiresBootstrap: Bool

    public init(
        client: CloudAPIClient,
        replica: LocalWalletRepository,
        lineageID: UUID,
        revision: Int64,
        requiresBootstrap: Bool = false
    ) {
        self.client = client
        self.replica = replica
        self.lineageID = lineageID
        self.revision = revision
        self.requiresBootstrap = requiresBootstrap
    }

    public var isAuthenticated: Bool { client.hasSession }
    public var hasConfiguredKid: Bool { true }
    public var supportsRuntimeMutations: Bool { false }
    public var localReplica: LocalWalletRepository { replica }

    public func snapshot() -> WalletSnapshot { replica.snapshot() }
    public func childSnapshot() -> WalletSnapshot { replica.childSnapshot() }

    public func refresh(for _: UserRole) async throws -> WalletSnapshot {
        if requiresBootstrap {
            return try await bootstrap()
        }
        let changes = try await client.changes(afterRevision: revision)
        try apply(changes, merging: true)
        return snapshot()
    }

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
        requiresBootstrap = false
        return snapshot()
    }

    public func activity(limit: Int) async throws -> [WalletEvent] {
        try await replica.activity(limit: limit)
    }

    public func activityDetail(remoteID: String) async throws -> WalletEvent {
        try await replica.activityDetail(remoteID: remoteID)
    }

    public func loanDetail(remoteID: String) async throws -> LoanDetail {
        try await replica.loanDetail(remoteID: remoteID)
    }

    public func submit(_: WalletCommand) async throws -> CommandResult {
        throw WalletAPIError.cloudRuntimeWritesUnavailable
    }

    public func setAllowance(_: AllowanceRuleCommand) async throws -> WalletSnapshot {
        throw WalletAPIError.cloudRuntimeWritesUnavailable
    }

    public func setup(_: ParentSetup) async throws -> WalletSnapshot {
        throw WalletAPIError.invalidResponse("This wallet is already set up.")
    }

    public func updateChildProfile(_: ChildProfileUpdate) async throws -> WalletSnapshot {
        throw WalletAPIError.cloudRuntimeWritesUnavailable
    }

    public func clearAuthentication() {
        client.clearLocalSession()
    }

    public func clearSession() throws {
        Task { [client] in
            try? await client.revokeCurrentSession()
        }
        client.clearLocalSession()
    }

    private func apply(_ replicaPayload: CloudReplica, merging: Bool) throws {
        try replica.applyCloudReplica(replicaPayload, merging: merging)
        revision = max(revision, replicaPayload.household.revision)
    }
}
