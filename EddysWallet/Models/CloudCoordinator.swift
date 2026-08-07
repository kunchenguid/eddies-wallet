import Foundation
import StoreKit

/// Guarded Cloud vertical slice: capability, plans, purchase delivery,
/// activation upload, replica bootstrap, and authority hand-offs.
///
/// Nothing here grants Cloud. A verified backend entitlement may activate the
/// local household, while a verified Cloud household may be adopted on another
/// device. The free local wallet keeps working whenever either path fails.
@MainActor
public final class CloudCoordinator: ObservableObject, AccountDeletionPerforming {
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
    private var sessionGeneration = 0
    var onTransactionUpdate: (() async -> Void)?

    public init(client: CloudAPIClient, subscriptions: CloudSubscriptionStore? = nil) {
        self.client = client
        self.subscriptions = subscriptions ?? CloudSubscriptionStore(client: client)
        self.subscriptions.onTransactionUpdateDelivery = { [weak self] in
            await self?.adoptTransactionUpdate()
        }
    }

    /// Purchase and restore controls may only appear when this is true.
    public var canOfferPlans: Bool { availability == .ready && plans.count == 2 }
    public var isCloudActive: Bool { entitlement.grantsCloud }
    public var hasSession: Bool { client.hasSession }
    public var permitsLocalContinuation: Bool { entitlement.permitsLocalContinuation }
    /// Owns StoreKit recovery and its local, privacy-safe evidence surface.
    public var subscriptionStore: CloudSubscriptionStore { subscriptions }

    public func authenticateCloud(identity: AppleIdentity) async throws {
        _ = try await client.authenticateApple(
            identityToken: identity.identityToken,
            nonce: identity.signedNonce
        )
        subscriptions.startObservingIfAuthenticated()
    }

    /// Reconciles an existing StoreKit entitlement immediately after a fresh
    /// Apple sign-in, before first-run household discovery. This is how a
    /// returning parent who deleted their account while an Apple subscription
    /// remained active re-binds that signed transaction to the new account
    /// without attempting a second purchase.
    public func reconcileExistingEntitlementsForFreshSignIn() async {
        await recoverEntitlements()
    }

    public func deleteAccount(idempotencyKey: String) async throws -> AccountDeletionResult {
        try await client.deleteAccount(idempotencyKey: idempotencyKey)
    }

    public func preflightAccountDeletion() async throws {
        let context = try await client.context()
        apply(context)
    }

    public func clearAuthenticationForAccountDeletion() throws {
        sessionGeneration += 1
        try client.clearLocalSessionForAccountDeletion()
    }

    /// Drops every in-memory StoreKit/session projection that can describe the
    /// deleted account. The device-local wallet replica is erased separately by
    /// `WalletStore` before the service deletion request.
    public func resetAfterAccountDeletion() {
        sessionGeneration += 1
        client.clearLocalSession()
        storeAccountToken = nil
        plans = []
        availability = .unknown
        purchaseAttempt = .idle
        entitlement = .none
        household = nil
        activationConflict = false
        message = nil
        subscriptions.resetAfterAccountDeletion()
    }

    // MARK: - First-run discovery

    /// Asks, for the exact signed-in parent only, whether a server-held wallet
    /// already exists. This reads; it never transitions, adopts, or mutates
    /// anything, and an unreadable answer is an error rather than a guess.
    public func discoverExistingWallet() async throws -> CloudExistingWalletDiscovery {
        guard client.hasSession else { throw WalletAPIError.noSession }
        let context = try await client.legacyContext()
        return context.discovery
    }

    /// The accepted transition, as one logical user action. The revision comes
    /// from discovery and the key from that single acceptance, so a retry of
    /// the same acceptance converges on the one household instead of forking.
    public func recoverLegacyHousehold(
        _ offer: CloudExistingWalletOffer,
        idempotencyKey: String,
        into local: LocalWalletRepository
    ) async throws -> CloudWalletRepository {
        guard client.hasSession else { throw WalletAPIError.noSession }
        let transitioned = try await client.activateLegacyHousehold(
            revision: offer.revision,
            idempotencyKey: idempotencyKey
        )
        guard transitioned.isCloudAuthoritative else {
            throw CloudLegacyActivationError(
                refusal: .unreachable,
                underlying: .invalidResponse("Cloud did not confirm this wallet. Nothing was changed.")
            )
        }
        guard transitioned.lineageID == offer.lineageID else {
            throw CloudLegacyActivationError(
                refusal: .revisionChanged(currentRevision: transitioned.revision),
                underlying: .invalidResponse("Cloud confirmed a different wallet history. Nothing was changed.")
            )
        }
        household = transitioned
        guard let adopted = await adoptCloudHousehold(transitioned, into: local) else {
            throw CloudLegacyActivationError(
                refusal: .unreachable,
                underlying: .invalidResponse("Cloud did not confirm this wallet. Nothing was changed.")
            )
        }
        return adopted
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
        let generation = sessionGeneration
        do {
            let context = try await client.context()
            guard generation == sessionGeneration, client.hasSession else { return nil }
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
    /// bounded passive StoreKit discovery surfaces plus the server projection.
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
        try? local.markCloudImportAccepted(lineageID: lineageID, revision: household.revision)
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
        guard client.hasSession, let household else { return nil }
        return await adoptCloudHousehold(household, into: local)
    }

    /// The one place a confirmed Cloud household becomes this device's
    /// authority: mark the replica, then bootstrap the complete wallet. A
    /// failed bootstrap keeps Cloud authority - the server already owns the
    /// household - and says so instead of showing a wallet this device has not
    /// read yet.
    private func adoptCloudHousehold(
        _ household: CloudHousehold,
        into local: LocalWalletRepository
    ) async -> CloudWalletRepository? {
        guard household.isCloudAuthoritative, let lineageID = household.lineageID else { return nil }
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
        clearLocalSession()
    }

    public func clearLocalSession() {
        sessionGeneration += 1
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

    private func adoptTransactionUpdate() async {
        purchaseAttempt = subscriptions.state
        if let context = subscriptions.lastVerifiedContext { apply(context) }
        await onTransactionUpdate?()
    }
}
