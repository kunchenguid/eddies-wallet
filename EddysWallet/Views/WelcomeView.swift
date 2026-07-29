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

#Preview("Welcome") {
    WelcomeView()
        .environmentObject(WalletStore())
}
