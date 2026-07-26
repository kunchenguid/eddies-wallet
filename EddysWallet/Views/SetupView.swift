import SwiftUI

struct SetupView: View {
    @EnvironmentObject private var store: WalletStore
    @State private var nickname = "Eddie"
    @State private var familyName = ""
    @State private var ageBand = "school-age"
    @State private var pin = ""
    @State private var confirmationPIN = ""

    private let ageBands = [
        (id: "early-years", title: "Early years"),
        (id: "school-age", title: "School age"),
        (id: "teen", title: "Teen")
    ]

    var body: some View {
        ZStack {
            EW.Color.appBackground.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: EW.Space.six) {
                    VStack(alignment: .leading, spacing: EW.Space.two) {
                        Text("Set up Eddie's wallet")
                            .font(EW.Font.display)
                            .foregroundStyle(EW.Color.textPrimary)
                        Text("Create one parent-managed child profile. No child login or Apple identity is needed.")
                            .font(EW.Font.body)
                            .foregroundStyle(EW.Color.textSecondary)
                    }

                    VStack(alignment: .leading, spacing: EW.Space.four) {
                        field(title: "Eddie's nickname", text: $nickname, placeholder: "Eddie")
                        field(title: "Family name (optional)", text: $familyName, placeholder: "Eddie's family")
                        VStack(alignment: .leading, spacing: EW.Space.two) {
                            Text("Lesson age band")
                                .font(EW.Font.captionUpper)
                                .foregroundStyle(EW.Color.textTertiary)
                            Picker("Lesson age band", selection: $ageBand) {
                                ForEach(ageBands, id: \.id) { band in
                                    Text(band.title).tag(band.id)
                                }
                            }
                            .pickerStyle(.menu)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, EW.Space.four)
                            .frame(minHeight: 52)
                            .background(EW.Color.card, in: RoundedRectangle(cornerRadius: EW.Radius.medium, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: EW.Radius.medium, style: .continuous)
                                    .stroke(EW.Color.border, lineWidth: 1)
                            }
                        }
                        VStack(alignment: .leading, spacing: EW.Space.two) {
                            Text("Parent PIN")
                                .font(EW.Font.captionUpper)
                                .foregroundStyle(EW.Color.textTertiary)
                            Text("This four-digit PIN protects parent mode on this iPad.")
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

                    Text("This creates the family and wallet on the authoritative service. If the request fails, this form remains a local draft and no wallet is claimed to be saved.")
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
                                familyName: familyName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : familyName,
                                nickname: nickname.trimmingCharacters(in: .whitespacesAndNewlines),
                                lessonAgeBand: ageBand
                            )
                            _ = await store.setupParent(setup, pin: pin, confirmation: confirmationPIN)
                        }
                    } label: {
                        if store.isLoading {
                            ProgressView()
                                .frame(maxWidth: .infinity, minHeight: 52)
                        } else {
                            Text("Create Eddie's wallet")
                                .frame(maxWidth: .infinity, minHeight: 52)
                        }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(store.isLoading || nickname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || pin.count != 4 || pin != confirmationPIN)
                    .opacity(store.isLoading || nickname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || pin.count != 4 || pin != confirmationPIN ? 0.45 : 1)

                    Button("Sign out") { store.signOut() }
                        .buttonStyle(SecondaryButtonStyle(compact: true))
                }
                .padding(EW.Space.screenMargin)
                .frame(maxWidth: 620)
                .frame(maxWidth: .infinity, alignment: .center)
            }
        }
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
