import SwiftUI

/// The one deliberate first-run choice a parent sees when their Apple account
/// already holds a wallet. It sits between sign-in and setup, states plainly
/// what will and will not change, and always leaves the free local path open.
/// Declining sends nothing at all.
struct ExistingWalletView: View {
    @EnvironmentObject private var store: WalletStore

    var body: some View {
        ZStack {
            EW.Color.appBackground.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: EW.Space.six) {
                    header
                    promises
                    if let refusalMessage = store.existingWalletRecovery?.refusalMessage {
                        refusal(refusalMessage)
                    }
                    actions
                    Text("Your wallet stays on your Apple account either way. Nothing is deleted by this choice.")
                        .font(EW.Font.caption)
                        .foregroundStyle(EW.Color.textTertiary)
                }
                .padding(EW.Space.screenMargin)
                .frame(maxWidth: 620)
                .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .accessibilityIdentifier("existing-wallet-screen")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: EW.Space.three) {
            IconBadge("arrow.down.circle", foreground: EW.Color.green700, background: EW.Color.primaryTint, size: 56)
            VStack(alignment: .leading, spacing: EW.Space.two) {
                Text("Use the wallet you already have")
                    .font(EW.Font.display)
                    .foregroundStyle(EW.Color.textPrimary)
                    .accessibilityIdentifier("existing-wallet-title")
                Text("Your Apple account already has a child's wallet. You can bring it to this \(DeviceCopy.deviceNoun) instead of starting a new one.")
                    .font(EW.Font.body)
                    .foregroundStyle(EW.Color.textSecondary)
            }
        }
    }

    private var promises: some View {
        VStack(alignment: .leading, spacing: EW.Space.three) {
            promise("checkmark.circle", "Nothing is lost", "The child profile, balance, activity, loans, repayments, and allowance all come back exactly as they are.")
            promise("icloud", "It moves to Cloud", cloudDetail)
            promise("hand.raised", "Only you can do this", "This wallet is only offered to the Apple account that owns it, and only when you choose it here.")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .ewCard()
    }

    /// Never claims an active subscription the service has just told this
    /// device it does not have.
    private var cloudDetail: String {
        store.existingWalletRecovery?.offer.entitlementActive == false
            ? "Cloud keeps this wallet in sync across your devices, and moving it needs an active Cloud subscription."
            : "Your active Cloud subscription keeps this wallet in sync across your devices from now on."
    }

    private func promise(_ systemImage: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: EW.Space.three) {
            Image(systemName: systemImage)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(EW.Color.green700)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: EW.Space.one) {
                Text(title)
                    .font(EW.Font.headingSmall)
                    .foregroundStyle(EW.Color.textPrimary)
                Text(detail)
                    .font(EW.Font.caption)
                    .foregroundStyle(EW.Color.textSecondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func refusal(_ message: String) -> some View {
        HStack(alignment: .top, spacing: EW.Space.three) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(EW.Color.red600)
                .accessibilityHidden(true)
            Text(message)
                .font(EW.Font.body)
                .foregroundStyle(EW.Color.textPrimary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(EW.Space.four)
        .background(EW.Color.dangerTint, in: RoundedRectangle(cornerRadius: EW.Radius.medium, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("existing-wallet-refusal")
    }

    @ViewBuilder
    private var actions: some View {
        VStack(spacing: EW.Space.three) {
            if isWorking {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .accessibilityIdentifier("existing-wallet-working")
                    .accessibilityLabel("Bringing your wallet to this \(DeviceCopy.deviceNoun)")
            } else if isRefused {
                if store.existingWalletRecovery?.canRetry == true {
                    Button("Try again") {
                        Task { await store.retryExistingWalletRecovery() }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .accessibilityIdentifier("existing-wallet-retry-button")
                }
            } else {
                Button("Use this wallet") {
                    Task { await store.acceptExistingWallet() }
                }
                .buttonStyle(PrimaryButtonStyle())
                .accessibilityIdentifier("existing-wallet-accept-button")
            }
            declineAction
        }
    }

    /// When a refusal leaves no way to ask again, setting up here is the only
    /// way forward and is styled as the action it has become.
    @ViewBuilder
    private var declineAction: some View {
        if isRefused, store.existingWalletRecovery?.canRetry != true {
            Button("Set up a new wallet instead") {
                store.declineExistingWallet()
            }
            .buttonStyle(PrimaryButtonStyle())
            .accessibilityIdentifier("existing-wallet-decline-button")
        } else {
            Button("Set up a new wallet instead") {
                store.declineExistingWallet()
            }
            .buttonStyle(SecondaryButtonStyle())
            .disabled(isWorking)
            .opacity(isWorking ? 0.45 : 1)
            .accessibilityIdentifier("existing-wallet-decline-button")
        }
    }

    /// The transition itself, and the re-check a stale acceptance runs first.
    private var isWorking: Bool { store.existingWalletRecovery?.isWorking == true || store.isSigningIn }
    private var isRefused: Bool { store.existingWalletRecovery?.refusalMessage != nil }
}

#if DEBUG
#Preview("Existing wallet offered") {
    let store = WalletStore.preview()
    store.applyDebugExistingWalletRecovery(.offered(CloudExistingWalletOffer(
        lineageID: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!,
        revision: 0,
        entitlementActive: true
    )))
    return ExistingWalletView().environmentObject(store)
}
#endif
