import Foundation
import StoreKit

@MainActor
public final class CloudSubscriptionStore: ObservableObject {
    @Published public private(set) var products: [Product] = []
    @Published public private(set) var state: PurchaseAttemptState = .idle

    private let client: CloudAPIClient
    private var updateTask: Task<Void, Never>?

    public init(client: CloudAPIClient) {
        self.client = client
        updateTask = Task { [weak self] in await self?.observeTransactions() }
    }

    deinit { updateTask?.cancel() }

    /// Products are usable only when both the backend capability and exactly
    /// the two StoreKit products are available. There is no price fallback.
    public func loadProducts() async {
        do {
            let capabilities = try await client.capabilities()
            guard capabilities.cloudActivationAvailable, capabilities.hasExactProducts else {
                products = []; state = .productsUnavailable; return
            }
            let loaded = try await Product.products(for: CloudProductID.all)
            guard Set(loaded.map(\.id)) == CloudProductID.all, loaded.count == 2 else {
                products = []; state = .productsUnavailable; return
            }
            products = loaded.sorted { $0.id < $1.id }
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

    private func observeTransactions() async {
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
            switch context.entitlement.clientState {
            case .active, .billingGrace:
                // Delivery means the backend enabled the Cloud household. Only
                // now may the StoreKit transaction be finished.
                state = .verifiedPaid
                await transaction.finish()
            case .verificationPending:
                state = .serverPending
            default:
                state = .serverRejected(correlationID: nil)
            }
        } catch let error as WalletAPIError {
            if case .server(let status, _, _) = error, status == 202 { state = .serverPending }
            else { state = .serverRejected(correlationID: nil) }
        } catch {
            state = .serverPending
        }
    }
}
