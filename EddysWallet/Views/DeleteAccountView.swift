import StoreKit
import SwiftUI
import UIKit

/// The irreversible parent-only account-delete confirmation. Its primary
/// action is pinned in a bottom safe-area inset so the typed confirmation,
/// billing acknowledgement, and destructive action remain simultaneously
/// reviewable on every supported phone and iPad size.
struct DeleteAccountView: View {
    private enum Screen {
        case confirmation
        case deleting
        case deleted
        case unknownOutcome
    }

    @EnvironmentObject private var store: WalletStore
    @Environment(\.openURL) private var openURL
    @State private var confirmation = ""
    @State private var acknowledgesBilling = false
    @State private var screen: Screen = .confirmation
    @State private var refusalMessage: String?
    @State private var deletionKey = UUID().uuidString

    private static let subscriptionsURL = URL(string: "https://apps.apple.com/account/subscriptions")!

    private var isConfirmed: Bool {
        confirmation.trimmingCharacters(in: .whitespacesAndNewlines) == "DELETE"
    }

    private var canDelete: Bool {
        isConfirmed && acknowledgesBilling && !store.isDeletingAccount
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: EW.Space.six) {
                switch screen {
                case .confirmation:
                    confirmationContent
                case .deleting:
                    progressContent
                case .deleted:
                    deletedContent
                case .unknownOutcome:
                    unknownOutcomeContent
                }
            }
            .padding(.horizontal, EW.Space.screenMargin)
            .padding(.top, EW.Space.five)
            .padding(.bottom, EW.Space.ten)
            .frame(maxWidth: 620)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(EW.Color.appBackground.ignoresSafeArea())
        .navigationTitle(navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(screen == .deleting || screen == .deleted)
        .interactiveDismissDisabled(screen == .deleting)
        .safeAreaInset(edge: .bottom) {
            bottomAction
        }
    }

    private var navigationTitle: String {
        switch screen {
        case .confirmation: "Delete account"
        case .deleting: "Deleting account"
        case .deleted: "Account deleted"
        case .unknownOutcome: "Check account deletion"
        }
    }

    @ViewBuilder
    private var confirmationContent: some View {
        VStack(alignment: .leading, spacing: EW.Space.three) {
            Text("Delete your account and \(ProductBrand.displayName)?")
                .font(EW.Font.display)
                .foregroundStyle(EW.Color.textPrimary)
            Text("This permanently deletes your parent account and your household. It cannot be undone.")
                .font(EW.Font.body)
                .foregroundStyle(EW.Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        deletionDetails
        billingAndRetentionDetails
        typedConfirmation

        if let refusalMessage {
            Label(refusalMessage, systemImage: "exclamationmark.triangle.fill")
                .font(EW.Font.caption)
                .foregroundStyle(EW.Color.red600)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(EW.Space.three)
                .background(EW.Color.dangerTint, in: RoundedRectangle(cornerRadius: EW.Radius.medium, style: .continuous))
                .accessibilityIdentifier("delete-account-refusal")
        }
    }

    private var deletionDetails: some View {
        VStack(alignment: .leading, spacing: EW.Space.three) {
            Text("What this deletes")
                .font(EW.Font.headingSmall)
                .foregroundStyle(EW.Color.textPrimary)
            deletionDetail("Your parent account and sign-in")
            deletionDetail("Your household, including your child's profile and nickname")
            deletionDetail("The whole wallet: balance, recorded deposits, withdrawals, allowances, loans, and repayments")
            deletionDetail("Your Cloud backup, if you have one")
            deletionDetail("This \(DeviceCopy.deviceNoun)'s copy of the wallet and your parent PIN")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .ewCard()
    }

    private var billingAndRetentionDetails: some View {
        VStack(alignment: .leading, spacing: EW.Space.four) {
            Label("What this does not do", systemImage: "exclamationmark.triangle.fill")
                .font(EW.Font.headingSmall)
                .foregroundStyle(EW.Color.gold700)

            Text("Your Cloud subscription keeps billing through Apple. Deleting your account here does not cancel it. Cancel it in your Apple subscription settings first.")
                .font(EW.Font.body)
                .foregroundStyle(EW.Color.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            Button("Manage subscription") {
                showManageSubscriptions()
            }
            .buttonStyle(SecondaryButtonStyle(compact: true))
            .accessibilityIdentifier("delete-account-manage-subscription")

            Toggle("I understand billing continues through Apple", isOn: $acknowledgesBilling)
                .font(EW.Font.bodyBold)
                .foregroundStyle(EW.Color.textPrimary)
                .tint(EW.Color.gold700)
                .accessibilityIdentifier("delete-account-billing-acknowledgement")

            Divider().overlay(EW.Color.gold300)

            Text("If \(ProductBrand.displayName) is on another family device, that device keeps its own saved copy until it is signed out there.")
                .font(EW.Font.caption)
                .foregroundStyle(EW.Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("Your wallet is removed from the service right away. Encrypted backup copies of the service's database are kept for up to 30 days and then deleted automatically.")
                .font(EW.Font.caption)
                .foregroundStyle(EW.Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(EW.Space.six)
        .background(EW.Color.gold50, in: RoundedRectangle(cornerRadius: EW.Radius.large, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: EW.Radius.large, style: .continuous)
                .stroke(EW.Color.gold300, lineWidth: 1)
        }
    }

    private var typedConfirmation: some View {
        VStack(alignment: .leading, spacing: EW.Space.two) {
            Text("Type DELETE to confirm")
                .font(EW.Font.captionUpper)
                .foregroundStyle(EW.Color.textTertiary)
            TextField("DELETE", text: $confirmation)
                .font(EW.Font.bodyBold)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .textFieldStyle(.roundedBorder)
                .frame(minHeight: 44)
                .accessibilityIdentifier("delete-account-confirmation-field")
            Text("This action is permanent.")
                .font(EW.Font.caption)
                .foregroundStyle(EW.Color.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .ewCard(variant: .alt)
    }

    private var progressContent: some View {
        VStack(alignment: .leading, spacing: EW.Space.four) {
            ProgressView()
                .controlSize(.large)
                .tint(EW.Color.primaryActive)
            Text("Deleting your account…")
                .font(EW.Font.display)
                .foregroundStyle(EW.Color.textPrimary)
            Text("This can take a moment. Don't close the app.")
                .font(EW.Font.body)
                .foregroundStyle(EW.Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .ewCard()
        .accessibilityIdentifier("delete-account-progress")
    }

    private var deletedContent: some View {
        VStack(alignment: .leading, spacing: EW.Space.four) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48, weight: .semibold))
                .foregroundStyle(EW.Color.green700)
                .accessibilityHidden(true)
            Text("Your account and wallet are deleted.")
                .font(EW.Font.display)
                .foregroundStyle(EW.Color.textPrimary)
            Text("Your Cloud subscription, if you had one, still needs cancelling in Apple's subscription settings.")
                .font(EW.Font.body)
                .foregroundStyle(EW.Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Manage subscription") {
                showManageSubscriptions()
            }
            .buttonStyle(SecondaryButtonStyle(compact: true))
            .accessibilityIdentifier("deleted-account-manage-subscription")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .ewCard()
        .accessibilityIdentifier("delete-account-success")
    }

    private var unknownOutcomeContent: some View {
        VStack(alignment: .leading, spacing: EW.Space.four) {
            Image(systemName: "questionmark.circle.fill")
                .font(.system(size: 48, weight: .semibold))
                .foregroundStyle(EW.Color.gold700)
                .accessibilityHidden(true)
            Text("We're not sure whether the deletion went through.")
                .font(EW.Font.display)
                .foregroundStyle(EW.Color.textPrimary)
            Text("Sign in again to check. We have not erased this \(DeviceCopy.deviceNoun)'s wallet because the service did not give a definite answer.")
                .font(EW.Font.body)
                .foregroundStyle(EW.Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .ewCard(variant: .alt)
        .accessibilityIdentifier("delete-account-unknown-outcome")
    }

    @ViewBuilder
    private var bottomAction: some View {
        switch screen {
        case .confirmation:
            Button(role: .destructive) {
                beginDeletion()
            } label: {
                Text("Delete account and wallet")
                    .frame(maxWidth: .infinity, minHeight: 52)
            }
            .buttonStyle(DeleteAccountButtonStyle())
            .disabled(!canDelete)
            .opacity(canDelete ? 1 : 0.45)
            .accessibilityIdentifier("delete-account-confirm-button")
        case .deleted:
            Button("Done") {
                store.finishAccountDeletion()
            }
            .buttonStyle(PrimaryButtonStyle())
            .accessibilityIdentifier("delete-account-done")
        case .unknownOutcome:
            Button("Back to account settings") {
                screen = .confirmation
            }
            .buttonStyle(PrimaryButtonStyle())
            .accessibilityIdentifier("delete-account-unknown-back")
        case .deleting:
            EmptyView()
        }
    }

    private func deletionDetail(_ text: String) -> some View {
        HStack(alignment: .top, spacing: EW.Space.three) {
            Image(systemName: "circle.fill")
                .font(.system(size: 6, weight: .bold))
                .foregroundStyle(EW.Color.textSecondary)
                .padding(.top, 6)
            Text(text)
                .font(EW.Font.body)
                .foregroundStyle(EW.Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func beginDeletion() {
        guard canDelete else { return }
        refusalMessage = nil
        screen = .deleting
        Task {
            switch await store.deleteAccount(idempotencyKey: deletionKey) {
            case .deleted:
                screen = .deleted
            case .refused(let message):
                refusalMessage = message
                screen = .confirmation
            case .unknownOutcome:
                screen = .unknownOutcome
            }
        }
    }

    private func showManageSubscriptions() {
        if #available(iOS 15.0, *),
           let scene = UIApplication.shared.connectedScenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene {
            Task {
                do {
                    try await AppStore.showManageSubscriptions(in: scene)
                } catch {
                    openURL(Self.subscriptionsURL)
                }
            }
        } else {
            openURL(Self.subscriptionsURL)
        }
    }
}

private struct DeleteAccountButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(EW.Font.bodyBold)
            .foregroundStyle(EW.Color.white)
            .padding(.horizontal, EW.Space.six)
            .background(EW.Color.red600, in: RoundedRectangle(cornerRadius: EW.Radius.medium, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
