import Foundation
import StoreKit

@MainActor
protocol CloudStoreKitOperations {
    func purchase(productID: String, product: Product?, accountToken: UUID) async throws -> CloudStoreKitPurchaseResult
    func currentEntitlements() async -> [CloudStoreKitTransaction]
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
    private let finish: () async -> Void

    init(productID: String, jwsRepresentation: String, finish: @escaping () async -> Void = {}) {
        self.productID = productID
        self.jwsRepresentation = jwsRepresentation
        self.finish = finish
    }

    func finishTransaction() async {
        await finish()
    }
}

@MainActor
private struct SystemCloudStoreKitOperations: CloudStoreKitOperations {
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

    func currentEntitlements() async -> [CloudStoreKitTransaction] {
        var entitlements: [CloudStoreKitTransaction] = []
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result else { continue }
            entitlements.append(CloudStoreKitTransaction(
                productID: transaction.productID,
                jwsRepresentation: result.jwsRepresentation,
                finish: { await transaction.finish() }
            ))
        }
        return entitlements
    }

    func sync() async throws {
        try await AppStore.sync()
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

    private let client: CloudAPIClient
    private let storeKit: any CloudStoreKitOperations
    private var updateTask: Task<Void, Never>?
    private var deliveriesInFlight: Set<String> = []
    private var completedDeliveries: Set<String> = []

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

    deinit { updateTask?.cancel() }

    public func startObservingIfAuthenticated() {
        guard client.hasSession, updateTask == nil else { return }
        updateTask = Task { [weak self] in await self?.observeTransactionUpdates() }
    }

    /// Products are usable only when both the backend capability and exactly
    /// the two StoreKit products are available. There is no price fallback.
    public func loadProducts() async {
        do {
            let capabilities = try await client.capabilities()
            guard capabilities.canOfferCloud else {
                products = []; state = .productsUnavailable; return
            }
            let loaded = try await Product.products(for: CloudProductID.all)
            guard Set(loaded.map(\.id)) == CloudProductID.all, loaded.count == 2 else {
                products = []; state = .productsUnavailable; return
            }
            products = CloudProductID.ordered.compactMap { id in loaded.first { $0.id == id } }
            state = .idle
        } catch {
            products = []
            state = .productsUnavailable
        }
    }

    public func purchase(_ product: Product, accountToken: UUID) async {
        await purchase(productID: product.id, product: product, accountToken: accountToken)
    }

    func purchase(productID: String, accountToken: UUID) async {
        await purchase(productID: productID, product: nil, accountToken: accountToken)
    }

    private func purchase(productID: String, product: Product?, accountToken: UUID) async {
        guard CloudProductID.all.contains(productID) else { state = .productsUnavailable; return }
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
    /// uses currentEntitlements and never prompts with AppStore.sync().
    public func restorePurchases() async {
        do {
            try await storeKit.sync()
            await recoverCurrentEntitlements()
        } catch {
            await handleStoreKitFailure()
        }
    }

    @discardableResult
    public func recoverCurrentEntitlements() async -> Bool {
        guard client.hasSession else { return false }
        var recovered = false
        for transaction in await storeKit.currentEntitlements() {
            guard CloudProductID.all.contains(transaction.productID) else { continue }
            recovered = true
            await deliver(transaction)
        }
        return recovered
    }

    private func handleStoreKitFailure() async {
        let recovered = await recoverCurrentEntitlements()
        if !recovered {
            state = .storeClientError
        }
    }

    private func observeTransactionUpdates() async {
        await recoverCurrentEntitlements()
        // Retry delivery left unfinished by a prior interrupted launch before
        // subscribing to the long-lived update stream.
        for await result in Transaction.unfinished {
            guard let transaction = verifiedStoreKitTransaction(from: result), CloudProductID.all.contains(transaction.productID) else { continue }
            await deliver(transaction)
        }
        for await result in Transaction.updates {
            guard let transaction = verifiedStoreKitTransaction(from: result), CloudProductID.all.contains(transaction.productID) else { continue }
            await deliver(transaction)
        }
    }

    private func verifiedStoreKitTransaction(from result: VerificationResult<Transaction>) -> CloudStoreKitTransaction? {
        guard case .verified(let transaction) = result else { return nil }
        return CloudStoreKitTransaction(
            productID: transaction.productID,
            jwsRepresentation: result.jwsRepresentation,
            finish: { await transaction.finish() }
        )
    }

    private func deliver(_ transaction: CloudStoreKitTransaction) async {
        let jws = transaction.jwsRepresentation
        guard !deliveriesInFlight.contains(jws), !completedDeliveries.contains(jws) else { return }
        deliveriesInFlight.insert(jws)
        defer { deliveriesInFlight.remove(jws) }
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
                await transaction.finishTransaction()
            case .verificationPending:
                state = .serverPending
            case .none:
                // A 2xx that carries no entitlement is not a grant. Keep the
                // transaction unfinished so a later launch retries delivery.
                state = .serverPending
            case .expired, .refunded, .revoked, .billingRetry:
                state = .serverRejected(correlationID: nil)
            }
        } catch let error as WalletAPIError {
            switch error {
            case .server(let status, _, _) where status == 202:
                completedDeliveries.insert(jws)
                // Accepted but not yet verified: pending, never finished.
                state = .serverPending
            case .server(let status, _, _) where (400..<500).contains(status):
                completedDeliveries.insert(jws)
                state = .serverRejected(correlationID: nil)
            case .unauthorized, .noSession:
                state = .serverRejected(correlationID: nil)
            default:
                // Network, timeout, or an unreadable response: unknown outcome,
                // so never grant and never finish the transaction.
                state = .serverPending
            }
        } catch {
            state = .serverPending
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
