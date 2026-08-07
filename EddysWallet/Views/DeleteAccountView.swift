import StoreKit
import SwiftUI
import UIKit

struct AccountDeletionBillingNotice: Equatable {
    let warning: String?
    let acknowledgement: String?
    let completionReminder: String?

    var requiresAcknowledgement: Bool { acknowledgement != nil }

    func allowsDeletion(typedConfirmationIsValid: Bool, acknowledged: Bool) -> Bool {
        typedConfirmationIsValid && (!requiresAcknowledgement || acknowledged)
    }

    init(entitlement: CloudEntitlementState?) {
        switch entitlement {
        case .some(.active(_, autoRenewEnabled: false)):
            warning = "Your Cloud access continues until its expiry date, but it will not renew. Deleting your account does not change that Apple subscription."
            acknowledgement = nil
            completionReminder = "Your non-renewing Cloud access remains with Apple until its expiry date."
        case .some(.none), .some(.expired), .some(.refunded), .some(.revoked):
            warning = nil
            acknowledgement = nil
            completionReminder = nil
        case .some(.active(_, autoRenewEnabled: true)), .some(.billingGrace), .some(.billingRetry), .some(.verificationPending):
            warning = "Your Cloud subscription may keep billing through Apple. Deleting your account here does not cancel it. Cancel it in your Apple subscription settings first."
            acknowledgement = "I understand billing may continue through Apple"
            completionReminder = "Your Cloud subscription may still need cancelling in Apple's subscription settings."
        case nil:
            warning = "We could not confirm your Apple subscription status. It may keep billing after account deletion. Check your Apple subscription settings first."
            acknowledgement = "I understand billing may continue through Apple"
            completionReminder = "Check Apple's subscription settings for any Cloud subscription that may still be active."
        }
    }
}

/// The irreversible parent-only account-delete confirmation. Its primary
/// action is pinned in a bottom safe-area inset so the typed confirmation,
/// billing acknowledgement, and destructive action remain simultaneously
/// reviewable on every supported phone and iPad size.
struct DeleteAccountView: View {
    private enum Screen {
        case confirmation
        case deleting
        case deleted
        case incomplete
    }

    @EnvironmentObject private var store: WalletStore
    @Environment(\.openURL) private var openURL
    @State private var confirmation = ""
    @State private var acknowledgesBilling = false
    @State private var refusalMessage: String?
    @State private var deletionKey = UUID().uuidString

    private static let subscriptionsURL = URL(string: "https://apps.apple.com/account/subscriptions")!

    private var isConfirmed: Bool {
        confirmation.trimmingCharacters(in: .whitespacesAndNewlines) == "DELETE"
    }

    private var canDelete: Bool {
        billingNotice.allowsDeletion(
            typedConfirmationIsValid: isConfirmed,
            acknowledged: acknowledgesBilling
        ) && !store.isDeletingAccount
    }

    private var billingNotice: AccountDeletionBillingNotice {
        AccountDeletionBillingNotice(entitlement: store.accountDeletionEntitlement)
    }

    private var screen: Screen {
        switch store.accountDeletionPresentation {
        case .deleting: .deleting
        case .deleted: .deleted
        case .incomplete: .incomplete
        case nil: .confirmation
        }
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
                case .incomplete:
                    incompleteContent
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
        .task {
            if store.accountDeletionPresentation == nil {
                await store.refreshAccountDeletionContext()
            }
        }
    }

    private var navigationTitle: String {
        switch screen {
        case .confirmation: "Delete account"
        case .deleting: "Deleting account"
        case .deleted: "Account deleted"
        case .incomplete: "Finish account deletion"
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
            deletionDetail("This \(DeviceCopy.deviceNoun)'s copy of the wallet, before the service account; your parent PIN afterward")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .ewCard()
    }

    private var billingAndRetentionDetails: some View {
        VStack(alignment: .leading, spacing: EW.Space.four) {
            Label("What this does not do", systemImage: "exclamationmark.triangle.fill")
                .font(EW.Font.headingSmall)
                .foregroundStyle(EW.Color.gold700)

            if let warning = billingNotice.warning {
                Text(warning)
                    .font(EW.Font.body)
                    .foregroundStyle(EW.Color.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button("Manage subscription") {
                showManageSubscriptions()
            }
            .buttonStyle(SecondaryButtonStyle(compact: true))
            .accessibilityIdentifier("delete-account-manage-subscription")

            if let acknowledgement = billingNotice.acknowledgement {
                Toggle(acknowledgement, isOn: $acknowledgesBilling)
                    .font(EW.Font.bodyBold)
                    .foregroundStyle(EW.Color.textPrimary)
                    .tint(EW.Color.gold700)
                    .accessibilityIdentifier("delete-account-billing-acknowledgement")
            }

            Divider().overlay(EW.Color.gold300)

            Text("If \(ProductBrand.displayName) is on another family device, that device keeps its own saved copy. To remove it, delete the app from that device.")
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
            if let completionReminder = billingNotice.completionReminder {
                Text(completionReminder)
                    .font(EW.Font.body)
                    .foregroundStyle(EW.Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
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

    private var incompleteContent: some View {
        VStack(alignment: .leading, spacing: EW.Space.four) {
            Image(systemName: "questionmark.circle.fill")
                .font(.system(size: 48, weight: .semibold))
                .foregroundStyle(EW.Color.gold700)
            Text("Account deletion needs one more step.")
                .font(EW.Font.display)
            Text("This \(DeviceCopy.deviceNoun)'s wallet is no longer available. Try again to finish service or device cleanup. If retry is not possible, remove the app from this device.")
                .font(EW.Font.body)
                .foregroundStyle(EW.Color.textSecondary)
        }
        .ewCard(variant: .alt)
        .accessibilityIdentifier("delete-account-incomplete")
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
        case .incomplete:
            VStack(spacing: EW.Space.three) {
                Button("Try again") { retryDeletion() }
                    .buttonStyle(PrimaryButtonStyle())
                    .accessibilityIdentifier("delete-account-incomplete-retry")
                Button("Finish later") {
                    store.finishAccountDeletionLater()
                }
                .buttonStyle(SecondaryButtonStyle())
                .accessibilityIdentifier("delete-account-incomplete-finish-later")
            }
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
        Task {
            switch await store.deleteAccount(
                idempotencyKey: deletionKey,
                acknowledgedBillingRisk: acknowledgesBilling
            ) {
            case .deleted, .incomplete:
                break
            case .refused(let message):
                refusalMessage = message
            }
        }
    }

    private func retryDeletion() {
        guard let idempotencyKey = store.accountDeletionPresentation?.idempotencyKey else { return }
        Task {
            if case .refused(let message) = await store.retryAccountDeletion(idempotencyKey: idempotencyKey) {
                refusalMessage = message
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
