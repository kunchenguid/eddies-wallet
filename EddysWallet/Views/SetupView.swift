import SwiftUI

struct SetupView: View {
    static let initialNickname = ""

    @EnvironmentObject private var store: WalletStore
    @State private var nickname = SetupView.initialNickname
    @State private var pin = ""
    @State private var confirmationPIN = ""
    @State private var isConfirmingSignOut = false

    var body: some View {
        ZStack {
            EW.Color.appBackground.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: EW.Space.six) {
                    VStack(alignment: .leading, spacing: EW.Space.two) {
                        Text("Set up your child's wallet")
                            .font(EW.Font.display)
                            .foregroundStyle(EW.Color.textPrimary)
                        Text("Create one parent-managed child profile. No child login or Apple identity is needed.")
                            .font(EW.Font.body)
                            .foregroundStyle(EW.Color.textSecondary)
                    }

                    if let notice = store.existingWalletNotice {
                        existingWalletNotice(notice)
                    }

                    VStack(alignment: .leading, spacing: EW.Space.four) {
                        field(title: "Child nickname", text: $nickname, placeholder: "Child's nickname")
                        VStack(alignment: .leading, spacing: EW.Space.two) {
                            Text("Parent PIN")
                                .font(EW.Font.captionUpper)
                                .foregroundStyle(EW.Color.textTertiary)
                            Text("This four-digit PIN protects the Parent area on this \(DeviceCopy.deviceNoun).")
                                .font(EW.Font.caption)
                                .foregroundStyle(EW.Color.textSecondary)
                            SecureField("Four digits", text: $pin)
                                .keyboardType(.numberPad)
                                .textFieldStyle(.roundedBorder)
                                .onChange(of: pin) { _, value in pin = String(value.filter(\.isNumber).prefix(4)) }
                            SecureField("Confirm PIN", text: $confirmationPIN)
                                .keyboardType(.numberPad)
                                .textFieldStyle(.roundedBorder)
                                .onChange(of: confirmationPIN) { _, value in confirmationPIN = String(value.filter(\.isNumber).prefix(4)) }
                        }
                    }
                    .ewCard()

                    Text("This saves a complete practice wallet on this \(DeviceCopy.deviceNoun). Cloud is optional and can be considered later in the Parent area.")
                        .font(EW.Font.caption)
                        .foregroundStyle(EW.Color.textTertiary)

                    if let errorMessage = store.errorMessage {
                        Text(errorMessage)
                            .font(EW.Font.caption)
                            .foregroundStyle(EW.Color.red600)
                    }

                    Button {
                        Task {
                            let setup = ParentSetup(
                                nickname: nickname.trimmingCharacters(in: .whitespacesAndNewlines)
                            )
                            _ = await store.setupParent(setup, pin: pin, confirmation: confirmationPIN)
                        }
                    } label: {
                        if store.isLoading {
                            ProgressView()
                                .frame(maxWidth: .infinity, minHeight: 52)
                        } else {
                            Text("Keep it on this device for free")
                                .frame(maxWidth: .infinity, minHeight: 52)
                        }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(store.isLoading || store.isSigningIn || nickname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || pin.count != 4 || pin != confirmationPIN)
                    .opacity(store.isLoading || store.isSigningIn || nickname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || pin.count != 4 || pin != confirmationPIN ? 0.45 : 1)

                    Button("Sign out") { isConfirmingSignOut = true }
                        .buttonStyle(SecondaryButtonStyle(compact: true))
                        .confirmationDialog(
                            "Sign out before setup?",
                            isPresented: $isConfirmingSignOut,
                            titleVisibility: .visible
                        ) {
                            Button("Sign out", role: .destructive) { store.signOut() }
                            Button("Keep setting up", role: .cancel) {}
                        } message: {
                            Text("This removes the new parent sign-in from this \(DeviceCopy.deviceNoun). No family wallet has been created yet.")
                        }
                }
                .padding(EW.Space.screenMargin)
                .frame(maxWidth: 620)
                .frame(maxWidth: .infinity, alignment: .center)
            }
        }
    }

    /// Truthful account-check status: this device either could not check for a
    /// wallet already on the account, or found one it cannot move yet. Neither
    /// blocks the free local wallet, and both can be checked again.
    private func existingWalletNotice(_ notice: ExistingWalletNotice) -> some View {
        VStack(alignment: .leading, spacing: EW.Space.three) {
            HStack(alignment: .top, spacing: EW.Space.three) {
                Image(systemName: "icloud.slash")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(EW.Color.gold700)
                    .accessibilityHidden(true)
                Text(notice.message)
                    .font(EW.Font.body)
                    .foregroundStyle(EW.Color.textPrimary)
            }
            .accessibilityElement(children: .combine)
            if store.isSigningIn {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            } else {
                // A filled secondary button here would sit cream-on-cream in
                // this card, so the inline action uses the same text treatment
                // as the other Cloud inline actions, at a full touch target.
                Button("Check again") {
                    Task { await store.checkForExistingWallet() }
                }
                .buttonStyle(.plain)
                .font(EW.Font.bodyBold)
                .foregroundStyle(EW.Color.primaryActive)
                .frame(minHeight: 44, alignment: .leading)
                .accessibilityIdentifier("existing-wallet-check-again-button")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .ewCard(variant: .alt)
        // A container identifier here would override the Check again button's
        // own identifier, so the card stays a plain container.
        .accessibilityElement(children: .contain)
    }

    private func field(title: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: EW.Space.two) {
            Text(title)
                .font(EW.Font.captionUpper)
                .foregroundStyle(EW.Color.textTertiary)
            TextField(placeholder, text: text)
                .font(EW.Font.body)
                .textFieldStyle(.roundedBorder)
        }
    }
}

#Preview("Setup") {
    SetupView().environmentObject(WalletStore.preview())
}
