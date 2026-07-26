import SwiftUI

struct ParentPINSetupView: View {
    @EnvironmentObject private var store: WalletStore
    @State private var pin = ""
    @State private var confirmation = ""

    var body: some View {
        ZStack {
            EW.Color.appBackground.ignoresSafeArea()
            VStack(alignment: .leading, spacing: EW.Space.five) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 42))
                    .foregroundStyle(EW.Color.primaryActive)
                Text("Set a parent PIN")
                    .font(EW.Font.display)
                    .foregroundStyle(EW.Color.textPrimary)
                Text("This PIN protects parent mode on this iPad. It does not grant service permissions or create a child login.")
                    .font(EW.Font.body)
                    .foregroundStyle(EW.Color.textSecondary)
                SecureField("Four digits", text: $pin)
                    .keyboardType(.numberPad)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: pin) { _, value in pin = String(value.filter(\.isNumber).prefix(4)) }
                SecureField("Confirm PIN", text: $confirmation)
                    .keyboardType(.numberPad)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: confirmation) { _, value in confirmation = String(value.filter(\.isNumber).prefix(4)) }
                if let errorMessage = store.errorMessage {
                    Text(errorMessage)
                        .font(EW.Font.caption)
                        .foregroundStyle(EW.Color.red600)
                }
                Button("Save parent PIN") {
                    _ = store.setParentPIN(pin, confirmation: confirmation)
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(pin.count != 4 || pin != confirmation)
                .opacity(pin.count != 4 || pin != confirmation ? 0.45 : 1)
                Button("Sign out") { store.signOut() }
                    .buttonStyle(SecondaryButtonStyle(compact: true))
            }
            .padding(EW.Space.screenMargin)
            .frame(maxWidth: 620)
        }
    }
}

#Preview("Parent PIN") {
    ParentPINSetupView().environmentObject(WalletStore.preview())
}
