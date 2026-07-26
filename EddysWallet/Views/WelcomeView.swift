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
                        Text("Eddie's Wallet")
                            .font(EW.Font.displayLarge)
                            .foregroundStyle(EW.Color.textPrimary)
                        Text("A pretend wallet for practicing allowance, spending, and borrowing.")
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
                            // This is deliberately a local integration point. Real AuthenticationServices wiring is future scope.
                            store.signInWithAppleIntegrationPoint()
                        } label: {
                            Label("Sign in with Apple", systemImage: "apple.logo")
                        }
                        .buttonStyle(AppleSignInButtonStyle())
                        .accessibilityHint("Parent sign-in integration point")

                        Text("Parent sign-in only. Eddie does not need an account.")
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

private struct AppleSignInButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(EW.Font.bodyBold)
            .foregroundStyle(Color.white)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(Color.black, in: RoundedRectangle(cornerRadius: EW.Radius.medium, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

#Preview("Welcome") {
    WelcomeView()
        .environmentObject(WalletStore())
}
