import Foundation
import StoreKit

/// Guarded Cloud vertical slice: capability, plans, purchase delivery,
/// activation upload, replica bootstrap, and authority hand-offs.
///
/// Nothing here grants Cloud. The backend's projected entitlement in a verified
/// `CloudContext` is the only value that can move this device to Cloud
/// authority, and the free local wallet keeps working whenever any of it fails.
@MainActor
public final class CloudCoordinator: ObservableObject {
    public enum Availability: Equatable, Sendable {
        /// Not asked yet, or the answer could not be read.
        case unknown
        /// The backend is reachable but Cloud cannot be activated from here.
        case unavailable
        /// Backend capability and exactly the two StoreKit products are ready.
        case ready
    }

    @Published public private(set) var availability: Availability = .unknown
    @Published public private(set) var plans: [Product] = []
    @Published public private(set) var purchaseAttempt: PurchaseAttemptState = .idle
    @Published public private(set) var entitlement: CloudEntitlementState = .none
    @Published public private(set) var household: CloudHousehold?
    @Published public private(set) var activationConflict = false
    @Published public private(set) var message: String?

    private let client: CloudAPIClient
    private let subscriptions: CloudSubscriptionStore
    private var storeAccountToken: UUID?

    public init(client: CloudAPIClient, subscriptions: CloudSubscriptionStore? = nil) {
        self.client = client
        self.subscriptions = subscriptions ?? CloudSubscriptionStore(client: client)
    }

    /// Purchase and restore controls may only appear when this is true.
    public var canOfferPlans: Bool { availability == .ready && plans.count == 2 }
    public var isCloudActive: Bool { entitlement.grantsCloud }
    public var hasSession: Bool { client.hasSession }
    public var permitsLocalContinuation: Bool { entitlement.permitsLocalContinuation }

    public func authenticateCloud(identity: AppleIdentity) async throws {
        _ = try await client.authenticateApple(
            identityToken: identity.identityToken,
            nonce: identity.signedNonce
        )
        subscriptions.startObservingIfAuthenticated()
    }

    // MARK: - Capability and plans

    public func refreshAvailability() async {
        guard client.hasSession else {
            plans = []
            availability = .unknown
            purchaseAttempt = .idle
            return
        }
        await subscriptions.loadProducts()
        plans = subscriptions.products
        purchaseAttempt = subscriptions.state
        availability = plans.count == 2 ? .ready : .unavailable
        if client.hasSession { await refreshContext() }
    }

    @discardableResult
    public func refreshContext() async -> CloudContext? {
        guard client.hasSession else { return nil }
        do {
            let context = try await client.context()
            apply(context)
            return context
        } catch {
            // An unreadable or unreachable context never changes entitlement.
            return nil
        }
    }

    // MARK: - Purchase and restore

    public func purchase(_ product: Product) async -> CloudEntitlementState {
        guard client.hasSession, canOfferPlans else { purchaseAttempt = .productsUnavailable; return entitlement }
        let refreshedToken = storeAccountToken == nil ? await refreshContext()?.storeAccountToken : storeAccountToken
        guard let accountToken = refreshedToken else {
            purchaseAttempt = .serverRejected(correlationID: nil)
            message = "Cloud could not be set up right now. Your wallet still works on this device."
            return entitlement
        }
        await subscriptions.purchase(product, accountToken: accountToken)
        purchaseAttempt = subscriptions.state
        if let context = subscriptions.lastVerifiedContext { apply(context) }
        return entitlement
    }

    public func restorePurchases() async {
        guard client.hasSession else { purchaseAttempt = .serverRejected(correlationID: nil); return }
        await subscriptions.restorePurchases()
        purchaseAttempt = subscriptions.state
        if let context = subscriptions.lastVerifiedContext { apply(context) }
        await refreshContext()
    }

    /// Launch and device-replacement recovery: no purchase prompt, only the
    /// current entitlements plus the server's projection.
    public func recoverEntitlements() async {
        guard client.hasSession else { purchaseAttempt = .serverRejected(correlationID: nil); return }
        await subscriptions.recoverCurrentEntitlements()
        purchaseAttempt = subscriptions.state
        if let context = subscriptions.lastVerifiedContext { apply(context) }
        await refreshContext()
    }

    // MARK: - Activation

    /// First device: upload the complete local household once, then mirror the
    /// accepted Cloud replica. Returns the Cloud repository when the household
    /// became Cloud-authoritative.
    public func activateCloud(from local: LocalWalletRepository, familyName: String) async throws -> CloudWalletRepository {
        guard client.hasSession else { throw WalletAPIError.noSession }
        guard isCloudActive else { throw WalletAPIError.cloudEntitlementRequired }
        activationConflict = false
        let operationID = try local.reserveCloudImportOperation()
        let manifest = try local.cloudImportManifest(familyName: familyName, operationID: operationID)
        let household: CloudHousehold
        do {
            household = try await client.importHousehold(manifest, idempotencyKey: "cloud-import-\(operationID.uuidString.lowercased())")
        } catch WalletAPIError.server(let status, let code, let message) where status == 409 {
            // Another household already owns this parent, or this lineage was
            // already imported under different facts. Never overwrite either.
            activationConflict = true
            self.message = "This wallet could not be moved to Cloud. Nothing was changed."
            throw WalletAPIError.server(statusCode: status, code: code, message: message)
        }
        guard household.isCloudAuthoritative, let lineageID = household.lineageID else {
            throw WalletAPIError.invalidResponse("Cloud did not confirm this wallet. Nothing was changed.")
        }
        guard lineageID == local.lineageID else {
            throw WalletAPIError.invalidResponse("Cloud confirmed a different wallet history. Nothing was changed.")
        }
        self.household = household
        let repository = CloudWalletRepository(client: client, replica: local, lineageID: lineageID, revision: household.revision)
        try? local.markCloudAuthorityConfirmed(lineageID: lineageID, revision: household.revision)
        do {
            _ = try await repository.bootstrap()
        } catch {
            message = repository.hasValidReplica
                ? "Cloud owns this wallet. This device is showing its last saved copy and will catch up when it reconnects."
                : "Cloud owns this wallet. Reconnect before this device can show the Cloud wallet."
        }
        return repository
    }

    /// Second device for the same parent: no upload, only a complete bootstrap
    /// of the household the server already owns.
    public func adoptExistingCloudHousehold(into local: LocalWalletRepository) async throws -> CloudWalletRepository? {
        guard client.hasSession else { throw WalletAPIError.noSession }
        _ = await refreshContext()
        guard let household, household.isCloudAuthoritative,
              let lineageID = household.lineageID else { return nil }
        let repository = CloudWalletRepository(
            client: client,
            replica: local,
            lineageID: lineageID,
            revision: household.revision,
            requiresBootstrap: true
        )
        try? local.markCloudAuthorityConfirmed(lineageID: lineageID, revision: household.revision)
        do {
            _ = try await repository.bootstrap()
        } catch {
            message = repository.hasValidReplica
                ? "Cloud owns this wallet. This device is showing its last saved copy and will catch up when it reconnects."
                : "Cloud owns this wallet. Reconnect before this device can show the Cloud wallet."
        }
        return repository
    }

    // MARK: - Hand-offs

    /// Cloud ended and the parent chose to keep using this device. Nothing is
    /// deleted; the mirrored history becomes local authority again.
    public func continueLocally(with local: LocalWalletRepository) throws {
        guard permitsLocalContinuation else {
            throw WalletAPIError.invalidResponse("Cloud status is unavailable, so this wallet must stay in Cloud mode.")
        }
        try local.continueLocallyAfterCloud()
        household = nil
    }

    public func signOutOfCloud() async {
        try? await client.revokeCurrentSession()
        client.clearLocalSession()
        household = nil
        purchaseAttempt = .idle
    }

    // MARK: - Private

    private func apply(_ context: CloudContext) {
        storeAccountToken = context.storeAccountToken ?? storeAccountToken
        entitlement = context.entitlementState
        // A malformed or non-Cloud household never becomes Cloud authority.
        household = context.household?.isCloudAuthoritative == true ? context.household : nil
    }
}
