import SwiftUI

/// The transient, visibly distinct parent administrative area. Presented as a
/// full-screen cover over the kid home while elevation is active, with an
/// unmistakable header and an explicit exit. Every money control, the
/// allowance rule, PIN change, and sign-out live only on this screen.
struct ParentAreaView: View {
    @EnvironmentObject private var store: WalletStore
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var selectedEvent: WalletEvent?
    @State private var isShowingLoan = false
    @State private var flow: MoneyFlowKind?
    @State private var isShowingAllowance = false
    @State private var isShowingChangePIN = false
    @State private var isShowingEditProfile = false
    @State private var isConfirmingSignOut = false

    private var isRegularWidth: Bool { horizontalSizeClass == .regular }

    private var childWalletReference: String {
        ChildProfileCopy.walletReference(nickname: store.snapshot.configuredChildNickname)
    }

    /// Shows the first-actions spotlight right after setup, and whenever the
    /// wallet has no recorded activity or allowance rule yet.
    private var showsHandoffCard: Bool {
        store.canModifyWallet
            && (store.showsFirstActionsHandoff
            || (store.snapshot.activities.isEmpty
                && store.snapshot.pendingEvents.isEmpty
                && store.snapshot.allowance == nil))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: EW.Space.six) {
                    if let errorMessage = store.errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .font(EW.Font.caption)
                            .foregroundStyle(EW.Color.red600)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(EW.Space.three)
                            .background(EW.Color.dangerTint, in: RoundedRectangle(cornerRadius: EW.Radius.medium, style: .continuous))
                    }

                    if store.canShowWalletData {
                        if showsHandoffCard {
                            firstActionsCard
                        }

                        walletCards

                        SectionHeader("Recent activity")
                        if store.snapshot.activities.isEmpty {
                            Text("Nothing recorded yet. Add a first deposit or set the weekly allowance.")
                                .font(EW.Font.body)
                                .foregroundStyle(EW.Color.textSecondary)
                        } else {
                            ActivityListCard(events: store.snapshot.activities) { event in
                                selectedEvent = event
                            }
                        }

                        if store.canModifyWallet {
                            SectionHeader("Parent actions")
                            actionGrid
                        } else {
                            cloudReadOnlyCard
                        }
                    } else {
                        cloudReplicaUnavailableCard
                    }

                    SectionHeader("Cloud")
                    CloudStatusView()

                    SectionHeader("Settings")
                    settingsCard
                }
                .padding(.horizontal, EW.Space.screenMargin)
                .padding(.top, EW.Space.five)
                .padding(.bottom, EW.Space.ten)
                .frame(maxWidth: 980)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .background(EW.Color.appBackground.ignoresSafeArea())
            .navigationTitle("Parent area")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    doneButton
                }
            }
            .toolbarBackground(EW.Color.green900, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .refreshable {
                await store.refresh()
            }
        }
        .sheet(item: $selectedEvent) { event in
            ActivityDetailView(event: event)
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $isShowingLoan) {
            LoanDetailView(isParent: true, onRepay: {
                isShowingLoan = false
                flow = .repayment
            })
            .presentationDetents([.medium, .large])
        }
        .sheet(item: $flow) { kind in
            MoneyFlowView(kind: kind)
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $isShowingAllowance) {
            AllowanceView()
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $isShowingChangePIN) {
            ChangePINView()
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $isShowingEditProfile) {
            EditChildProfileView()
                .presentationDetents([.medium, .large])
        }
    }

    /// Persistent, explicit exit in the dark-green Parent area bar: visibly
    /// not the kid's space, always one tap back to the kid home.
    private var doneButton: some View {
        Button {
            store.exitParentArea()
        } label: {
            Text("Done")
                .font(EW.Font.bodyBold)
                .foregroundStyle(EW.Color.green900)
                .padding(.horizontal, EW.Space.four)
                .padding(.vertical, EW.Space.two)
                .background(EW.Color.cream50, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Done. Back to \(childWalletReference)")
    }

    private var firstActionsCard: some View {
        VStack(alignment: .leading, spacing: EW.Space.four) {
            Label("You're all set", systemImage: "checkmark.seal.fill")
                .font(EW.Font.heading)
                .foregroundStyle(EW.Color.textPrimary)
            Text("Give \(ChildProfileCopy.childReference(nickname: store.snapshot.configuredChildNickname)) something to see: add the first pretend dollars or set the weekly allowance.")
                .font(EW.Font.body)
                .foregroundStyle(EW.Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: EW.Space.three) {
                Button("Add a first deposit") { flow = .deposit }
                    .buttonStyle(SecondaryButtonStyle(compact: true))
                Button("Set a weekly allowance") { isShowingAllowance = true }
                    .buttonStyle(SecondaryButtonStyle(compact: true))
            }
            Button {
                store.exitParentArea()
            } label: {
                Label("Show \(childWalletReference)", systemImage: "arrow.uturn.left")
                    .frame(maxWidth: .infinity, minHeight: 52)
            }
            .buttonStyle(PrimaryButtonStyle())
            .accessibilityHint("Leaves the Parent area")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .ewCard()
    }

    static func cloudReplicaUnavailableMessage(deviceNoun: String) -> String {
        "Reconnect this \(deviceNoun) to finish Cloud setup and show the wallet balance and activity."
    }

    private var cloudReplicaUnavailableCard: some View {
        VStack(alignment: .leading, spacing: EW.Space.three) {
            Label("Cloud wallet unavailable", systemImage: "icloud.slash")
                .font(EW.Font.heading)
                .foregroundStyle(EW.Color.textPrimary)
            Text(Self.cloudReplicaUnavailableMessage(deviceNoun: DeviceCopy.deviceNoun))
                .font(EW.Font.body)
                .foregroundStyle(EW.Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .ewCard(variant: .alt)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("parent-cloud-replica-unavailable")
    }

    /// Balance + allowance pair on top; loan + sync pair below. On regular
    /// widths a lone second-row card spans the full width so the grid never
    /// leaves an orphan gap.
    @ViewBuilder
    private var walletCards: some View {
        let loan = store.snapshot.loan
        let hasPending = !store.snapshot.pendingEvents.isEmpty
        if isRegularWidth {
            HStack(alignment: .top, spacing: EW.Space.five) {
                balanceCard.frame(maxWidth: .infinity)
                allowanceCard.frame(maxWidth: .infinity)
            }
            .fixedSize(horizontal: false, vertical: true)
            if let loan, hasPending {
                HStack(alignment: .top, spacing: EW.Space.five) {
                    LoanCardView(loan: loan, isParent: true) { isShowingLoan = true }
                        .frame(maxWidth: .infinity)
                    syncStatusCard.frame(maxWidth: .infinity)
                }
                .fixedSize(horizontal: false, vertical: true)
            } else if let loan {
                LoanCardView(loan: loan, isParent: true) { isShowingLoan = true }
            } else if hasPending {
                syncStatusCard
            }
        } else {
            balanceCard
            allowanceCard
            if let loan {
                LoanCardView(loan: loan, isParent: true) { isShowingLoan = true }
            }
            if hasPending {
                syncStatusCard
            }
        }
    }

    private var balanceCard: some View {
        VStack(alignment: .leading, spacing: EW.Space.three) {
            Text(ChildProfileCopy.parentBalanceTitle(nickname: store.snapshot.configuredChildNickname))
                .font(EW.Font.captionUpper)
                .foregroundStyle(EW.Color.textTertiary)
                .textCase(.uppercase)
            MoneyAmount(cents: store.snapshot.acceptedBalanceCents, font: EW.Font.displayBalance)
            Text("Virtual practice only. These dollars are pretend, cannot be redeemed, and never move real money.")
                .font(EW.Font.body)
                .foregroundStyle(EW.Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            FreshnessLabel(date: store.snapshot.lastUpdated, isStale: store.snapshot.isStale)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .ewCard()
    }

    private var allowanceCard: some View {
        Group {
            if store.canModifyWallet {
                Button {
                    isShowingAllowance = true
                } label: {
                    HStack(spacing: EW.Space.two) {
                        allowanceCardContent
                        Image(systemName: "chevron.right")
                            .foregroundStyle(EW.Color.textTertiary)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens allowance setup")
            } else {
                allowanceCardContent
            }
        }
        .frame(minHeight: 44, maxHeight: .infinity, alignment: .topLeading)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .ewCard(variant: .alt)
    }

    private var allowanceCardContent: some View {
        HStack(alignment: .top, spacing: EW.Space.three) {
            IconBadge("calendar", foreground: EW.Color.gold700, background: EW.Color.goldTint)
            VStack(alignment: .leading, spacing: EW.Space.one) {
                Text("Next allowance")
                    .font(EW.Font.bodyBold)
                    .foregroundStyle(EW.Color.textPrimary)
                if let allowance = store.snapshot.allowance {
                    Text("\(Money(cents: allowance.amountCents).display) \(allowance.cadence)")
                        .font(EW.Font.body)
                        .foregroundStyle(EW.Color.textSecondary)
                    Text("Starting \(allowance.nextDate.formatted(.dateTime.month(.abbreviated).day()))")
                        .font(EW.Font.caption)
                        .foregroundStyle(EW.Color.textTertiary)
                    if allowance.syncState != .recorded {
                        StatusPill(state: allowance.syncState)
                    }
                } else {
                    Text(store.canModifyWallet ? "Set a weekly allowance" : "No weekly allowance")
                        .font(EW.Font.body)
                        .foregroundStyle(EW.Color.textSecondary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: EW.Space.two)
        }
    }

    private var cloudReadOnlyCard: some View {
        VStack(alignment: .leading, spacing: EW.Space.three) {
            Label("Cloud wallet is read-only", systemImage: "icloud")
                .font(EW.Font.headingSmall)
                .foregroundStyle(EW.Color.textPrimary)
            Text("This version shows the wallet accepted by Cloud. Recording money, changing allowance, and editing the child profile stay unavailable until Cloud write support is ready.")
                .font(EW.Font.body)
                .foregroundStyle(EW.Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Refresh from Cloud") {
                Task { await store.refresh() }
            }
            .buttonStyle(.plain)
            .font(EW.Font.bodyBold)
            .foregroundStyle(EW.Color.primaryActive)
            .accessibilityIdentifier("cloud-read-only-refresh-button")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .ewCard(variant: .alt)
    }

    private var syncStatusCard: some View {
        VStack(alignment: .leading, spacing: EW.Space.three) {
            Label("Sync status", systemImage: "arrow.triangle.2.circlepath")
                .font(EW.Font.headingSmall)
                .foregroundStyle(EW.Color.textPrimary)
            ForEach(store.snapshot.pendingEvents) { event in
                VStack(alignment: .leading, spacing: EW.Space.two) {
                    Button {
                        selectedEvent = event
                    } label: {
                        HStack(spacing: EW.Space.three) {
                            IconBadge(event.type.iconName, foreground: stateColor(event.syncState), background: stateTint(event.syncState), size: 36)
                            VStack(alignment: .leading, spacing: EW.Space.one) {
                                Text(event.displayReason)
                                    .font(EW.Font.bodyBold)
                                    .foregroundStyle(EW.Color.textPrimary)
                                    .lineLimit(1)
                                MoneyAmount(cents: event.amountCents, font: EW.Font.caption, color: EW.Color.textSecondary)
                            }
                            Spacer()
                            StatusPill(state: event.syncState)
                        }
                        .frame(minHeight: 44)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .ewCard(variant: .alt)
    }

    /// Non-lazy so every action stays in the accessibility tree; the odd
    /// fifth action spans the full width on regular layouts instead of
    /// leaving an orphan cell.
    @ViewBuilder
    private var actionGrid: some View {
        if isRegularWidth {
            VStack(spacing: EW.Space.three) {
                HStack(spacing: EW.Space.three) {
                    depositButton
                    withdrawalButton
                }
                HStack(spacing: EW.Space.three) {
                    loanButton
                    repaymentButton
                }
                allowanceActionButton
            }
        } else {
            VStack(spacing: EW.Space.three) {
                depositButton
                withdrawalButton
                loanButton
                repaymentButton
                allowanceActionButton
            }
        }
    }

    private var depositButton: some View {
        ActionButton(title: "Add deposit", icon: "arrow.down.circle", tint: EW.Color.primary) { flow = .deposit }
    }

    private var withdrawalButton: some View {
        ActionButton(title: "Record withdrawal", icon: "arrow.up.circle", tint: EW.Color.textSecondary) { flow = .withdrawal }
    }

    private var loanButton: some View {
        ActionButton(title: "Create loan", icon: "hand.raised", tint: EW.Color.peach700) { flow = .loan }
    }

    private var repaymentButton: some View {
        ActionButton(title: "Record repayment", icon: "arrow.triangle.2.circlepath", tint: EW.Color.green700) { flow = .repayment }
    }

    private var allowanceActionButton: some View {
        ActionButton(title: "Record allowance", icon: "gift", tint: EW.Color.gold700) { flow = .allowance }
    }

    private var settingsCard: some View {
        VStack(spacing: 0) {
            if store.canModifyWallet {
                settingsRow(title: "Edit child profile", icon: "person.crop.circle", accessibilityIdentifier: "edit-child-profile-settings") {
                    isShowingEditProfile = true
                }
                Divider().overlay(EW.Color.border)
            }
            settingsRow(title: "Change PIN", icon: "lock.rotation") {
                isShowingChangePIN = true
            }
            Divider().overlay(EW.Color.border)
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

    private func settingsRow(title: String, icon: String, role: ButtonRole? = nil, accessibilityIdentifier: String? = nil, action: @escaping () -> Void) -> some View {
        Button(role: role, action: action) {
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
        .buttonStyle(.plain)
        .accessibilityIdentifier(accessibilityIdentifier ?? title)
    }

    private func stateColor(_ state: SyncState) -> Color {
        switch state {
        case .recorded: EW.Color.green700
        case .pending: EW.Color.gold700
        case .rejected: EW.Color.red600
        case .draft: EW.Color.textSecondary
        }
    }

    private func stateTint(_ state: SyncState) -> Color {
        switch state {
        case .recorded: EW.Color.green100
        case .pending: EW.Color.goldTint
        case .rejected: EW.Color.dangerTint
        case .draft: EW.Color.ink100
        }
    }
}

/// Parent-only editor for the configured child nickname. Uses the same
/// non-empty trimmed validation as first-run setup.
struct EditChildProfileView: View {
    @EnvironmentObject private var store: WalletStore
    @Environment(\.dismiss) private var dismiss
    @State private var nickname = ""
    @State private var didSave = false
    @State private var localError: String?

    private var trimmedNickname: String {
        nickname.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isValid: Bool {
        ChildProfileCopy.configuredNickname(from: nickname) != nil
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: EW.Space.five) {
                    Text("This nickname appears on the Parent area summary and on the child's wallet. It is not a login.")
                        .font(EW.Font.body)
                        .foregroundStyle(EW.Color.textSecondary)

                    VStack(alignment: .leading, spacing: EW.Space.two) {
                        Text("Child nickname")
                            .font(EW.Font.captionUpper)
                            .foregroundStyle(EW.Color.textTertiary)
                        TextField("Child's nickname", text: $nickname)
                            .font(EW.Font.body)
                            .textFieldStyle(.roundedBorder)
                            .frame(minHeight: 44)
                            .accessibilityLabel("Child nickname")
                            .accessibilityIdentifier("child-nickname-field")
                            .onChange(of: nickname) { _, _ in
                                didSave = false
                                localError = nil
                            }
                    }
                    .ewCard()

                    if didSave {
                        Label("Child profile saved.", systemImage: "checkmark.circle.fill")
                            .font(EW.Font.bodyBold)
                            .foregroundStyle(EW.Color.green700)
                    }
                    if let localError {
                        Text(localError)
                            .font(EW.Font.caption)
                            .foregroundStyle(EW.Color.red600)
                    } else if let errorMessage = store.errorMessage, !didSave {
                        Text(errorMessage)
                            .font(EW.Font.caption)
                            .foregroundStyle(EW.Color.red600)
                    }

                    Button {
                        Task {
                            let ok = await store.updateChildProfile(nickname: nickname)
                            didSave = ok
                            localError = ok ? nil : (store.errorMessage ?? "The child profile could not be saved.")
                        }
                    } label: {
                        if store.isLoading {
                            ProgressView()
                                .frame(maxWidth: .infinity, minHeight: 52)
                        } else {
                            Text("Save child profile")
                                .frame(maxWidth: .infinity, minHeight: 52)
                        }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(store.isLoading || !isValid)
                    .opacity(store.isLoading || !isValid ? 0.45 : 1)
                }
                .padding(EW.Space.screenMargin)
                .frame(maxWidth: 620)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .background(EW.Color.appBackground)
            .navigationTitle("Child profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(didSave ? "Done" : "Cancel") { dismiss() }
                }
            }
            .onAppear {
                nickname = store.snapshot.configuredChildNickname ?? ""
            }
        }
    }
}

/// Change the parent PIN with the current PIN, inside the Parent area only.
struct ChangePINView: View {
    @EnvironmentObject private var store: WalletStore
    @Environment(\.dismiss) private var dismiss
    @State private var currentPIN = ""
    @State private var newPIN = ""
    @State private var confirmation = ""
    @State private var errorMessage: String?
    @State private var didSave = false

    private var isValid: Bool {
        currentPIN.count == 4 && newPIN.count == 4 && newPIN == confirmation
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: EW.Space.five) {
                    Text("The parent PIN protects parent controls on this \(DeviceCopy.deviceNoun). Changing it needs the current PIN.")
                        .font(EW.Font.body)
                        .foregroundStyle(EW.Color.textSecondary)

                    VStack(alignment: .leading, spacing: EW.Space.three) {
                        pinField("Current PIN", text: $currentPIN)
                        pinField("New PIN", text: $newPIN)
                        pinField("Confirm new PIN", text: $confirmation)
                    }
                    .ewCard()

                    if didSave {
                        Label("The parent PIN was changed.", systemImage: "checkmark.circle.fill")
                            .font(EW.Font.bodyBold)
                            .foregroundStyle(EW.Color.green700)
                    }
                    if let errorMessage {
                        Text(errorMessage)
                            .font(EW.Font.caption)
                            .foregroundStyle(EW.Color.red600)
                    }

                    Button("Save new PIN") {
                        errorMessage = store.changeParentPIN(current: currentPIN, new: newPIN, confirmation: confirmation)
                        didSave = errorMessage == nil
                        if didSave {
                            currentPIN = ""
                            newPIN = ""
                            confirmation = ""
                        }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(!isValid)
                    .opacity(isValid ? 1 : 0.45)
                }
                .padding(EW.Space.screenMargin)
                .frame(maxWidth: 620)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .background(EW.Color.appBackground)
            .navigationTitle("Change PIN")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(didSave ? "Done" : "Cancel") { dismiss() }
                }
            }
        }
    }

    private func pinField(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: EW.Space.two) {
            Text(title)
                .font(EW.Font.captionUpper)
                .foregroundStyle(EW.Color.textTertiary)
            SecureField("Four digits", text: text)
                .keyboardType(.numberPad)
                .textFieldStyle(.roundedBorder)
                .frame(minHeight: 44)
                .onChange(of: text.wrappedValue) { _, value in
                    text.wrappedValue = String(value.filter(\.isNumber).prefix(4))
                }
                .accessibilityLabel(title)
        }
    }
}

#Preview("Parent area") {
    let store = WalletStore.preview()
    store.openParentGate()
    for digit in "1234" { store.appendPINDigit(String(digit)) }
    return ParentAreaView().environmentObject(store)
}
