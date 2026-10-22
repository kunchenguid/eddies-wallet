import SwiftUI

/// Everything in the Parent area that is not about the wallet's money, on its
/// own screen behind the gear: the optional Cloud plan, the child profile, the
/// parent PIN, the connection readout once something failed, sign-out, and
/// account deletion. Keeping these off the money screen is what lets the
/// balance, the four actions and anything needing attention fit on the first
/// screen there.
struct ParentSettingsView: View {
    @EnvironmentObject private var store: WalletStore
    @State private var isShowingChangePIN = false
    @State private var isShowingEditProfile = false
    @State private var isShowingConnectionDetails = false
    @State private var isConfirmingSignOut = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: EW.Space.six) {
                SectionHeader("Cloud")
                CloudStatusView()

                SectionHeader("Settings")
                settingsCard

                SectionHeader("Account")
                accountCard
            }
            .padding(.horizontal, EW.Space.screenMargin)
            .padding(.top, EW.Space.five)
            .padding(.bottom, EW.Space.ten)
            .frame(maxWidth: 980)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .accessibilityIdentifier("parent-settings-scroll")
        .background(EW.Color.appBackground.ignoresSafeArea())
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(EW.Color.green900, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .sheet(isPresented: $isShowingChangePIN) {
            ChangePINView()
                .ewFormSheetPresentation()
        }
        .sheet(isPresented: $isShowingEditProfile) {
            EditChildProfileView()
                .ewFormSheetPresentation()
        }
        .sheet(isPresented: $isShowingConnectionDetails) {
            if let diagnostic = store.latestTransportDiagnostic {
                ConnectionDetailsView(diagnostic: diagnostic)
                    .ewFormSheetPresentation()
            }
        }
    }

    private var settingsCard: some View {
        VStack(spacing: 0) {
            if store.canModifyWallet {
                settingsRow(title: "Edit child profile", icon: "person.crop.circle", isEnabled: store.canStartParentMutation, accessibilityIdentifier: "edit-child-profile-settings") {
                    isShowingEditProfile = true
                }
                Divider().overlay(EW.Color.border)
            }
            settingsRow(title: "Change PIN", icon: "lock.rotation") {
                isShowingChangePIN = true
            }
            Divider().overlay(EW.Color.border)
            // Only offered once something actually failed: a family with a
            // healthy connection is never shown a diagnostics row.
            if store.latestTransportDiagnostic != nil {
                settingsRow(
                    title: "Connection details",
                    icon: "antenna.radiowaves.left.and.right",
                    accessibilityIdentifier: "connection-details-settings"
                ) {
                    isShowingConnectionDetails = true
                }
                Divider().overlay(EW.Color.border)
            }
            settingsRow(title: "Sign out", icon: "rectangle.portrait.and.arrow.right", role: .destructive) {
                isConfirmingSignOut = true
            }
        }
        .padding(.horizontal, EW.Space.five)
        .background(EW.Color.card, in: RoundedRectangle(cornerRadius: EW.Radius.large, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: EW.Radius.large, style: .continuous).stroke(EW.Color.border, lineWidth: 1)
        }
        .confirmationDialog(signOutTitle, isPresented: $isConfirmingSignOut, titleVisibility: .visible) {
            Button(signOutButtonTitle, role: .destructive) {
                if store.canSignOutOfCloudOnThisDevice {
                    Task { await store.signOutOfCloudOnThisDevice() }
                } else {
                    store.signOut()
                }
            }
            Button("Stay signed in", role: .cancel) {}
        } message: {
            Text(signOutMessage)
        }
    }

    private var accountCard: some View {
        NavigationLink {
            DeleteAccountView()
        } label: {
            settingsRowLabel(title: "Delete account and wallet", icon: "trash", role: .destructive)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, EW.Space.five)
        .background(EW.Color.card, in: RoundedRectangle(cornerRadius: EW.Radius.large, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: EW.Radius.large, style: .continuous).stroke(EW.Color.border, lineWidth: 1)
        }
        .accessibilityIdentifier("delete-account-settings")
    }

    private var signOutTitle: String {
        switch store.cloudSignOutMode {
        case .cloudDevice: "Sign out of Cloud on this \(DeviceCopy.deviceNoun)?"
        case .serviceDevice: "Sign out?"
        case .localErase: "Sign out and erase this device's wallet?"
        }
    }

    private var signOutButtonTitle: String {
        store.cloudSignOutMode == .localErase ? "Sign out and erase wallet" : "Sign out from this \(DeviceCopy.deviceNoun)"
    }

    private var signOutMessage: String {
        switch store.cloudSignOutMode {
        case .cloudDevice:
            "This \(DeviceCopy.deviceNoun) stops syncing with Cloud. The wallet keeps working here and nothing is deleted."
        case .serviceDevice:
            "This removes the local Cloud view and parent PIN from this \(DeviceCopy.deviceNoun). It does not delete the Cloud wallet."
        case .localErase:
            "There is no Cloud backup for this wallet. This permanently erases the wallet, parent PIN, and parent identity evidence from this \(DeviceCopy.deviceNoun)."
        }
    }

    private func settingsRow(title: String, icon: String, role: ButtonRole? = nil, isEnabled: Bool = true, accessibilityIdentifier: String? = nil, action: @escaping () -> Void) -> some View {
        Button(role: role, action: action) {
            settingsRowLabel(title: title, icon: icon, role: role)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.5)
        .accessibilityIdentifier(accessibilityIdentifier ?? title)
    }

    private func settingsRowLabel(title: String, icon: String, role: ButtonRole? = nil) -> some View {
        HStack(spacing: EW.Space.three) {
            Image(systemName: icon)
                .foregroundStyle(role == .destructive ? EW.Color.red600 : EW.Color.textSecondary)
                .frame(width: 24)
            Text(title)
                .font(EW.Font.bodyBold)
                .foregroundStyle(role == .destructive ? EW.Color.red600 : EW.Color.textPrimary)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(EW.Color.textTertiary)
        }
        .padding(.vertical, EW.Space.three)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }
}

/// The whole activity history, one tap past the five rows the Parent area
/// keeps in view. Rows open the same detail sheet they open on the wallet.
struct ParentActivityListView: View {
    @EnvironmentObject private var store: WalletStore
    @State private var selectedEvent: WalletEvent?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: EW.Space.six) {
                if store.snapshot.activities.isEmpty {
                    Text("Nothing recorded yet.")
                        .font(EW.Font.body)
                        .foregroundStyle(EW.Color.textSecondary)
                } else {
                    ActivityListCard(
                        events: store.snapshot.activities,
                        childRecorderName: ActivityDetailCopy.childRecorderName(audience: .parent, nickname: store.snapshot.configuredChildNickname)
                    ) { event in
                        selectedEvent = event
                    }
                }
            }
            .padding(.horizontal, EW.Space.screenMargin)
            .padding(.top, EW.Space.five)
            .padding(.bottom, EW.Space.ten)
            .frame(maxWidth: 980)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .accessibilityIdentifier("parent-all-activity")
        .background(EW.Color.appBackground.ignoresSafeArea())
        .navigationTitle("All activity")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(EW.Color.green900, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .sheet(item: $selectedEvent) { event in
            ActivityDetailView(event: event, childNickname: store.snapshot.configuredChildNickname)
                .ewDetailSheetPresentation()
        }
    }
}
