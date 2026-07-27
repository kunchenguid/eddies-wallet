import SwiftUI
import UIKit

/// Full-screen Grown-ups gate. Never shows family data. Routes:
/// - PIN entry (with bounded retries and a cooldown after repeated misses)
/// - owning-parent re-authentication (expired session, forgotten/missing PIN)
/// - choosing a new parent PIN after successful re-authentication
struct ParentGateView: View {
    @EnvironmentObject private var store: WalletStore

    var body: some View {
        ZStack {
            EW.Color.appBackground.ignoresSafeArea()
            ScrollView {
                Group {
                    switch store.gateRoute {
                    case .pinEntry:
                        PINEntryGate()
                    case .reauth(let reason):
                        ReauthGate(reason: reason)
                    case .setPIN:
                        SetNewPINGate()
                    }
                }
                .padding(EW.Space.screenMargin)
                .frame(maxWidth: 460)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, EW.Space.seven)
            }
        }
    }
}

private struct GateHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: EW.Space.three) {
            IconBadge("lock.fill", foreground: EW.Color.green700, background: EW.Color.green100, size: 56)
            Text(title)
                .font(EW.Font.display)
                .foregroundStyle(EW.Color.textPrimary)
                .multilineTextAlignment(.center)
            Text(subtitle)
                .font(EW.Font.body)
                .foregroundStyle(EW.Color.textTertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct GateCancelButton: View {
    @EnvironmentObject private var store: WalletStore

    var body: some View {
        Button("Cancel") {
            store.cancelParentGate()
        }
        .font(EW.Font.bodyBold)
        .foregroundStyle(EW.Color.textSecondary)
        .frame(minWidth: 44, minHeight: 44)
        .accessibilityHint("Goes back to the wallet")
    }
}

private struct PINEntryGate: View {
    @EnvironmentObject private var store: WalletStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shakeTrigger = 0

    var body: some View {
        VStack(spacing: EW.Space.five) {
            GateHeader(
                title: "Grown-ups only",
                subtitle: "Enter the parent PIN for this \(DeviceCopy.deviceNoun)."
            )

            statusLine

            pinDots
                .modifier(ShakeEffect(animatableData: CGFloat(shakeTrigger)))
                .onChange(of: store.pinError) { _, isError in
                    guard isError else { return }
                    if reduceMotion {
                        shakeTrigger = 0
                    } else {
                        withAnimation(.linear(duration: 0.3)) { shakeTrigger += 1 }
                    }
                    UIAccessibility.post(
                        notification: .announcement,
                        argument: store.isCoolingDown
                            ? "Incorrect PIN. The keypad is paused for a moment."
                            : "Incorrect PIN. \(store.attemptsRemaining) tries left before a short pause."
                    )
                }

            PINKeypad(
                isDisabled: store.isCoolingDown,
                onDigit: { store.appendPINDigit($0) },
                onDelete: { store.deletePINDigit() }
            )

            Button("Forgot PIN?") {
                store.requestPINRecovery()
            }
            .font(EW.Font.body)
            .foregroundStyle(EW.Color.primaryActive)
            .frame(minHeight: 44)
            .accessibilityHint("Sign in with Apple as the parent to choose a new PIN")

            GateCancelButton()
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        if store.isCoolingDown {
            Text("Too many tries. Wait \(store.cooldownSecondsRemaining)s, then try again.")
                .font(EW.Font.bodyBold)
                .foregroundStyle(EW.Color.red600)
                .multilineTextAlignment(.center)
        } else if store.pinError {
            Text("Incorrect PIN. Try again.")
                .font(EW.Font.bodyBold)
                .foregroundStyle(EW.Color.red600)
                .multilineTextAlignment(.center)
        } else {
            Text("Enter the four-digit parent PIN.")
                .font(EW.Font.body)
                .foregroundStyle(EW.Color.textSecondary)
                .multilineTextAlignment(.center)
        }
    }

    private var pinDots: some View {
        HStack(spacing: EW.Space.four) {
            ForEach(0..<4, id: \.self) { index in
                Circle()
                    .fill(index < store.pin.count ? EW.Color.primary : .clear)
                    .frame(width: 14, height: 14)
                    .overlay(Circle().stroke(index < store.pin.count ? EW.Color.primary : EW.Color.ink300, lineWidth: 1.5))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("PIN, \(store.pin.count) of 4 digits entered")
    }
}

struct PINKeypad: View {
    let isDisabled: Bool
    let onDigit: (String) -> Void
    let onDelete: () -> Void

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(64)), count: 3), spacing: EW.Space.four) {
            ForEach(["1", "2", "3", "4", "5", "6", "7", "8", "9"], id: \.self) { digit in
                keypadButton(digit)
            }
            Color.clear.frame(width: 64, height: 64)
            keypadButton("0")
            Button {
                onDelete()
            } label: {
                Image(systemName: "delete.left")
                    .font(EW.Font.heading)
                    .frame(width: 64, height: 64)
            }
            .buttonStyle(.plain)
            .foregroundStyle(EW.Color.textSecondary)
            .accessibilityLabel("Delete last PIN digit")
        }
        .opacity(isDisabled ? 0.4 : 1)
        .disabled(isDisabled)
    }

    private func keypadButton(_ digit: String) -> some View {
        Button {
            onDigit(digit)
        } label: {
            Text(digit)
                .font(EW.Font.heading)
                .foregroundStyle(EW.Color.textPrimary)
                .frame(width: 64, height: 64)
                .background(EW.Color.cardAlt, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("PIN digit \(digit)")
    }
}

private struct ReauthGate: View {
    @EnvironmentObject private var store: WalletStore
    let reason: ParentReauthReason

    var body: some View {
        VStack(spacing: EW.Space.five) {
            GateHeader(title: title, subtitle: subtitle)

            if store.canVerifyOwningParent {
                Button {
                    Task { await store.reauthenticateOwningParent() }
                } label: {
                    if store.isSigningIn {
                        ProgressView()
                            .tint(.white)
                            .frame(maxWidth: .infinity, minHeight: 52)
                    } else {
                        Label("Sign in with Apple", systemImage: "apple.logo")
                    }
                }
                .buttonStyle(AppleSignInButtonStyle())
                .disabled(store.isSigningIn)
                .accessibilityHint("Only the parent Apple account that set up this wallet is accepted")

                Text("Only the Apple account that set up this wallet is accepted.")
                    .font(EW.Font.caption)
                    .foregroundStyle(EW.Color.textTertiary)
                    .multilineTextAlignment(.center)
            } else {
                Text("This \(DeviceCopy.deviceNoun) cannot confirm which Apple account manages this wallet, so recovery is unavailable here. The wallet and family data have not been changed.")
                    .font(EW.Font.body)
                    .foregroundStyle(EW.Color.textSecondary)
                    .multilineTextAlignment(.center)
            }

            if let gateErrorMessage = store.gateErrorMessage {
                Text(gateErrorMessage)
                    .font(EW.Font.caption)
                    .foregroundStyle(EW.Color.red600)
                    .multilineTextAlignment(.center)
            }

            GateCancelButton()
        }
    }

    private var title: String {
        switch reason {
        case .sessionExpired: "Sign in again"
        case .forgotPIN, .missingPIN: "Reset the parent PIN"
        }
    }

    private var subtitle: String {
        switch reason {
        case .sessionExpired:
            "The parent session on this \(DeviceCopy.deviceNoun) ended. Sign in with Apple to continue."
        case .forgotPIN:
            "Sign in with Apple as the parent who set up this wallet, then choose a new PIN. Nothing else changes."
        case .missingPIN:
            "This \(DeviceCopy.deviceNoun) has no parent PIN yet. Sign in with Apple as the parent who set up this wallet, then choose one."
        }
    }
}

private struct SetNewPINGate: View {
    @EnvironmentObject private var store: WalletStore
    @State private var newPIN = ""
    @State private var confirmation = ""

    private var isValid: Bool {
        newPIN.count == 4 && newPIN == confirmation
    }

    var body: some View {
        VStack(spacing: EW.Space.five) {
            GateHeader(
                title: "Choose a new parent PIN",
                subtitle: "This PIN protects parent controls on this \(DeviceCopy.deviceNoun). It does not grant service permissions or create a child login."
            )

            VStack(alignment: .leading, spacing: EW.Space.three) {
                SecureField("Four digits", text: $newPIN)
                    .keyboardType(.numberPad)
                    .textFieldStyle(.roundedBorder)
                    .frame(minHeight: 44)
                    .onChange(of: newPIN) { _, value in newPIN = String(value.filter(\.isNumber).prefix(4)) }
                    .accessibilityLabel("New parent PIN")
                SecureField("Confirm PIN", text: $confirmation)
                    .keyboardType(.numberPad)
                    .textFieldStyle(.roundedBorder)
                    .frame(minHeight: 44)
                    .onChange(of: confirmation) { _, value in confirmation = String(value.filter(\.isNumber).prefix(4)) }
                    .accessibilityLabel("Confirm new parent PIN")
            }

            if let gateErrorMessage = store.gateErrorMessage {
                Text(gateErrorMessage)
                    .font(EW.Font.caption)
                    .foregroundStyle(EW.Color.red600)
                    .multilineTextAlignment(.center)
            }

            Button("Save parent PIN") {
                store.completeGatePINSetup(pin: newPIN, confirmation: confirmation)
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(!isValid)
            .opacity(isValid ? 1 : 0.45)

            GateCancelButton()
        }
    }
}

/// Small horizontal shake used for a wrong PIN. Driven by an integer trigger
/// so Reduce Motion can skip it entirely.
private struct ShakeEffect: GeometryEffect {
    var animatableData: CGFloat

    func effectValue(size: CGSize) -> ProjectionTransform {
        let translation = 8 * sin(animatableData * .pi * 4)
        return ProjectionTransform(CGAffineTransform(translationX: translation, y: 0))
    }
}

#Preview("Parent gate") {
    let store = WalletStore.preview()
    store.openParentGate()
    return ParentGateView().environmentObject(store)
}
