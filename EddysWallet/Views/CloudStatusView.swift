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

    /// Guideline 3.1.2 requires the purchase surface itself to link both
    /// documents next to the subscription offer. The privacy policy is this
    /// project's own published page; the terms of use is Apple's Standard
    /// EULA, which governs an auto-renewable subscription that ships no
    /// custom EULA of its own.
    static let termsOfUseURL = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!
    static let privacyPolicyURL = URL(string: "https://eddies-wallet.kunchenguid.com/")!

    /// The remaining factual half of the Guideline 3.1.2 disclosure - title,
    /// length, and price already appear on each plan row above.
    static let autoRenewDisclosure = "Subscriptions renew automatically unless canceled at least 24 hours before the end of the current period. Manage or cancel anytime in Settings > Apple ID > Subscriptions."

    private var isCloudOn: Bool { store.cloudEntitlement.grantsCloud }

    private var hasCloudWalletOnDevice: Bool {
        store.authorityState.isCloudAuthority || store.hasValidCloudReplica
    }

    private var headerPresentation: (subtitle: String, symbol: String) {
        if isCloudOn {
            return ("On for this family", "checkmark.icloud.fill")
        }
        if hasCloudWalletOnDevice {
            switch store.cloudEntitlement {
            case .verificationPending:
                return ("Confirming this family's Cloud plan", "exclamationmark.icloud.fill")
            case .none:
                return ("Cloud plan status unavailable", "exclamationmark.icloud.fill")
            case .billingRetry, .expired, .refunded, .revoked:
                return ("Paused - Cloud plan not active", "exclamationmark.icloud.fill")
            case .active, .billingGrace:
                break
            }
        }
        return ("An optional extra", "icloud.fill")
    }

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
            // The green line is gated on the same evidence a protected write
            // needs, so it can never appear beside a blocked money control.
            // Reading only "an active plan, Cloud authority, and some stored
            // replica" as "syncing" is what let 0.1.14 claim this device was in
            // sync while every parent action was disabled behind a block.
            if isCloudOn, store.isSyncedWithCloud {
                Label("This \(DeviceCopy.deviceNoun) is syncing with Cloud.", systemImage: "checkmark.circle.fill")
                    .font(EW.Font.caption)
                    .foregroundStyle(EW.Color.green700)
                    .accessibilityIdentifier("cloud-syncing-note")
            } else if store.authorityState.isCloudAuthority, let block = store.parentMutationBlock {
                Label(Self.notSyncedNote(block, deviceNoun: DeviceCopy.deviceNoun), systemImage: "exclamationmark.circle.fill")
                    .font(EW.Font.caption)
                    .foregroundStyle(EW.Color.gold700)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("cloud-not-syncing-note")
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
                headerPresentation.symbol,
                foreground: EW.Color.green700,
                background: EW.Color.green100,
                size: 44
            )
            VStack(alignment: .leading, spacing: 2) {
                Text("Cloud backup & sync")
                    .font(EW.Font.headingSmall)
                    .foregroundStyle(EW.Color.textPrimary)
                Text(headerPresentation.subtitle)
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
                        Self.plansUnavailableNoteCopy(for: store.purchaseAttempt, deviceNoun: DeviceCopy.deviceNoun),
                        systemImage: Self.plansUnavailableNoteSymbol(for: store.purchaseAttempt)
                    )
                        .font(EW.Font.caption)
                        .foregroundStyle(EW.Color.gold700)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("cloud-plans-unavailable-note")
                    if Self.showsPlansRetryControl(for: store.purchaseAttempt) {
                        Button("Check again") {
                            guard !isWorking else { return }
                            isWorking = true
                            Task {
                                await store.loadCloudPlans()
                                isWorking = false
                            }
                        }
                        .buttonStyle(SecondaryButtonStyle(compact: true))
                        .disabled(isWorking)
                        .accessibilityIdentifier("cloud-plans-retry-button")
                    }
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

    /// The unavailable note must never present a deliberate service answer as
    /// a passing outage or a failed check as a settled "no": a stable policy
    /// state reads as "isn't available for this account", while a failed check
    /// reads as "couldn't be checked". States that never ran the check - a
    /// scripted state without a Cloud session, or a check not attempted yet -
    /// keep the original neutral wording.
    static func plansUnavailableNoteCopy(for attempt: PurchaseAttemptState, deviceNoun: String) -> String {
        switch attempt {
        case .productsUnavailable(.notOffered):
            "Cloud isn't available for this account yet. Everything in the wallet keeps working on this \(deviceNoun)."
        case .productsUnavailable(.couldNotCheck):
            "Cloud plans couldn't be checked right now. Everything in the wallet keeps working on this \(deviceNoun)."
        default:
            "Cloud isn't available yet. Everything in the wallet keeps working on this \(deviceNoun)."
        }
    }

    static func plansUnavailableNoteSymbol(for attempt: PurchaseAttemptState) -> String {
        if case .productsUnavailable(.couldNotCheck) = attempt { return "exclamationmark.icloud" }
        return "clock"
    }

    /// A definite unavailable answer earns a retry: capabilities are re-read
    /// on demand, so checking again is truthful for both the policy and the
    /// failed-check state. States that never ran a real check offer no retry,
    /// because there is nothing for the control to re-run.
    static func showsPlansRetryControl(for attempt: PurchaseAttemptState) -> Bool {
        if case .productsUnavailable = attempt { return true }
        return false
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
            Divider().overlay(EW.Color.border)
                .padding(.top, EW.Space.one)
            Text(Self.autoRenewDisclosure)
                .font(EW.Font.caption)
                .foregroundStyle(EW.Color.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("cloud-auto-renew-disclosure")
            HStack(spacing: EW.Space.five) {
                Link("Terms of Use", destination: Self.termsOfUseURL)
                    .accessibilityIdentifier("cloud-terms-link")
                Link("Privacy Policy", destination: Self.privacyPolicyURL)
                    .accessibilityIdentifier("cloud-privacy-link")
            }
            .font(EW.Font.caption)
            .foregroundStyle(EW.Color.primaryActive)
            .frame(minHeight: 44, alignment: .leading)
        }
    }

    /// The Cloud card states the current sync fact only. What to do about it,
    /// and the control that does it, belong on the block itself in the Parent
    /// actions section, so a parent is never sent hunting between cards.
    private static func notSyncedNote(_ block: ParentMutationBlock, deviceNoun: String) -> String {
        switch block {
        case .rejectedCleanup:
            "This \(deviceNoun) has local cleanup to finish before it syncs again."
        case .unsettledMutation:
            "This \(deviceNoun) is waiting for Cloud to confirm its last change."
        case .replicaUnavailable:
            "This \(deviceNoun) does not have the Cloud wallet yet."
        case .planInactive:
            "This \(deviceNoun) is not syncing: the Cloud plan is not active."
        case .awaitingReview:
            "This wallet changed somewhere else and is waiting to be reviewed."
        case .authorityUnreached:
            "This \(deviceNoun) has not reached Cloud."
        case .revisionUnconfirmed:
            "This \(deviceNoun) has not confirmed the latest Cloud wallet yet."
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
