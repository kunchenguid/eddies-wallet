import Foundation
import StoreKit

@MainActor
protocol CloudStoreKitOperations {
    func products(for identifiers: Set<String>) async throws -> [Product]
    func purchase(productID: String, product: Product?, accountToken: UUID) async throws -> CloudStoreKitPurchaseResult
    func currentEntitlements() async -> CloudStoreKitScanOutcome
    func latestTransactions() async -> CloudStoreKitScanOutcome
    func transactionHistory() async -> CloudStoreKitScanOutcome
    func subscriptionStatusTransactions() async -> CloudStoreKitScanOutcome
    func unfinishedEvents() -> AsyncStream<CloudStoreKitStreamEvent>
    func updateEvents() -> AsyncStream<CloudStoreKitStreamEvent>
    func sync() async throws
}

enum CloudStoreKitPurchaseResult {
    case success(CloudStoreKitTransaction)
    case pending
    case userCancelled
    case clientUnverified
    case unknown
}

@MainActor
struct CloudStoreKitTransaction {
    let productID: String
    let jwsRepresentation: String
    let purchaseDate: Date
    private let finish: () async -> Void

    init(productID: String, jwsRepresentation: String, purchaseDate: Date = .distantPast, finish: @escaping () async -> Void = {}) {
        self.productID = productID
        self.jwsRepresentation = jwsRepresentation
        self.purchaseDate = purchaseDate
        self.finish = finish
    }

    func finishTransaction() async {
        await finish()
    }
}

/// The aggregate result of scanning one passive StoreKit discovery surface:
/// verified transactions, which are deliverable, and a count of unverified
/// results, which are recorded for local diagnostics and never delivered.
@MainActor
struct CloudStoreKitScanOutcome {
    private(set) var verified: [CloudStoreKitTransaction]
    private(set) var unverifiedCount: Int

    init(verified: [CloudStoreKitTransaction] = [], unverifiedCount: Int = 0) {
        self.verified = verified
        self.unverifiedCount = unverifiedCount
    }

    mutating func record(_ result: VerificationResult<Transaction>) {
        switch result {
        case .verified(let transaction):
            verified.append(CloudStoreKitTransaction(
                productID: transaction.productID,
                jwsRepresentation: result.jwsRepresentation,
                purchaseDate: transaction.purchaseDate,
                finish: { await transaction.finish() }
            ))
        case .unverified:
            unverifiedCount += 1
        }
    }
}

/// One sighting on a long-lived StoreKit transaction stream.
enum CloudStoreKitStreamEvent {
    case verified(CloudStoreKitTransaction)
    case unverified
}

@MainActor
private struct SystemCloudStoreKitOperations: CloudStoreKitOperations {
    func products(for identifiers: Set<String>) async throws -> [Product] {
        try await Product.products(for: identifiers)
    }

    func purchase(productID: String, product: Product?, accountToken: UUID) async throws -> CloudStoreKitPurchaseResult {
        let selectedProduct: Product
        if let product {
            selectedProduct = product
        } else if let resolved = try await Product.products(for: [productID]).first(where: { $0.id == productID }) {
            selectedProduct = resolved
        } else {
            throw CloudStoreKitError.productUnavailable
        }
        switch try await selectedProduct.purchase(options: [.appAccountToken(accountToken)]) {
        case .success(let verification):
            guard case .verified(let transaction) = verification else { return .clientUnverified }
            return .success(CloudStoreKitTransaction(
                productID: transaction.productID,
                jwsRepresentation: verification.jwsRepresentation,
                purchaseDate: transaction.purchaseDate,
                finish: { await transaction.finish() }
            ))
        case .pending:
            return .pending
        case .userCancelled:
            return .userCancelled
        @unknown default:
            return .unknown
        }
    }

    func currentEntitlements() async -> CloudStoreKitScanOutcome {
        var outcome = CloudStoreKitScanOutcome()
        for await result in Transaction.currentEntitlements {
            outcome.record(result)
        }
        return outcome
    }

    /// `Transaction.latest(for:)` yields the most recent transaction per
    /// product even when it has expired - exactly the history shape current
    /// entitlements cannot surface.
    func latestTransactions() async -> CloudStoreKitScanOutcome {
        var outcome = CloudStoreKitScanOutcome()
        for productID in CloudProductID.ordered {
            if let result = await Transaction.latest(for: productID) {
                outcome.record(result)
            }
        }
        return outcome
    }

    /// `Transaction.all` is finite per Apple's documentation, and every entry
    /// is still an Apple-signed transaction the existing backend route can
    /// verify. Recovery filters it to the configured Cloud products.
    func transactionHistory() async -> CloudStoreKitScanOutcome {
        var outcome = CloudStoreKitScanOutcome()
        for await result in Transaction.all {
            outcome.record(result)
        }
        return outcome
    }

    /// Each subscription status carries its signed `transaction`. The renewal
    /// info is a different JWS type the backend route does not accept, so only
    /// the transaction field is recorded. Both Cloud products share one
    /// subscription group, so each group is queried once.
    func subscriptionStatusTransactions() async -> CloudStoreKitScanOutcome {
        var outcome = CloudStoreKitScanOutcome()
        guard let products = try? await Product.products(for: CloudProductID.ordered) else { return outcome }
        var queriedGroups: Set<String> = []
        for product in products {
            guard let groupID = product.subscription?.subscriptionGroupID, queriedGroups.insert(groupID).inserted else { continue }
            guard let statuses = try? await Product.SubscriptionInfo.status(for: groupID) else { continue }
            for status in statuses {
                outcome.record(status.transaction)
            }
        }
        return outcome
    }

    func unfinishedEvents() -> AsyncStream<CloudStoreKitStreamEvent> {
        Self.bridge { continuation in
            for await result in Transaction.unfinished {
                continuation.yield(Self.streamEvent(from: result))
            }
        }
    }

    func updateEvents() -> AsyncStream<CloudStoreKitStreamEvent> {
        Self.bridge { continuation in
            for await result in Transaction.updates {
                continuation.yield(Self.streamEvent(from: result))
            }
        }
    }

    func sync() async throws {
        try await AppStore.sync()
    }

    private static func streamEvent(from result: VerificationResult<Transaction>) -> CloudStoreKitStreamEvent {
        switch result {
        case .verified(let transaction):
            return .verified(CloudStoreKitTransaction(
                productID: transaction.productID,
                jwsRepresentation: result.jwsRepresentation,
                purchaseDate: transaction.purchaseDate,
                finish: { await transaction.finish() }
            ))
        case .unverified:
            return .unverified
        }
    }

    /// Bridges a StoreKit sequence into a stream whose consumer owns the
    /// lifetime: cancelling the consumer's task ends the stream, which cancels
    /// the bridge task instead of leaking a StoreKit listener.
    private static func bridge(_ iterate: @escaping (AsyncStream<CloudStoreKitStreamEvent>.Continuation) async -> Void) -> AsyncStream<CloudStoreKitStreamEvent> {
        AsyncStream { continuation in
            let task = Task { @MainActor in
                await iterate(continuation)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

enum CloudStoreKitError: Error {
    case productUnavailable
}

@MainActor
public final class CloudSubscriptionStore: ObservableObject {
    @Published public private(set) var products: [Product] = []
    @Published public private(set) var state: PurchaseAttemptState = .idle
    /// The last context the backend returned for a delivered transaction. This
    /// is the only value that may enable Cloud in the app.
    @Published public private(set) var lastVerifiedContext: CloudContext?
    /// Local aggregate recovery evidence: per-surface counts and outcome
    /// classes only. Safe to render on parent surfaces; never sent anywhere.
    @Published public private(set) var recoveryEvidence = CloudRecoveryEvidence()

    private let client: CloudAPIClient
    private let storeKit: any CloudStoreKitOperations
    private var recoveryTask: Task<Void, Never>?
    private var updatesTask: Task<Void, Never>?
    private var deliveriesInFlight: Set<String> = []
    private var deliveryWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var deliverySettlementWaiters: [CheckedContinuation<Void, Never>] = []
    private var completedDeliveries: Set<String> = []
    private var deliveryGeneration = 0
    private var availabilityCheckGeneration = 0
    var onTransactionUpdateDelivery: (() async -> Void)?

    /// The one bounded wait between an empty post-sync sweep and its single
    /// delayed rescan. Injectable so tests stay deterministic.
    var delayedRescanDelayNanoseconds: UInt64 = 30_000_000_000

    public init(client: CloudAPIClient, observeTransactions: Bool = true) {
        self.client = client
        self.storeKit = SystemCloudStoreKitOperations()
        guard observeTransactions else { return }
        startObservingIfAuthenticated()
    }

    init(client: CloudAPIClient, storeKit: any CloudStoreKitOperations, observeTransactions: Bool = true) {
        self.client = client
        self.storeKit = storeKit
        guard observeTransactions else { return }
        startObservingIfAuthenticated()
    }

    deinit {
        recoveryTask?.cancel()
        updatesTask?.cancel()
    }

    public func startObservingIfAuthenticated() {
        guard client.hasSession else { return }
        if recoveryTask == nil {
            recoveryTask = Task { [weak self] in await self?.observeRecoveryAndUnfinished() }
        }
        if updatesTask == nil {
            updatesTask = Task { [weak self] in await self?.observeTransactionUpdates() }
        }
    }

    /// Account deletion removes the service binding, so no signed transaction
    /// or projected entitlement from that account may remain in memory while
    /// the terminal confirmation is on screen.
    public func resetAfterAccountDeletion() {
        recoveryTask?.cancel()
        updatesTask?.cancel()
        recoveryTask = nil
        updatesTask = nil
        products = []
        state = .idle
        lastVerifiedContext = nil
        deliveriesInFlight.removeAll()
        let pendingDeliveryWaiters = deliveryWaiters.values.flatMap { $0 }
        deliveryWaiters.removeAll()
        for waiter in pendingDeliveryWaiters {
            waiter.resume()
        }
        let pendingSettlementWaiters = deliverySettlementWaiters
        deliverySettlementWaiters.removeAll()
        for waiter in pendingSettlementWaiters {
            waiter.resume()
        }
        completedDeliveries.removeAll()
        deliveryGeneration = 0
        availabilityCheckGeneration &+= 1
    }

    /// Products are usable only when both the backend capability and exactly
    /// the two StoreKit products are available. There is no price fallback.
    ///
    /// Each step records its outcome class in the local recovery evidence, so
    /// an unavailable card names the step that actually failed instead of
    /// collapsing a policy answer, an unreadable service, and a failed App
    /// Store query into one indistinguishable state. Only a deliberate
    /// service "no" is `.notOffered`; every failed or wrong answer is
    /// `.couldNotCheck`, because whether Cloud could be offered is unknown.
    public func loadProducts() async {
        availabilityCheckGeneration &+= 1
        let generation = availabilityCheckGeneration
        let capabilities: CloudCapabilities
        do {
            capabilities = try await client.capabilities()
        } catch {
            guard generation == availabilityCheckGeneration else { return }
            recoveryEvidence.recordCapabilityRead(.unreadable)
            products = []
            state = .productsUnavailable(.couldNotCheck)
            return
        }
        guard generation == availabilityCheckGeneration else { return }
        guard capabilities.canOfferCloud else {
            recoveryEvidence.recordCapabilityRead(.notPermitted)
            products = []
            state = .productsUnavailable(.notOffered)
            return
        }
        recoveryEvidence.recordCapabilityRead(.permitted)
        let loaded: [Product]
        do {
            loaded = try await storeKit.products(for: CloudProductID.all)
        } catch {
            guard generation == availabilityCheckGeneration else { return }
            recoveryEvidence.recordProductLoad(.networkFailure)
            products = []
            state = .productsUnavailable(.couldNotCheck)
            return
        }
        guard generation == availabilityCheckGeneration else { return }
        let outcome = Self.productLoadOutcome(forLoadedIDs: loaded.map(\.id))
        recoveryEvidence.recordProductLoad(outcome)
        guard outcome == .loaded else {
            products = []
            state = .productsUnavailable(.couldNotCheck)
            return
        }
        products = CloudProductID.ordered.compactMap { id in loaded.first { $0.id == id } }
        state = .idle
    }

    /// `.loaded` only when the store answered with exactly the two Cloud
    /// plans; anything else is classified, never partially accepted.
    static func productLoadOutcome(forLoadedIDs ids: [String]) -> CloudRecoveryEvidence.ProductLoadOutcome {
        if ids.isEmpty { return .storeReturnedNone }
        guard Set(ids) == CloudProductID.all, ids.count == 2 else { return .productSetMismatch }
        return .loaded
    }

    public func purchase(_ product: Product, accountToken: UUID) async {
        await purchase(productID: product.id, product: product, accountToken: accountToken)
    }

    func purchase(productID: String, accountToken: UUID) async {
        await purchase(productID: productID, product: nil, accountToken: accountToken)
    }

    private func purchase(productID: String, product: Product?, accountToken: UUID) async {
        guard CloudProductID.all.contains(productID) else { state = .productsUnavailable(.notOffered); return }
        state = .purchasing(productID: productID)
        do {
            switch try await storeKit.purchase(productID: productID, product: product, accountToken: accountToken) {
            case .success(let transaction):
                await deliver(transaction)
            case .pending:
                state = .pending
            case .userCancelled:
                state = .cancelled
            case .clientUnverified:
                state = .clientUnverified
            case .unknown:
                await handleStoreKitFailure()
            }
        } catch {
            await handleStoreKitFailure()
        }
    }

    /// Explicit parent action only. Normal launch/device replacement recovery
    /// uses passive surfaces and never prompts with AppStore.sync(). When the
    /// sync returns but the immediate sweep finds no usable Cloud transaction,
    /// exactly one bounded delayed rescan runs; only when both come back empty
    /// does the parent see the truthful App Store/client failure state.
    public func restorePurchases() async {
        let startingDeliveryGeneration = deliveryGeneration
        do {
            try await storeKit.sync()
        } catch {
            recoveryEvidence.recordSync(.threw)
            await handleStoreKitFailure()
            return
        }
        recoveryEvidence.recordSync(.returned)
        if await recoverWithDiscovery(phase: .immediate) { return }
        do {
            try await Task.sleep(nanoseconds: delayedRescanDelayNanoseconds)
        } catch {
            // Cancelled while waiting: nothing truthful to claim either way.
            return
        }
        guard !Task.isCancelled else { return }
        if await recoverWithDiscovery(phase: .delayed) { return }
        guard deliveryGeneration == startingDeliveryGeneration, deliveriesInFlight.isEmpty else {
            await waitForDeliverySettlement()
            return
        }
        state = .storeClientError
    }

    /// Passive recovery across every supported discovery surface. Never
    /// prompts; used at launch, on device replacement, and as the fallback
    /// when a StoreKit call throws or answers unexpectedly.
    @discardableResult
    public func recoverCurrentEntitlements() async -> Bool {
        await recoverWithDiscovery(phase: .passive)
    }

    /// One bounded passive sweep in documented fallback order: current
    /// entitlements, latest transaction per Cloud product, Cloud-filtered
    /// history, then subscription-status transactions. The newest verified
    /// Cloud transaction found is delivered through the existing backend route
    /// and ends the sweep, so one sweep issues at most one delivery. Repeated
    /// sightings of that same signed transaction across surfaces and sweeps
    /// coalesce inside `deliver`, so one logical recovery never issues
    /// duplicate concurrent deliveries. Unverified results are counted for the
    /// local evidence surface and never delivered.
    @discardableResult
    private func recoverWithDiscovery(phase: CloudRecoveryEvidence.ScanPhase) async -> Bool {
        guard client.hasSession else { return false }
        let scans: [(CloudRecoveryEvidence.Surface, () async -> CloudStoreKitScanOutcome)] = [
            (.currentEntitlements, { await self.storeKit.currentEntitlements() }),
            (.latestTransaction, { await self.storeKit.latestTransactions() }),
            (.transactionHistory, { await self.storeKit.transactionHistory() }),
            (.subscriptionStatus, { await self.storeKit.subscriptionStatusTransactions() }),
        ]
        for (surface, scan) in scans {
            if Task.isCancelled { return false }
            let outcome = await scan()
            let cloudTransactions = outcome.verified.filter { CloudProductID.all.contains($0.productID) }
            recoveryEvidence.recordScan(
                surface: surface,
                phase: phase,
                verifiedCloud: cloudTransactions.count,
                unverified: outcome.unverifiedCount
            )
            if let transaction = newestTransaction(in: cloudTransactions) {
                await deliver(transaction)
                return true
            }
        }
        return false
    }

    private func handleStoreKitFailure() async {
        let recovered = await recoverWithDiscovery(phase: .passive)
        if !recovered {
            state = .storeClientError
        }
    }

    /// Initial finite recovery followed by the unfinished backlog, kept
    /// separate from the updates listener so a never-terminating unfinished
    /// sequence can never block update delivery.
    private func observeRecoveryAndUnfinished() async {
        await recoverWithDiscovery(phase: .passive)
        for await event in storeKit.unfinishedEvents() {
            switch event {
            case .verified(let transaction):
                guard CloudProductID.all.contains(transaction.productID) else { continue }
                recoveryEvidence.recordStreamSighting(surface: .unfinished, verified: true)
                await deliver(transaction)
            case .unverified:
                recoveryEvidence.recordStreamSighting(surface: .unfinished, verified: false)
            }
        }
    }

    /// Apple's documented infinite launch listener, subscribed in its own
    /// long-lived task.
    private func observeTransactionUpdates() async {
        for await event in storeKit.updateEvents() {
            switch event {
            case .verified(let transaction):
                guard CloudProductID.all.contains(transaction.productID) else { continue }
                recoveryEvidence.recordStreamSighting(surface: .transactionUpdates, verified: true)
                await deliver(transaction)
                await onTransactionUpdateDelivery?()
            case .unverified:
                recoveryEvidence.recordStreamSighting(surface: .transactionUpdates, verified: false)
            }
        }
    }

    private func newestTransaction(in transactions: [CloudStoreKitTransaction]) -> CloudStoreKitTransaction? {
        transactions.max { lhs, rhs in
            if lhs.purchaseDate != rhs.purchaseDate { return lhs.purchaseDate < rhs.purchaseDate }
            if lhs.productID != rhs.productID { return lhs.productID < rhs.productID }
            return lhs.jwsRepresentation < rhs.jwsRepresentation
        }
    }

    private func deliver(_ transaction: CloudStoreKitTransaction) async {
        let jws = transaction.jwsRepresentation
        guard !completedDeliveries.contains(jws) else { return }
        if deliveriesInFlight.contains(jws) {
            await withCheckedContinuation { continuation in
                deliveryWaiters[jws, default: []].append(continuation)
            }
            return
        }
        deliveriesInFlight.insert(jws)
        deliveryGeneration &+= 1
        state = .serverVerifying
        do {
            let context = try await client.deliver(transactionJWS: jws)
            completedDeliveries.insert(jws)
            lastVerifiedContext = context
            switch context.entitlementState {
            case .active, .billingGrace:
                // Delivery means the backend projected an entitlement that
                // grants Cloud. Only now may the transaction be finished.
                state = .verifiedPaid
                recoveryEvidence.recordDelivery(.active)
                await transaction.finishTransaction()
            case .verificationPending, .none:
                // A 2xx that carries no grant is not a grant. Keep the
                // transaction unfinished so a later launch retries delivery.
                state = .serverPending
                recoveryEvidence.recordDelivery(.pending)
            case .expired, .refunded, .revoked, .billingRetry:
                // The backend verified the transaction and projected its real
                // non-granting state. Render that truthfully, never as a
                // server rejection.
                state = .entitlementNotActive(context.entitlementState)
                recoveryEvidence.recordDelivery(.inactive)
            }
        } catch let error as WalletAPIError {
            switch error.operationError {
            case .server(let status, _, _) where status == 202:
                completedDeliveries.insert(jws)
                // Accepted but not yet verified: pending, never finished.
                state = .serverPending
                recoveryEvidence.recordDelivery(.pending)
            case .server(let status, _, _) where (400..<500).contains(status):
                completedDeliveries.insert(jws)
                state = .serverRejected(correlationID: nil)
                recoveryEvidence.recordDelivery(.rejected)
            case .unauthorized, .noSession:
                state = .serverRejected(correlationID: nil)
                recoveryEvidence.recordDelivery(.rejected)
            default:
                // Network, timeout, or an unreadable response: unknown outcome,
                // so never grant and never finish the transaction.
                state = .serverPending
                recoveryEvidence.recordDelivery(.network)
            }
        } catch {
            state = .serverPending
            recoveryEvidence.recordDelivery(.network)
        }
        deliveryGeneration &+= 1
        deliveriesInFlight.remove(jws)
        let waiters = deliveryWaiters.removeValue(forKey: jws) ?? []
        for waiter in waiters {
            waiter.resume()
        }
        if deliveriesInFlight.isEmpty {
            let settlementWaiters = deliverySettlementWaiters
            deliverySettlementWaiters.removeAll()
            for waiter in settlementWaiters {
                waiter.resume()
            }
        }
    }

    private func waitForDeliverySettlement() async {
        guard !deliveriesInFlight.isEmpty else { return }
        await withCheckedContinuation { continuation in
            deliverySettlementWaiters.append(continuation)
        }
    }
}

extension CloudPlan {
    /// StoreKit owns the displayed price and period. Nothing here is hard-coded.
    init(_ product: Product) {
        let period: String = {
            guard let subscription = product.subscription else { return "" }
            return switch subscription.subscriptionPeriod.unit {
            case .month: subscription.subscriptionPeriod.value == 1 ? "every month" : "every \(subscription.subscriptionPeriod.value) months"
            case .year: subscription.subscriptionPeriod.value == 1 ? "every year" : "every \(subscription.subscriptionPeriod.value) years"
            case .week: "every week"
            case .day: "every day"
            @unknown default: ""
            }
        }()
        self.init(
            id: product.id,
            displayName: product.displayName,
            displayPrice: product.displayPrice,
            periodDescription: period
        )
    }
}
