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
    @State private var isShowingConnectionDetails = false
    @State private var isConfirmingSignOut = false
    @State private var isConfirmingRecordAllMissedAllowance = false
    @State private var recordAllMissedAllowanceOutcome: AllowanceRecordAllOutcome?

    private var isRegularWidth: Bool { horizontalSizeClass == .regular }

    private var missedAllowancePayouts: AllowanceMissedPayouts {
        store.missedAllowancePayouts
    }

    private var childWalletReference: String {
        ChildProfileCopy.walletReference(nickname: store.snapshot.configuredChildNickname)
    }

    /// VoiceOver hears the same specific reason the block states, never a
    /// blanket "reconnect" for a device that is already connected.
    static func allowanceAccessibilityHint(block: ParentMutationBlock?) -> String {
        guard let block else { return "Opens allowance setup" }
        switch block {
        case .rejectedCleanup: return "Finish local cleanup before changing the allowance"
        case .unsettledMutation: return "Wait for Cloud to confirm the last change before changing the allowance"
        case .replicaUnavailable: return "Reconnect to get the Cloud wallet before changing the allowance"
        case .planInactive: return "The Cloud plan is not active, so the allowance cannot be changed"
        case .awaitingReview: return "Review the latest balance before changing the allowance"
        case .authorityUnreached: return "Reconnect before changing the allowance"
        case .revisionUnconfirmed: return "Refresh the Cloud wallet before changing the allowance"
        }
    }

    /// Shows the first-actions spotlight right after setup, and whenever the
    /// wallet has no recorded activity or allowance rule yet.
    private var showsHandoffCard: Bool {
        store.canStartParentMutation
            && (store.showsFirstActionsHandoff
            || (store.snapshot.activities.isEmpty
                && store.snapshot.pendingEvents.isEmpty
                && store.snapshot.allowance == nil))
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { scroll in
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

                            if !missedAllowancePayouts.isEmpty {
                                missedAllowanceCard
                            }

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
                                if let block = store.parentMutationBlock {
                                    mutationControlsNotice(block, scroll: scroll)
                                }
                                actionGrid
                            }
                        } else {
                            cloudReplicaUnavailableCard
                        }

                        SectionHeader("Cloud")
                            .id(Self.cloudSectionAnchor)
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
                .accessibilityIdentifier("parent-area-scroll")
                .background(EW.Color.appBackground.ignoresSafeArea())
                .navigationTitle("Parent area")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    if !store.isDeletingAccount && !store.hasDeletedAccount {
                        ToolbarItem(placement: .topBarTrailing) {
                            doneButton
                        }
                    }
                }
                .toolbarBackground(EW.Color.green900, for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)
                .toolbarColorScheme(.dark, for: .navigationBar)
                .refreshable {
                    await store.refresh()
                }
            }
        }
        .sheet(item: $selectedEvent) { event in
            ActivityDetailView(event: event)
                .ewDetailSheetPresentation()
        }
        .sheet(isPresented: $isShowingLoan) {
            LoanDetailView(isParent: true, onRepay: {
                isShowingLoan = false
                flow = .repayment
            })
            .ewDetailSheetPresentation()
        }
        .sheet(item: $flow) { kind in
            MoneyFlowView(kind: kind)
                .ewFormSheetPresentation()
        }
        .sheet(isPresented: $isShowingAllowance) {
            AllowanceView()
                .ewFormSheetPresentation()
        }
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
        .confirmationDialog(
            "Pay out \(missedAllowancePayouts.count) missed allowance weeks?",
            isPresented: $isConfirmingRecordAllMissedAllowance,
            titleVisibility: .visible
        ) {
            Button("Pay out all") {
                Task { recordAllMissedAllowanceOutcome = await store.recordAllMissedAllowance() }
            }
            Button("Not now", role: .cancel) {}
        } message: {
            Text("This will add \(missedAllowancePayouts.count) separate allowance entries totaling \(Money(cents: missedAllowancePayouts.totalCents).display). Today's allowance will not be paid out.")
        }
        .alert(recordAllMissedAllowanceAlertTitle, isPresented: Binding(
            get: { recordAllMissedAllowanceOutcome != nil },
            set: { if !$0 { recordAllMissedAllowanceOutcome = nil } }
        )) {
            Button("Done") { recordAllMissedAllowanceOutcome = nil }
        } message: {
            Text(recordAllMissedAllowanceAlertMessage)
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
        "Reconnect this \(deviceNoun) to show the Cloud wallet balance and activity."
    }

    /// This card stands in for the whole wallet, so it is also the block for a
    /// device with no usable replica - and it owes the same reachable way out
    /// every other block carries.
    private var cloudReplicaUnavailableCard: some View {
        VStack(alignment: .leading, spacing: EW.Space.three) {
            Label("Cloud wallet unavailable", systemImage: "icloud.slash")
                .font(EW.Font.heading)
                .foregroundStyle(EW.Color.textPrimary)
            Text(Self.cloudReplicaUnavailableMessage(deviceNoun: DeviceCopy.deviceNoun))
                .font(EW.Font.body)
                .foregroundStyle(EW.Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(ParentMutationBlock.replicaUnavailable.recoveryActionTitle) {
                Task { await store.clearParentMutationBlock() }
            }
            .buttonStyle(.plain)
            .font(EW.Font.bodyBold)
            .foregroundStyle(EW.Color.primaryActive)
            .frame(minHeight: 44, alignment: .leading)
            .disabled(store.isLoading)
            .accessibilityIdentifier("cloud-mutation-block-recovery")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .ewCard(variant: .alt)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("parent-cloud-replica-unavailable")
    }

    /// Balance + allowance pair on top; loan + sync pair below. On regular
    /// widths a lone second-row card spans the full width so the grid never
    /// leaves an orphan gap.
    @ViewBuilder
    private var walletCards: some View {
        let loan = store.snapshot.loan
        let hasPending = !store.snapshot.pendingEvents.isEmpty || store.hasUnsettledCloudMutation
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
                    guard store.canStartParentMutation else { return }
                    isShowingAllowance = true
                } label: {
                    HStack(spacing: EW.Space.two) {
                        allowanceCardContent
                        Image(systemName: "chevron.right")
                            .foregroundStyle(EW.Color.textTertiary)
                    }
                }
                .buttonStyle(.plain)
                .disabled(!store.canStartParentMutation)
                .opacity(store.canStartParentMutation ? 1 : 0.55)
                .accessibilityHint(Self.allowanceAccessibilityHint(block: store.parentMutationBlock))
                .accessibilityIdentifier("parent-allowance-card")
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
                    if let nextDate = allowance.nextCurrentOrFuturePayout() {
                        Text("Starting \(nextDate.formatted(.dateTime.month(.abbreviated).day()))")
                            .font(EW.Font.caption)
                            .foregroundStyle(EW.Color.textTertiary)
                    }
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

    /// A parent-visible ledger of all already-past-due weekly occurrences.
    /// The action deliberately settles only this list: today remains the
    /// ordinary next allowance and is never auto-recorded by this control.
    private var missedAllowanceCard: some View {
        VStack(alignment: .leading, spacing: EW.Space.three) {
            HStack(alignment: .firstTextBaseline) {
                Label("Missed allowance", systemImage: "calendar.badge.exclamationmark")
                    .font(EW.Font.headingSmall)
                    .foregroundStyle(EW.Color.textPrimary)
                Spacer()
                Text("\(missedAllowancePayouts.count) missed weeks")
                    .font(EW.Font.caption)
                    .foregroundStyle(EW.Color.textSecondary)
            }
            VStack(spacing: 0) {
                ForEach(missedAllowancePayouts.occurrences) { occurrence in
                    HStack {
                        Text(occurrence.dueDate.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                            .font(EW.Font.body)
                            .foregroundStyle(EW.Color.textPrimary)
                        Spacer()
                        MoneyAmount(cents: occurrence.amountCents, font: EW.Font.bodyBold)
                    }
                    .frame(minHeight: 44)
                    if occurrence.id != missedAllowancePayouts.occurrences.last?.id {
                        Divider().overlay(EW.Color.border)
                    }
                }
            }
            .padding(.horizontal, EW.Space.three)
            .background(EW.Color.card, in: RoundedRectangle(cornerRadius: EW.Radius.medium, style: .continuous))
            HStack {
                Text("Owed total")
                    .font(EW.Font.bodyBold)
                    .foregroundStyle(EW.Color.textPrimary)
                Spacer()
                MoneyAmount(cents: missedAllowancePayouts.totalCents, font: EW.Font.heading)
            }
            ActionButton(
                title: "Pay out missed allowance",
                icon: "gift.fill",
                tint: EW.Color.gold700,
                isEnabled: store.canStartParentMutation && !store.isRecordingMissedAllowance
            ) {
                isConfirmingRecordAllMissedAllowance = true
            }
            .accessibilityIdentifier("record-all-missed-allowance")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .ewCard(variant: .alt)
        .accessibilityIdentifier("missed-allowance-card")
    }

    private var recordAllMissedAllowanceAlertTitle: String {
        switch recordAllMissedAllowanceOutcome {
        case .recorded: "Missed allowances paid out"
        case .partial: "Some missed allowances were paid out"
        case .noMissed, nil: "No missed allowances"
        }
    }

    private var recordAllMissedAllowanceAlertMessage: String {
        switch recordAllMissedAllowanceOutcome {
        case .recorded(let count, let totalCents):
            "Paid out \(count) separate allowance entries totaling \(Money(cents: totalCents).display)."
        case .partial(let recordedCount, let recordedTotalCents, let remaining):
            "Paid out \(recordedCount) allowance entries totaling \(Money(cents: recordedTotalCents).display). \(remaining.count) missed weeks remain and can be paid out after reviewing the latest wallet."
        case .noMissed:
            "There are no past-due allowance weeks to pay out."
        case nil:
            ""
        }
    }

    /// The block that disables the money controls, stated as the guard that is
    /// actually holding and shipped with the control that clears it.
    ///
    /// The recovery is not optional garnish. Before it existed, a block whose
    /// reason was not a pending review put the parent in a dead end: the
    /// generic notice named nothing to do, and the Cloud card's `Got it`
    /// - the only clear on the screen - is shown for a pending review alone.
    /// Every case now answers with its own way out, on the block itself.
    private func mutationControlsNotice(_ block: ParentMutationBlock, scroll: ScrollViewProxy) -> some View {
        let isTerminal = block == .rejectedCleanup
        return VStack(alignment: .leading, spacing: EW.Space.two) {
            HStack(alignment: .top, spacing: EW.Space.three) {
                Image(systemName: Self.noticeSymbol(block))
                    .foregroundStyle(isTerminal ? EW.Color.red600 : EW.Color.gold700)
                Text(Self.noticeMessage(block, unsettled: store.unsettledCloudMutationMessage))
                    .font(EW.Font.caption)
                    .foregroundStyle(EW.Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(block.recoveryActionTitle) {
                switch block.recovery {
                case .readLatest:
                    Task { await store.clearParentMutationBlock() }
                case .cloudPlan:
                    withAnimation { scroll.scrollTo(Self.cloudSectionAnchor, anchor: .top) }
                }
            }
            .buttonStyle(.plain)
            .font(EW.Font.bodyBold)
            .foregroundStyle(EW.Color.primaryActive)
            .frame(minHeight: 44, alignment: .leading)
            .disabled(store.isLoading)
            .accessibilityIdentifier("cloud-mutation-block-recovery")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(EW.Space.three)
        .background(isTerminal ? EW.Color.dangerTint : EW.Color.goldTint, in: RoundedRectangle(cornerRadius: EW.Radius.medium, style: .continuous))
        // A container identifier alone would override the recovery control's
        // own, and the control is the point of the notice.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("cloud-mutation-controls-notice")
    }

    private static let cloudSectionAnchor = "parent-cloud-section"

    /// An unresolved request describes itself best - it knows which phase it is
    /// in. Every other block states its own reason.
    private static func noticeMessage(_ block: ParentMutationBlock, unsettled: String?) -> String {
        switch block {
        case .rejectedCleanup, .unsettledMutation:
            unsettled ?? block.message(deviceNoun: DeviceCopy.deviceNoun)
        default:
            block.message(deviceNoun: DeviceCopy.deviceNoun)
        }
    }

    private static func noticeSymbol(_ block: ParentMutationBlock) -> String {
        switch block {
        case .rejectedCleanup: "xmark.circle.fill"
        case .unsettledMutation: "clock.fill"
        case .awaitingReview: "arrow.triangle.2.circlepath"
        case .planInactive: "exclamationmark.icloud"
        case .replicaUnavailable, .authorityUnreached, .revisionUnconfirmed: "icloud.slash"
        }
    }

    /// A readout, not a place to act. The control that clears any of these
    /// states lives on the block that disables the money controls, so there is
    /// exactly one way out and it sits where the parent was stopped - never a
    /// second copy of the same action on another card, which VoiceOver and a
    /// tap target both read as ambiguous.
    private var syncStatusCard: some View {
        VStack(alignment: .leading, spacing: EW.Space.three) {
            Label(
                store.hasRejectedCloudMutationCleanup ? "Cloud cleanup" : "Sync status",
                systemImage: store.hasRejectedCloudMutationCleanup ? "xmark.circle" : "arrow.triangle.2.circlepath"
            )
                .font(EW.Font.headingSmall)
                .foregroundStyle(EW.Color.textPrimary)
            if store.hasRejectedCloudMutationCleanup {
                VStack(alignment: .leading, spacing: EW.Space.two) {
                    StatusPill(state: .rejected)
                    Text("Not recorded")
                        .font(EW.Font.bodyBold)
                        .foregroundStyle(EW.Color.textPrimary)
                    Text("This change was not recorded. Finish local cleanup on this \(DeviceCopy.deviceNoun) before recording another action.")
                        .font(EW.Font.caption)
                        .foregroundStyle(EW.Color.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityIdentifier("cloud-rejected-cleanup-status")
            } else if let message = store.unsettledCloudMutationMessage {
                VStack(alignment: .leading, spacing: EW.Space.two) {
                    StatusPill(state: .pending)
                    Text(store.unsettledCloudMutationWasAccepted ? "Accepted by Cloud" : "Checking with Cloud")
                        .font(EW.Font.bodyBold)
                        .foregroundStyle(EW.Color.textPrimary)
                    Text(message)
                        .font(EW.Font.caption)
                        .foregroundStyle(EW.Color.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityIdentifier("cloud-mutation-status")
            }
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
        ActionButton(title: "Add deposit", icon: "arrow.down.circle", tint: EW.Color.primary, isEnabled: store.canStartParentMutation) { flow = .deposit }
    }

    private var withdrawalButton: some View {
        ActionButton(title: "Record withdrawal", icon: "arrow.up.circle", tint: EW.Color.textSecondary, isEnabled: store.canStartParentMutation) { flow = .withdrawal }
    }

    private var loanButton: some View {
        ActionButton(title: "Create loan", icon: "hand.raised", tint: EW.Color.peach700, isEnabled: store.canStartParentMutation) { flow = .loan }
    }

    private var repaymentButton: some View {
        ActionButton(title: "Record repayment", icon: "arrow.triangle.2.circlepath", tint: EW.Color.green700, isEnabled: store.canStartParentMutation) { flow = .repayment }
    }

    private var allowanceActionButton: some View {
        ActionButton(title: "Pay out allowance", icon: "gift", tint: EW.Color.gold700, isEnabled: store.canStartParentMutation) { flow = .allowance }
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
    @State private var mutationOutcome: ParentMutationOutcome?

    private var trimmedNickname: String {
        nickname.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isValid: Bool {
        ChildProfileCopy.configuredNickname(from: nickname) != nil
    }

    var body: some View {
        NavigationStack {
            SheetForm {
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
                                mutationOutcome = nil
                            }
                    }
                    .ewCard()

                    if didSave {
                        Label("Child profile saved.", systemImage: "checkmark.circle.fill")
                            .font(EW.Font.bodyBold)
                            .foregroundStyle(EW.Color.green700)
                    } else if let mutationOutcome,
                              mutationOutcome == .waitingForCloud || mutationOutcome == .acceptedAwaitingReplica {
                        VStack(alignment: .leading, spacing: EW.Space.two) {
                            StatusPill(state: .pending)
                            Text(mutationOutcome.message)
                                .font(EW.Font.caption)
                                .foregroundStyle(EW.Color.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .accessibilityIdentifier("child-profile-cloud-waiting")
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
                }
            } actions: {
                Button {
                    Task {
                        let ok = await store.updateChildProfile(nickname: nickname)
                        mutationOutcome = store.latestParentMutationOutcome
                        didSave = ok && mutationOutcome == .recorded
                        if mutationOutcome == .waitingForCloud || mutationOutcome == .acceptedAwaitingReplica {
                            localError = nil
                        } else {
                            localError = didSave ? nil : (store.errorMessage ?? "The child profile could not be saved.")
                        }
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
                .disabled(store.isLoading || !isValid || !store.canStartParentMutation || mutationOutcome == .waitingForCloud || mutationOutcome == .acceptedAwaitingReplica)
                .opacity(store.isLoading || !isValid || !store.canStartParentMutation || mutationOutcome == .waitingForCloud || mutationOutcome == .acceptedAwaitingReplica ? 0.45 : 1)
            }
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
            SheetForm {
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
                }
            } actions: {
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
