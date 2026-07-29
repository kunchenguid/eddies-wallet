import Foundation
import StoreKit

@MainActor
public final class CloudSubscriptionStore: ObservableObject {
    @Published public private(set) var products: [Product] = []
    @Published public private(set) var state: PurchaseAttemptState = .idle
    /// The last context the backend returned for a delivered transaction. This
    /// is the only value that may enable Cloud in the app.
    @Published public private(set) var lastVerifiedContext: CloudContext?

    private let client: CloudAPIClient
    private var updateTask: Task<Void, Never>?

    public init(client: CloudAPIClient, observeTransactions: Bool = true) {
        self.client = client
        guard observeTransactions else { return }
        updateTask = Task { [weak self] in await self?.observeTransactionUpdates() }
    }

    deinit { updateTask?.cancel() }

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
        guard CloudProductID.all.contains(product.id) else { state = .productsUnavailable; return }
        state = .purchasing(productID: product.id)
        do {
            switch try await product.purchase(options: [.appAccountToken(accountToken)]) {
            case .success(let verification):
                guard case .verified(let transaction) = verification else { state = .clientUnverified; return }
                await deliver(transaction, jws: verification.jwsRepresentation)
            case .pending:
                state = .pending
            case .userCancelled:
                state = .cancelled
            @unknown default:
                state = .serverRejected(correlationID: nil)
            }
        } catch {
            state = .serverRejected(correlationID: nil)
        }
    }

    /// Explicit parent action only. Normal launch/device replacement recovery
    /// uses currentEntitlements and never prompts with AppStore.sync().
    public func restorePurchases() async {
        do {
            try await AppStore.sync()
            await recoverCurrentEntitlements()
        } catch {
            state = .serverRejected(correlationID: nil)
        }
    }

    public func recoverCurrentEntitlements() async {
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result, CloudProductID.all.contains(transaction.productID) else { continue }
            await deliver(transaction, jws: result.jwsRepresentation)
        }
    }

    private func observeTransactionUpdates() async {
        await recoverCurrentEntitlements()
        // Retry delivery left unfinished by a prior interrupted launch before
        // subscribing to the long-lived update stream.
        for await result in Transaction.unfinished {
            guard case .verified(let transaction) = result, CloudProductID.all.contains(transaction.productID) else { continue }
            await deliver(transaction, jws: result.jwsRepresentation)
        }
        for await result in Transaction.updates {
            guard case .verified(let transaction) = result, CloudProductID.all.contains(transaction.productID) else { continue }
            await deliver(transaction, jws: result.jwsRepresentation)
        }
    }

    private func deliver(_ transaction: Transaction, jws: String) async {
        state = .serverVerifying
        do {
            let context = try await client.deliver(transactionJWS: jws)
            lastVerifiedContext = context
            switch context.entitlementState {
            case .active, .billingGrace:
                // Delivery means the backend enabled the Cloud household. Only
                // now may the StoreKit transaction be finished.
                state = .verifiedPaid
                await transaction.finish()
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
                // Accepted but not yet verified: pending, never finished.
                state = .serverPending
            case .server(let status, _, _) where (400..<500).contains(status):
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
