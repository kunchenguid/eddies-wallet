import SwiftUI

/// Parent-only Cloud surface, written for a parent rather than an operator: it
/// says what Cloud does for the family, what is true on this device right now,
/// and nothing else. Internal diagnostics are not reachable from here in a
/// shipped build. Prices and purchase controls appear only when the backend
/// reports Cloud is available and StoreKit returns exactly the two real
/// products; there is no hard-coded price and no scripted success path.
struct CloudStatusView: View {
    @EnvironmentObject private var store: WalletStore
    @State private var isWorking = false

    private var isCloudOn: Bool { store.cloudEntitlement.grantsCloud }

    /// Only a family that has no Cloud at all is told what Cloud would add. A
    /// device that already keeps a Cloud wallet needs its state, not a pitch.
    private var showsCloudBenefits: Bool {
        !isCloudOn && !store.authorityState.isCloudAuthority
    }

    var body: some View {
        VStack(alignment: .leading, spacing: EW.Space.four) {
            header
            statusCopy
            purchaseStateCopy
            if showsCloudBenefits {
                whatCloudAdds
            }
            if store.needsCloudSignIn {
                Button("Sign in to see Cloud plans") {
                    guard !isWorking else { return }
                    isWorking = true
                    Task {
                        await store.signInToCloud()
                        isWorking = false
                    }
                }
                .buttonStyle(SecondaryButtonStyle(compact: true))
                .disabled(isWorking)
                .accessibilityIdentifier("cloud-sign-in-button")
            }
            if store.canOfferCloudPlans, !isCloudOn {
                plans
            }
            if store.needsCloudReview {
                reviewNotice
            }
            if isCloudOn, store.authorityState.isCloudAuthority, store.hasValidCloudReplica {
                Label("This \(DeviceCopy.deviceNoun) is syncing with Cloud.", systemImage: "checkmark.circle.fill")
                    .font(EW.Font.caption)
                    .foregroundStyle(EW.Color.green700)
                    .accessibilityIdentifier("cloud-syncing-note")
            }
            if store.canContinueLocallyAfterCloud {
                Button("Keep using this \(DeviceCopy.deviceNoun)") {
                    Task { await store.continueLocallyAfterCloud() }
                }
                    .buttonStyle(SecondaryButtonStyle(compact: true))
                    .accessibilityIdentifier("cloud-continue-local-button")
            }
            if let message = store.cloudMessage {
                Text(message)
                    .font(EW.Font.caption)
                    .foregroundStyle(EW.Color.gold700)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("cloud-message")
            }
            Text(optionalCloudCopy)
                .font(EW.Font.caption)
                .foregroundStyle(EW.Color.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            #if DEBUG
            // Internal-only surfaces. A shipped build compiles neither this
            // seam nor the screens behind it, so no one outside a Debug run
            // launched with `EW_UITEST_DIAGNOSTICS=1` can reach diagnostics.
            if DebugLaunchScenario.showsDiagnosticsEntryPoints() {
                NavigationLink("StoreKit diagnostics") { CloudDiagnosticsView() }
                    .font(EW.Font.caption)
                    .accessibilityIdentifier("cloud-storekit-diagnostics-link")
                NavigationLink("Cloud recovery details") {
                    CloudRecoveryEvidenceView(subscriptions: store.cloudSubscriptionStore)
                }
                    .font(EW.Font.caption)
                    .accessibilityIdentifier("cloud-recovery-details-link")
            }
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

    private var header: some View {
        HStack(spacing: EW.Space.three) {
            IconBadge(
                isCloudOn ? "checkmark.icloud.fill" : "icloud.fill",
                foreground: EW.Color.green700,
                background: EW.Color.green100,
                size: 44
            )
            VStack(alignment: .leading, spacing: 2) {
                Text("Cloud backup & sync")
                    .font(EW.Font.headingSmall)
                    .foregroundStyle(EW.Color.textPrimary)
                Text(isCloudOn ? "On for this family" : "An optional extra")
                    .font(EW.Font.caption)
                    .foregroundStyle(EW.Color.textTertiary)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    /// Plain-language benefits, phrased as what Cloud would add rather than as
    /// anything this device already has.
    private var whatCloudAdds: some View {
        VStack(alignment: .leading, spacing: EW.Space.three) {
            benefit("lock.icloud.fill", "A safe copy of the wallet, so a lost \(DeviceCopy.deviceNoun) doesn't lose the savings history")
            benefit("ipad.and.iphone", "The same wallet on your family's other devices, signed in with your parent Apple account")
            benefit("arrow.triangle.2.circlepath", "New \(DeviceCopy.deviceNoun)? Pick up exactly where you left off")
        }
        .padding(EW.Space.four)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(EW.Color.cream50, in: RoundedRectangle(cornerRadius: EW.Radius.medium, style: .continuous))
        .accessibilityIdentifier("cloud-benefits")
    }

    private func benefit(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: EW.Space.three) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(EW.Color.green600)
                .frame(width: 22, alignment: .center)
                .accessibilityHidden(true)
            Text(text)
                .font(EW.Font.body)
                .foregroundStyle(EW.Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private var statusCopy: some View {
        if store.authorityState.isCloudAuthority, !store.hasValidCloudReplica {
            statusText(Self.cloudReplicaUnavailableStatusCopy(deviceNoun: DeviceCopy.deviceNoun))
        } else {
            switch store.cloudEntitlement {
            case .active(let accessUntil, _):
                statusText("Cloud is on through \(accessUntil.formatted(date: .abbreviated, time: .omitted)). Backed up and synced across devices using the same parent Apple account.")
            case .billingGrace:
                statusText("Cloud is still on while the App Store retries billing.")
            case .expired, .refunded, .revoked, .billingRetry:
                statusText("Cloud ended. You can keep using the wallet on this device. Nothing was deleted.")
            case .verificationPending:
                statusText("Your Cloud plan is being confirmed. Nothing changed on this \(DeviceCopy.deviceNoun) yet.")
            case .none:
                statusText(Self.noEntitlementStatusCopy(authority: store.authorityState, deviceNoun: DeviceCopy.deviceNoun))
                if !store.canOfferCloudPlans, !store.needsCloudSignIn {
                    Label(
                        "Cloud isn't available yet. Everything in the wallet keeps working on this \(DeviceCopy.deviceNoun).",
                        systemImage: "clock"
                    )
                        .font(EW.Font.caption)
                        .foregroundStyle(EW.Color.gold700)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("cloud-plans-unavailable-note")
                }
            }
        }
    }

    private func statusText(_ text: String) -> some View {
        Text(text)
            .font(EW.Font.body)
            .foregroundStyle(EW.Color.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
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
        return "Right now this wallet is saved only on this \(deviceNoun)."
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
                    HStack(spacing: EW.Space.three) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(plan.displayName)
                                .font(EW.Font.bodyBold)
                                .foregroundStyle(EW.Color.textPrimary)
                            Text("\(plan.displayPrice) \(plan.periodDescription)")
                                .font(EW.Font.caption)
                                .foregroundStyle(EW.Color.textSecondary)
                        }
                        Spacer(minLength: EW.Space.three)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(EW.Color.textTertiary)
                    }
                    .padding(.horizontal, EW.Space.four)
                    .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
                    .background(EW.Color.card, in: RoundedRectangle(cornerRadius: EW.Radius.medium, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: EW.Radius.medium, style: .continuous)
                            .stroke(EW.Color.border, lineWidth: 1)
                    }
                }
                .buttonStyle(.plain)
                .disabled(isWorking)
                .accessibilityIdentifier("cloud-plan-\(plan.id)")
            }
            Button("Already subscribed? Restore purchase") {
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
            .frame(minHeight: 44)
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
