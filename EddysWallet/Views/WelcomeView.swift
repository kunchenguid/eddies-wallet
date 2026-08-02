import SwiftUI

struct WelcomeView: View {
    @EnvironmentObject private var store: WalletStore

    var body: some View {
        ZStack {
            EW.Color.appBackground.ignoresSafeArea()
            ScrollView {
                VStack(spacing: EW.Space.seven) {
                    Spacer(minLength: EW.Space.ten)
                    VStack(spacing: EW.Space.four) {
                        Image("WalletMark")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 104, height: 104)
                            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                            .shadow(color: EW.Color.ink900.opacity(0.10), radius: 10, y: 4)
                        Text(ProductBrand.displayName)
                            .font(EW.Font.displayLarge)
                            .foregroundStyle(EW.Color.textPrimary)
                            .accessibilityIdentifier("product-brand-wordmark")
                        Text("Set up a complete practice wallet on this iPhone or iPad for free. Cloud is optional.")
                            .font(EW.Font.body)
                            .foregroundStyle(EW.Color.textSecondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 340)
                    }

                    VStack(alignment: .leading, spacing: EW.Space.three) {
                        Label("Virtual practice only", systemImage: "shield.checkered")
                            .font(EW.Font.headingSmall)
                            .foregroundStyle(EW.Color.textPrimary)
                        Text("These dollars are pretend, cannot be redeemed, and never move real money.")
                            .font(EW.Font.body)
                            .foregroundStyle(EW.Color.textSecondary)
                    }
                    .frame(maxWidth: 440, alignment: .leading)
                    .ewCard(variant: .alt)

                    VStack(spacing: EW.Space.three) {
                        Button {
                            Task { await store.signInWithApple() }
                        } label: {
                            if store.isSigningIn {
                                ProgressView()
                                    .tint(.white)
                                    .frame(maxWidth: .infinity, minHeight: 52)
                            } else {
                                Label("Set up your child's wallet", systemImage: "apple.logo")
                            }
                        }
                        .buttonStyle(AppleSignInButtonStyle())
                        .disabled(store.isSigningIn)
                        .accessibilityHint("Parent sign-in only. Your child does not need an account.")

                        if let errorMessage = store.errorMessage {
                            Text(errorMessage)
                                .font(EW.Font.caption)
                                .foregroundStyle(EW.Color.red600)
                                .multilineTextAlignment(.center)
                        }

                        Text("Parent sign-in only. Your child does not need an account.")
                            .font(EW.Font.caption)
                            .foregroundStyle(EW.Color.textTertiary)
                            .multilineTextAlignment(.center)

                        Text("Signing in also checks whether your Apple account already has a wallet, so you can bring it here instead of starting over.")
                            .font(EW.Font.caption)
                            .foregroundStyle(EW.Color.textTertiary)
                            .multilineTextAlignment(.center)
                            .accessibilityIdentifier("welcome-existing-wallet-note")
                    }
                    .frame(maxWidth: 440)
                    Spacer(minLength: EW.Space.seven)
                }
                .padding(.horizontal, EW.Space.screenMargin)
                .frame(maxWidth: 700)
                .frame(maxWidth: .infinity)
            }
        }
    }
}

struct WalletRecoveryView: View {
    @EnvironmentObject private var store: WalletStore

    var body: some View {
        ZStack {
            EW.Color.appBackground.ignoresSafeArea()
            VStack(spacing: EW.Space.seven) {
                Spacer()
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 54, weight: .semibold))
                    .foregroundStyle(EW.Color.primaryActive)
                    .frame(width: 96, height: 96)
                    .background(EW.Color.primaryTint, in: RoundedRectangle(cornerRadius: EW.Radius.large, style: .continuous))

                VStack(spacing: EW.Space.three) {
                    Text("Your wallet needs a parent")
                        .font(EW.Font.display)
                        .foregroundStyle(EW.Color.textPrimary)
                        .multilineTextAlignment(.center)
                    Text(message)
                        .font(EW.Font.body)
                        .foregroundStyle(EW.Color.textSecondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: 420)

                Label("No wallet data was replaced.", systemImage: "lock.shield")
                    .font(EW.Font.headingSmall)
                    .foregroundStyle(EW.Color.textPrimary)
                    .frame(maxWidth: 440, alignment: .leading)
                    .ewCard(variant: .alt)
                Spacer()
            }
            .padding(.horizontal, EW.Space.screenMargin)
            .padding(.vertical, EW.Space.seven)
        }
        .accessibilityElement(children: .contain)
    }

    private var message: String {
        switch store.recoveryState {
        case .historyUnavailable:
            "This device cannot safely read the wallet history right now. Ask a parent for help."
        case .storageUnavailable:
            "This device cannot open its protected wallet storage right now. Ask a parent to try again later."
        case nil:
            "This device cannot safely open the wallet right now. Ask a parent for help."
        }
    }
}

#Preview("Welcome") {
    WelcomeView()
        .environmentObject(WalletStore())
}
