import SwiftUI
import UIKit

/// Full-screen Parent gate. Never shows family data. Routes:
/// - PIN entry (with bounded retries and a cooldown after repeated misses)
/// - owning-parent re-authentication (expired session, forgotten/missing PIN)
/// - choosing a new parent PIN after successful re-authentication
///
/// PIN entry is deliberately **not** scrollable: a keypad that drifts or
/// bounces under the thumb makes people miss digits. It sizes itself to the
/// screen instead (see `PINKeypad`), and its surrounding words stop growing at
/// `xxxLarge` so an accessibility text size can never push a key off screen -
/// the digits themselves keep scaling. The two recovery routes keep a scroll
/// view because they carry text fields the software keyboard can cover.
struct ParentGateView: View {
    @EnvironmentObject private var store: WalletStore

    var body: some View {
        ZStack {
            EW.Color.appBackground.ignoresSafeArea()
            switch store.gateRoute {
            case .pinEntry:
                PINEntryGate()
                    .padding(EW.Space.screenMargin)
                    .frame(maxWidth: 460)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            case .reauth(let reason):
                scrollingRoute { ReauthGate(reason: reason) }
            case .setPIN:
                scrollingRoute { SetNewPINGate() }
            }
        }
    }

    private func scrollingRoute<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ScrollView {
            content()
                .padding(EW.Space.screenMargin)
                .frame(maxWidth: 460)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, EW.Space.seven)
        }
    }
}

private struct GateHeader: View {
    let title: String
    let subtitle: String?

    var body: some View {
        VStack(spacing: EW.Space.three) {
            IconBadge("lock.fill", foreground: EW.Color.green700, background: EW.Color.green100, size: 56)
            Text(title)
                .font(EW.Font.display)
                .foregroundStyle(EW.Color.textPrimary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let subtitle {
                Text(subtitle)
                    .font(EW.Font.body)
                    .foregroundStyle(EW.Color.textTertiary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
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
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var shakeTrigger = 0

    var body: some View {
        ViewThatFits(in: .vertical) {
            gateContent(showsSubtitle: true, spacing: EW.Space.four)
            gateContent(showsSubtitle: false, spacing: EW.Space.three)
        }
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
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
    }

    private func gateContent(showsSubtitle: Bool, spacing: CGFloat) -> some View {
        VStack(spacing: spacing) {
            GateHeader(
                title: "Parent only",
                subtitle: showsSubtitle ? "Enter the parent PIN for this \(DeviceCopy.deviceNoun)." : nil
            )

            statusLine

            pinDots
                .modifier(ShakeEffect(animatableData: CGFloat(shakeTrigger)))

            keypad

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

    /// The keypad takes whatever height is left and sizes its keys to it, so
    /// the gate always fits the screen exactly once.
    private var keypad: some View {
        GeometryReader { proxy in
            PINKeypad(
                availableWidth: proxy.size.width,
                availableHeight: proxy.size.height,
                isDisabled: store.isCoolingDown,
                onDigit: { store.appendPINDigit($0) },
                onDelete: { store.deletePINDigit() }
            )
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .frame(minHeight: PINKeypad.minimumHeight, maxHeight: .infinity)
        .dynamicTypeSize(dynamicTypeSize)
    }

    private var statusMessage: String? {
        if store.isCoolingDown {
            return "Too many tries. Wait \(store.cooldownSecondsRemaining)s, then try again."
        }
        if store.pinError {
            return "Incorrect PIN. Try again."
        }
        return nil
    }

    /// Always reserves its two lines. An error that appeared or cleared must
    /// never move the keys under a thumb that is already on its way down.
    private var statusLine: some View {
        // A blank space, not an empty string: an empty `Text` reserves nothing
        // and the keypad would resize the moment a message appeared.
        Text(statusMessage ?? " ")
            .font(EW.Font.bodyBold)
            .foregroundStyle(EW.Color.red600)
            .multilineTextAlignment(.center)
            .lineLimit(2, reservesSpace: true)
            .frame(maxWidth: .infinity)
            .accessibilityHidden(statusMessage == nil)
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
        .accessibilityIdentifier("pin-entry-dots")
    }
}

/// Balanced three-column numeric grid modeled on the familiar Apple
/// lock-screen keypad: generous circular hit targets sized from the actual
/// measured space (device size, safe area) within a comfortable range, so
/// nothing clips on any supported iPhone or iPad and the keypad never
/// depends on one fixed screen size.
///
/// It fits *height* as well as width, because the gate that hosts it does not
/// scroll: on a short screen the keys and their gaps tighten together rather
/// than pushing the keypad under the fold. `availableHeight <= 0` means the
/// caller is not constraining height (previews), so only width is fitted.
struct PINKeypad: View {
    let availableWidth: CGFloat
    var availableHeight: CGFloat = 0
    let isDisabled: Bool
    let onDigit: (String) -> Void
    let onDelete: () -> Void

    /// Never below the 44pt minimum hit target, even on the smallest screen.
    private static let minDiameter: CGFloat = 48
    static let minimumHeight: CGFloat = minDiameter * 4 + EW.Space.three * 3
    private let comfortableDiameter: CGFloat = 64
    private let maxDiameter: CGFloat = 88
    /// Gaps are given up before key size is: a smaller gap between big keys
    /// beats a roomy grid of small ones.
    private let tightestSpacing: CGFloat = EW.Space.three
    private var candidateSpacings: [CGFloat] { [EW.Space.six, EW.Space.four, tightestSpacing] }

    private var metrics: (spacing: CGFloat, diameter: CGFloat) {
        for spacing in candidateSpacings where diameter(spacing: spacing) >= comfortableDiameter {
            return (spacing, diameter(spacing: spacing))
        }
        return (tightestSpacing, diameter(spacing: tightestSpacing))
    }

    private var spacing: CGFloat { metrics.spacing }
    private var diameter: CGFloat { metrics.diameter }

    private func diameter(spacing: CGFloat) -> CGFloat {
        let widthFitted = (min(availableWidth, 320) - spacing * 2) / 3
        let heightFitted = availableHeight > 0
            ? (availableHeight - spacing * 3) / 4
            : .greatestFiniteMagnitude
        return min(max(min(widthFitted, heightFitted), Self.minDiameter), maxDiameter)
    }

    var body: some View {
        VStack(spacing: spacing) {
            keypadRow(["1", "2", "3"])
            keypadRow(["4", "5", "6"])
            keypadRow(["7", "8", "9"])
            HStack(spacing: spacing) {
                Color.clear.frame(width: diameter, height: diameter)
                keypadButton("0")
                Button {
                    onDelete()
                } label: {
                    Image(systemName: "delete.left")
                        .font(EW.Font.heading)
                        .frame(width: diameter, height: diameter)
                }
                .buttonStyle(.plain)
                .foregroundStyle(EW.Color.textSecondary)
                .accessibilityLabel("Delete last PIN digit")
            }
        }
        .frame(maxWidth: .infinity)
        .opacity(isDisabled ? 0.4 : 1)
        .disabled(isDisabled)
    }

    private func keypadRow(_ digits: [String]) -> some View {
        HStack(spacing: spacing) {
            ForEach(digits, id: \.self) { keypadButton($0) }
        }
    }

    private func keypadButton(_ digit: String) -> some View {
        Button {
            onDigit(digit)
        } label: {
            Text(digit)
                .font(EW.Font.heading)
                .foregroundStyle(EW.Color.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .frame(width: diameter, height: diameter)
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
