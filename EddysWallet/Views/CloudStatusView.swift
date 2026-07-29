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
            if store.cloudEntitlement.grantsCloud, store.authorityState.isCloudAuthority {
                Text("This \(DeviceCopy.deviceNoun) is syncing with Cloud.")
                    .font(EW.Font.caption)
                    .foregroundStyle(EW.Color.textTertiary)
                    .accessibilityIdentifier("cloud-syncing-note")
            }
            if store.canContinueLocallyAfterCloud {
                Button("Keep using this \(DeviceCopy.deviceNoun)") { store.continueLocallyAfterCloud() }
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
            Text("Cloud is optional. Your wallet keeps working on this device without it.")
                .font(EW.Font.caption)
                .foregroundStyle(EW.Color.textTertiary)
            #if DEBUG
            NavigationLink("StoreKit diagnostics") { CloudDiagnosticsView() }
                .font(EW.Font.caption)
                .accessibilityIdentifier("cloud-storekit-diagnostics-link")
            #endif
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
            Text("This wallet is saved only on this \(DeviceCopy.deviceNoun). Cloud adds backup and sync on devices using the same parent Apple account.")
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
