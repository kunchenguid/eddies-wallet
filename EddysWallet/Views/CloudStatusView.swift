import SwiftUI

/// Parent-only Cloud surface. Prices and purchase controls appear only when the
/// backend reports Cloud is available and StoreKit returns exactly the two real
/// products; there is no hard-coded price and no scripted success path.
struct CloudStatusView: View {
    @EnvironmentObject private var store: WalletStore
    @State private var isWorking = false

    var body: some View {
        VStack(alignment: .leading, spacing: EW.Space.three) {
            Label("Cloud backup & sync", systemImage: "icloud")
                .font(EW.Font.headingSmall)
                .foregroundStyle(EW.Color.textPrimary)
            statusCopy
            purchaseStateCopy
            if store.needsCloudSignIn {
                Button("Sign in to check Cloud plans") {
                    guard !isWorking else { return }
                    isWorking = true
                    Task {
                        await store.signInToCloud()
                        isWorking = false
                    }
                }
                .buttonStyle(.plain)
                .font(EW.Font.body)
                .foregroundStyle(EW.Color.primaryActive)
                .disabled(isWorking)
                .accessibilityIdentifier("cloud-sign-in-button")
            }
            if store.canOfferCloudPlans, !store.cloudEntitlement.grantsCloud {
                plans
            }
            if store.needsCloudReview {
                reviewNotice
            }
            if store.cloudEntitlement.grantsCloud, store.authorityState.isCloudAuthority, store.hasValidCloudReplica {
                Text("This \(DeviceCopy.deviceNoun) is syncing with Cloud.")
                    .font(EW.Font.caption)
                    .foregroundStyle(EW.Color.textTertiary)
                    .accessibilityIdentifier("cloud-syncing-note")
            }
            if store.canContinueLocallyAfterCloud {
                Button("Keep using this \(DeviceCopy.deviceNoun)") {
                    Task { await store.continueLocallyAfterCloud() }
                }
                    .buttonStyle(.plain)
                    .font(EW.Font.body)
                    .foregroundStyle(EW.Color.primaryActive)
                    .accessibilityIdentifier("cloud-continue-local-button")
            }
            if let message = store.cloudMessage {
                Text(message)
                    .font(EW.Font.caption)
                    .foregroundStyle(EW.Color.gold700)
                    .accessibilityIdentifier("cloud-message")
            }
            Text(optionalCloudCopy)
                .font(EW.Font.caption)
                .foregroundStyle(EW.Color.textTertiary)
            #if DEBUG
            NavigationLink("StoreKit diagnostics") { CloudDiagnosticsView() }
                .font(EW.Font.caption)
                .accessibilityIdentifier("cloud-storekit-diagnostics-link")
            #endif
            // Local-only aggregate recovery outcomes, safe to show in every
            // build including Release. Nothing sensitive can appear on it.
            NavigationLink("Cloud recovery details") {
                CloudRecoveryEvidenceView(subscriptions: store.cloudSubscriptionStore)
            }
                .font(EW.Font.caption)
                .accessibilityIdentifier("cloud-recovery-details-link")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .ewCard(variant: .alt)
        // A container identifier alone would override every child identifier,
        // so the card stays a container and its rows keep their own identifiers.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("cloud-backup-sync-card")
        .task { await store.loadCloudPlans() }
    }

    @ViewBuilder private var statusCopy: some View {
        if store.authorityState.isCloudAuthority, !store.hasValidCloudReplica {
            Text(Self.cloudReplicaUnavailableStatusCopy(deviceNoun: DeviceCopy.deviceNoun))
                .font(EW.Font.body)
                .foregroundStyle(EW.Color.textSecondary)
        } else {
            switch store.cloudEntitlement {
            case .active(let accessUntil, _):
                Text("Cloud is on through \(accessUntil.formatted(date: .abbreviated, time: .omitted)). Backed up and synced across devices using the same parent Apple account.")
                    .font(EW.Font.body)
                    .foregroundStyle(EW.Color.textSecondary)
            case .billingGrace:
                Text("Cloud is still on while the App Store retries billing.")
                    .font(EW.Font.body)
                    .foregroundStyle(EW.Color.textSecondary)
            case .expired, .refunded, .revoked, .billingRetry:
                Text("Cloud ended. You can keep using the wallet on this device. Nothing was deleted.")
                    .font(EW.Font.body)
                    .foregroundStyle(EW.Color.textSecondary)
            case .verificationPending:
                Text("Your Cloud plan is being confirmed. Nothing changed on this \(DeviceCopy.deviceNoun) yet.")
                    .font(EW.Font.body)
                    .foregroundStyle(EW.Color.textSecondary)
            case .none:
                Text(Self.noEntitlementStatusCopy(authority: store.authorityState, deviceNoun: DeviceCopy.deviceNoun))
                    .font(EW.Font.body)
                    .foregroundStyle(EW.Color.textSecondary)
                if !store.canOfferCloudPlans, !store.needsCloudSignIn {
                    Text("Cloud plans are unavailable right now. Your wallet still works on this device.")
                        .font(EW.Font.caption)
                        .foregroundStyle(EW.Color.gold700)
                        .accessibilityIdentifier("cloud-plans-unavailable-note")
                }
            }
        }
    }

    private var optionalCloudCopy: String {
        if store.authorityState.isCloudAuthority, !store.hasValidCloudReplica {
            return "After this device syncs once, its last accepted Cloud wallet stays readable offline."
        }
        return "Cloud is optional. Your wallet keeps working on this device without it."
    }

    static func cloudReplicaUnavailableStatusCopy(deviceNoun: String) -> String {
        "Cloud owns this wallet. Reconnect before this \(deviceNoun) can show the Cloud wallet."
    }

    static func noEntitlementStatusCopy(authority: WalletAuthorityState, deviceNoun: String) -> String {
        if authority.isCloudAuthority {
            return "This \(deviceNoun) is showing the last synced Cloud wallet. Reconnect to check its current status."
        }
        return "This wallet is saved only on this \(deviceNoun). Cloud adds backup and sync on devices using the same parent Apple account."
    }

    /// The backend verified the delivered transaction and projected its real
    /// non-granting state, so the copy names that state instead of claiming a
    /// rejection.
    static func entitlementNotActiveCopy(for entitlement: CloudEntitlementState) -> String {
        switch entitlement {
        case .expired:
            "This Cloud plan has expired, so Cloud stays off. Your wallet is unchanged."
        case .refunded:
            "This Cloud plan was refunded, so Cloud stays off. Your wallet is unchanged."
        case .revoked:
            "The App Store revoked this Cloud plan, so Cloud stays off. Your wallet is unchanged."
        case .billingRetry:
            "The App Store is still trying to bill this Cloud plan. Cloud stays off for now, and your wallet is unchanged."
        default:
            "This Cloud plan is not active, so Cloud stays off. Your wallet is unchanged."
        }
    }

    @ViewBuilder private var purchaseStateCopy: some View {
        switch store.purchaseAttempt {
        case .pending:
            purchaseNote("This plan needs approval before Cloud can turn on. Nothing changed yet.", identifier: "cloud-purchase-pending")
        case .serverVerifying, .serverPending:
            purchaseNote("Confirming your plan with our service. Nothing changed on this \(DeviceCopy.deviceNoun) yet.", identifier: "cloud-purchase-verifying")
        case .serverRejected:
            purchaseNote("That plan could not be confirmed, so Cloud is still off. Your wallet is unchanged.", identifier: "cloud-purchase-rejected")
        case .clientUnverified:
            purchaseNote("The App Store could not verify that purchase, so Cloud stays off.", identifier: "cloud-purchase-unverified")
        case .storeClientError:
            purchaseNote("The App Store could not finish confirming that purchase. Cloud is still off, and your wallet is unchanged.", identifier: "cloud-purchase-store-error")
        case .entitlementNotActive(let entitlement):
            purchaseNote(Self.entitlementNotActiveCopy(for: entitlement), identifier: "cloud-purchase-not-active")
        case .cancelled:
            purchaseNote("Purchase cancelled. Nothing changed.", identifier: "cloud-purchase-cancelled")
        case .activationConflict:
            purchaseNote("This wallet could not be moved to Cloud. Nothing was changed on this \(DeviceCopy.deviceNoun).", identifier: "cloud-activation-conflict")
        case .idle, .productsUnavailable, .purchasing, .verifiedPaid:
            EmptyView()
        }
    }

    private var plans: some View {
        VStack(alignment: .leading, spacing: EW.Space.two) {
            ForEach(store.cloudPlans) { plan in
                Button {
                    guard !isWorking else { return }
                    isWorking = true
                    Task {
                        await store.purchaseCloud(planID: plan.id)
                        isWorking = false
                    }
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(plan.displayName)
                                .font(EW.Font.body)
                                .foregroundStyle(EW.Color.textPrimary)
                            Text("\(plan.displayPrice) \(plan.periodDescription)")
                                .font(EW.Font.caption)
                                .foregroundStyle(EW.Color.textSecondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(EW.Color.textTertiary)
                    }
                }
                .buttonStyle(.plain)
                .disabled(isWorking)
                .accessibilityIdentifier("cloud-plan-\(plan.id)")
            }
            Button("Restore purchase") {
                guard !isWorking else { return }
                isWorking = true
                Task {
                    await store.restoreCloudPurchases()
                    isWorking = false
                }
            }
            .buttonStyle(.plain)
            .font(EW.Font.caption)
            .foregroundStyle(EW.Color.primaryActive)
            .disabled(isWorking)
            .accessibilityIdentifier("cloud-restore-button")
        }
    }

    private var reviewNotice: some View {
        VStack(alignment: .leading, spacing: EW.Space.one) {
            Text("This wallet changed on another device. Review the latest balance, then record the action again.")
                .font(EW.Font.caption)
                .foregroundStyle(EW.Color.gold700)
            Button("Got it") { store.acknowledgeCloudReview() }
                .buttonStyle(.plain)
                .font(EW.Font.caption)
                .foregroundStyle(EW.Color.primaryActive)
        }
        .accessibilityIdentifier("cloud-review-notice")
    }

    private func purchaseNote(_ text: String, identifier: String) -> some View {
        Text(text)
            .font(EW.Font.caption)
            .foregroundStyle(EW.Color.textSecondary)
            .accessibilityIdentifier(identifier)
    }
}
