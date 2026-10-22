import SwiftUI

/// Where the Parent area's navigation can go from its one scroll.
enum ParentRoute: Hashable {
    /// Cloud, child profile, PIN, connection details, sign-out and deletion.
    case settings
    /// The whole activity history, past the five rows kept on the wallet.
    case allActivity
}

/// The transient, visibly distinct parent administrative area. Presented as a
/// full-screen cover over the kid home while elevation is active, with an
/// unmistakable header and an explicit exit.
///
/// The screen is one scroll in the order a parent needs it: the balance, the
/// four money actions directly under it, anything that needs attention (a
/// write block with its own way out, missed allowance, loan payments, an
/// unsettled Cloud change), the plans, and the five most recent activity rows
/// with the rest one tap away. Cloud, profile, PIN, connection details,
/// sign-out and account deletion live on `ParentSettingsView` behind the gear,
/// so nothing a parent came to do sits below the fold however long the
/// history grows.
struct ParentAreaView: View {
    @EnvironmentObject private var store: WalletStore
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var path = NavigationPath()
    @State private var selectedEvent: WalletEvent?
    @State private var isShowingLoan = false
    @State private var flow: MoneyFlowKind?
    @State private var isShowingAllowance = false
    /// A one-line confirmation of the last change made from a sheet, shown at
    /// the top of the scroll for a few seconds in place of a second screen.
    @State private var confirmation: String?
    @State private var confirmationTask: Task<Void, Never>?
    /// A failure already shown inside the sheet that produced it is not shown
    /// a second time as a banner once that sheet closes.
    @State private var acknowledgedErrorMessage: String?
    @State private var isConfirmingRecordAllMissedAllowance = false
    @State private var confirmedMissedAllowancePayouts: AllowanceMissedPayouts?
    @State private var recordAllMissedAllowanceOutcome: AllowanceRecordAllOutcome?
    @State private var isConfirmingRecordAllMissedLoanInstallments = false
    @State private var confirmedMissedLoanInstallments: LoanMissedInstallments?
    @State private var recordAllMissedLoanInstallmentsOutcome: LoanRecordAllOutcome?
    @State private var isConfirmingRecordLoanInstallment = false
    @State private var recordLoanInstallmentOutcome: SyncState?

    private var isRegularWidth: Bool { horizontalSizeClass == .regular }

    private var missedAllowancePayouts: AllowanceMissedPayouts {
        store.missedAllowancePayouts
    }

    private var missedLoanInstallments: LoanMissedInstallments {
        store.missedLoanInstallments
    }

    /// Only a loan that was created with a plan has payment days at all. A
    /// scheduleless loan keeps the one-shot repayment path and shows nothing
    /// here.
    private var hasScheduledLoan: Bool {
        store.snapshot.loan.map { $0.schedule != nil && !$0.isPaid } ?? false
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

    /// How many activity rows stay on the wallet before the rest move behind
    /// a See all link, so the actions above never sink as history grows.
    static let recentActivityLimit = 5

    private var visibleErrorMessage: String? {
        guard let errorMessage = store.errorMessage, errorMessage != acknowledgedErrorMessage else { return nil }
        return errorMessage
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: EW.Space.six) {
                    if let confirmation {
                        Label(confirmation, systemImage: "checkmark.circle.fill")
                            .font(EW.Font.caption)
                            .foregroundStyle(EW.Color.green700)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(EW.Space.three)
                            .background(EW.Color.green100, in: RoundedRectangle(cornerRadius: EW.Radius.medium, style: .continuous))
                            .accessibilityIdentifier("parent-confirmation")
                    }
                    if let errorMessage = visibleErrorMessage {
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

                        balanceCard

                        if store.canModifyWallet {
                            actionTiles
                            if let block = store.parentMutationBlock {
                                mutationControlsNotice(block)
                            }
                        }

                        if !missedAllowancePayouts.isEmpty {
                            missedAllowanceCard
                        }

                        if hasScheduledLoan {
                            loanPaymentsCard
                        }

                        if hasPendingCloudWork {
                            syncStatusCard
                        }

                        SectionHeader("Plans")
                        plansCards

                        SectionHeader("Recent activity")
                        recentActivity
                    } else {
                        cloudReplicaUnavailableCard
                    }
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
                    ToolbarItem(placement: .topBarLeading) {
                        settingsButton
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        doneButton
                    }
                }
            }
            .toolbarBackground(EW.Color.green900, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .navigationDestination(for: ParentRoute.self) { route in
                switch route {
                case .settings: ParentSettingsView()
                case .allActivity: ParentActivityListView()
                }
            }
            .refreshable {
                await store.refresh()
            }
        }
        .sheet(item: $selectedEvent) { event in
            ActivityDetailView(event: event, childNickname: store.snapshot.configuredChildNickname)
                .ewDetailSheetPresentation()
        }
        .sheet(isPresented: $isShowingLoan) {
            LoanDetailView(isParent: true, onRepay: {
                isShowingLoan = false
                flow = .repayment
            })
            .ewDetailSheetPresentation()
        }
        .sheet(item: $flow, onDismiss: acknowledgeSheetFailure) { kind in
            MoneyFlowView(kind: kind)
                .ewFormSheetPresentation()
        }
        .sheet(isPresented: $isShowingAllowance, onDismiss: acknowledgeSheetFailure) {
            AllowanceView { summary in
                showConfirmation("Allowance is now \(summary).")
            }
            .ewFormSheetPresentation()
        }
        .confirmationDialog(
            "Pay out \(confirmedMissedAllowancePayouts?.count ?? 0) missed allowance weeks?",
            isPresented: $isConfirmingRecordAllMissedAllowance,
            titleVisibility: .visible
        ) {
            Button("Pay out all") {
                guard let confirmedMissedAllowancePayouts else { return }
                self.confirmedMissedAllowancePayouts = nil
                Task {
                    recordAllMissedAllowanceOutcome = await store.recordAllMissedAllowance(confirmedMissedAllowancePayouts)
                }
            }
            Button("Not now", role: .cancel) {
                confirmedMissedAllowancePayouts = nil
            }
        } message: {
            let confirmed = confirmedMissedAllowancePayouts ?? AllowanceMissedPayouts(occurrences: [])
            Text("This will add \(confirmed.count) separate allowance entries totaling \(Money(cents: confirmed.totalCents).display). Today's allowance will not be paid out.")
        }
        .alert(recordAllMissedAllowanceAlertTitle, isPresented: Binding(
            get: { recordAllMissedAllowanceOutcome != nil },
            set: { if !$0 { recordAllMissedAllowanceOutcome = nil } }
        )) {
            Button("Done") { recordAllMissedAllowanceOutcome = nil }
        } message: {
            Text(recordAllMissedAllowanceAlertMessage)
        }
        .confirmationDialog(
            "Pay \(confirmedMissedLoanInstallments?.count ?? 0) missed loan payments?",
            isPresented: $isConfirmingRecordAllMissedLoanInstallments,
            titleVisibility: .visible
        ) {
            Button("Pay all") {
                guard let confirmedMissedLoanInstallments else { return }
                self.confirmedMissedLoanInstallments = nil
                Task {
                    recordAllMissedLoanInstallmentsOutcome = await store.recordAllMissedLoanInstallments(confirmedMissedLoanInstallments)
                }
            }
            Button("Not now", role: .cancel) {
                confirmedMissedLoanInstallments = nil
            }
        } message: {
            let confirmed = confirmedMissedLoanInstallments ?? LoanMissedInstallments(installments: [])
            Text("This pays \(confirmed.count) separate payments totaling \(Money(cents: confirmed.totalCents).display) toward the loan. The next payment is not included.")
        }
        .alert(recordAllMissedLoanInstallmentsAlertTitle, isPresented: Binding(
            get: { recordAllMissedLoanInstallmentsOutcome != nil },
            set: { if !$0 { recordAllMissedLoanInstallmentsOutcome = nil } }
        )) {
            Button("Done") { recordAllMissedLoanInstallmentsOutcome = nil }
        } message: {
            Text(recordAllMissedLoanInstallmentsAlertMessage)
        }
        .confirmationDialog(
            "Pay this loan payment?",
            isPresented: $isConfirmingRecordLoanInstallment,
            titleVisibility: .visible
        ) {
            // Deliberately not the card button's own words: the batch dialog
            // confirms with "Pay all", so its singular counterpart is "Pay".
            // Sharing a label with the control that opened the dialog also
            // leaves two identical buttons on screen at once.
            Button("Pay") {
                guard let next = store.nextLoanInstallment else { return }
                Task {
                    let result = await store.submit(WalletCommand(kind: .loanInstallment, amountCents: next.amountCents))
                    recordLoanInstallmentOutcome = switch result {
                    case .accepted, .acceptedScheduleUnavailable: SyncState.recorded
                    case .pending, .acceptedAwaitingReplica: SyncState.pending
                    case .rejected: SyncState.rejected
                    }
                }
            }
            Button("Not now", role: .cancel) {}
        } message: {
            let next = store.nextLoanInstallment
            Text("This pays \(Money(cents: next?.amountCents ?? 0).display) toward the loan for the payment due \(next.map { $0.dueDate.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()) } ?? "").")
        }
        .alert("Loan payment", isPresented: Binding(
            get: { recordLoanInstallmentOutcome != nil },
            set: { if !$0 { recordLoanInstallmentOutcome = nil } }
        )) {
            Button("Done") { recordLoanInstallmentOutcome = nil }
        } message: {
            Text(recordLoanInstallmentAlertMessage)
        }
    }

    /// A sheet shows its own failure, so the banner at the top of the scroll
    /// does not repeat it after the sheet closes. A later failure still shows.
    private func acknowledgeSheetFailure() {
        acknowledgedErrorMessage = store.errorMessage
    }

    private func showConfirmation(_ message: String) {
        confirmationTask?.cancel()
        withAnimation { confirmation = message }
        confirmationTask = Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation { confirmation = nil }
        }
    }

    /// Cloud, child profile, PIN, connection details, sign-out and deletion
    /// sit on their own screen behind this gear, off the money scroll.
    private var settingsButton: some View {
        Button {
            path.append(ParentRoute.settings)
        } label: {
            Image(systemName: "gearshape.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(EW.Color.cream50)
                .frame(width: 36, height: 36)
                .background(EW.Color.cream50.opacity(0.16), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Settings")
        .accessibilityIdentifier("parent-settings")
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

    private var hasPendingCloudWork: Bool {
        !store.snapshot.pendingEvents.isEmpty || store.hasUnsettledCloudMutation
    }

    /// The four things a parent comes here to do, directly under the balance.
    /// The loan tile follows the wallet: it creates a loan while none is open
    /// and pays toward the open one otherwise, so neither action is offered
    /// when it would only fail. All four disable together behind the one
    /// write guard, and the block below them says why and carries the way out.
    @ViewBuilder
    private var actionTiles: some View {
        if isRegularWidth {
            HStack(alignment: .top, spacing: EW.Space.three) {
                depositTile
                withdrawalTile
                loanTile
                allowanceTile
            }
            .fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(spacing: EW.Space.three) {
                HStack(alignment: .top, spacing: EW.Space.three) {
                    depositTile
                    withdrawalTile
                }
                .fixedSize(horizontal: false, vertical: true)
                HStack(alignment: .top, spacing: EW.Space.three) {
                    loanTile
                    allowanceTile
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var depositTile: some View {
        ActionTile(
            title: "Add deposit",
            detail: "Add pretend dollars",
            icon: "arrow.down",
            tint: EW.Color.green600,
            background: EW.Color.green100,
            isEnabled: store.canStartParentMutation
        ) { flow = .deposit }
    }

    private var withdrawalTile: some View {
        ActionTile(
            title: "Record withdrawal",
            detail: "Record dollars used",
            icon: "arrow.up",
            tint: EW.Color.ink700,
            background: EW.Color.ink100,
            isEnabled: store.canStartParentMutation
        ) { flow = .withdrawal }
    }

    @ViewBuilder
    private var loanTile: some View {
        if let loan = store.snapshot.loan, !loan.isPaid {
            ActionTile(
                title: "Pay toward loan",
                detail: "\(Money(cents: loan.remainingCents).display) left to repay",
                icon: "arrow.triangle.2.circlepath",
                tint: EW.Color.peach600,
                background: EW.Color.peach100,
                isEnabled: store.canStartParentMutation
            ) { flow = .repayment }
        } else {
            ActionTile(
                title: "Create loan",
                detail: "Give now, repay later",
                icon: "hand.raised",
                tint: EW.Color.peach600,
                background: EW.Color.peach100,
                isEnabled: store.canStartParentMutation
            ) { flow = .loan }
        }
    }

    private var allowanceTile: some View {
        ActionTile(
            title: "Allowance",
            detail: store.snapshot.allowance.flatMap { $0.isExhausted ? nil : $0 }
                .map { AllowanceCopy.summary(amountCents: $0.amountCents, weekday: $0.weekday) }
                ?? "Set a weekly plan",
            icon: "gift",
            tint: EW.Color.gold600,
            background: EW.Color.goldTint,
            isEnabled: store.canStartParentMutation
        ) { isShowingAllowance = true }
        .accessibilityIdentifier("parent-action-allowance")
    }

    /// The next allowance and the open loan. On regular widths they share a
    /// row; a lone card spans the full width so the grid never leaves a gap.
    @ViewBuilder
    private var plansCards: some View {
        let loan = store.snapshot.loan
        if isRegularWidth, let loan {
            HStack(alignment: .top, spacing: EW.Space.five) {
                allowanceCard.frame(maxWidth: .infinity)
                LoanCardView(loan: loan, isParent: true) { isShowingLoan = true }
                    .frame(maxWidth: .infinity)
            }
            .fixedSize(horizontal: false, vertical: true)
        } else {
            allowanceCard
            if let loan {
                LoanCardView(loan: loan, isParent: true) { isShowingLoan = true }
            }
        }
    }

    /// Five rows, then the rest behind See all, so the actions above never
    /// sink as the history grows. The full list is a continuation of this
    /// one, not a second activity entry point.
    @ViewBuilder
    private var recentActivity: some View {
        let activities = store.snapshot.activities
        if activities.isEmpty {
            Text("Nothing recorded yet. Add a first deposit or set the weekly allowance.")
                .font(EW.Font.body)
                .foregroundStyle(EW.Color.textSecondary)
        } else {
            let shown = Array(activities.prefix(Self.recentActivityLimit))
            ActivityListCard(
                events: shown,
                childRecorderName: ActivityDetailCopy.childRecorderName(audience: .parent, nickname: store.snapshot.configuredChildNickname),
                seeAllTitle: activities.count > shown.count ? "See all \(activities.count) entries" : nil,
                onSeeAll: { path.append(ParentRoute.allActivity) }
            ) { event in
                selectedEvent = event
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
                    Text(AllowanceCopy.summary(amountCents: allowance.amountCents, weekday: allowance.weekday))
                        .font(EW.Font.body)
                        .foregroundStyle(EW.Color.textSecondary)
                    if let nextDate = allowance.nextCurrentOrFuturePayout() {
                        Text(nextDate.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
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
                confirmedMissedAllowancePayouts = missedAllowancePayouts
                isConfirmingRecordAllMissedAllowance = true
            }
            .accessibilityIdentifier("record-all-missed-allowance")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .ewCard(variant: .alt)
        .accessibilityIdentifier("missed-allowance-card")
    }

    /// The one place a parent settles a scheduled loan. The reminder names the
    /// next payment and the day it is due; the missed list below it is every
    /// payment day that has already passed. The two controls are deliberately
    /// separate: the catch-up settles exactly the listed past-due payments, and
    /// the next payment stays on its own single-record path so a tap can never
    /// record a payment that is not owed yet.
    private var loanPaymentsCard: some View {
        VStack(alignment: .leading, spacing: EW.Space.three) {
            HStack(alignment: .firstTextBaseline) {
                Label("Loan payments", systemImage: "calendar.badge.clock")
                    .font(EW.Font.headingSmall)
                    .foregroundStyle(EW.Color.textPrimary)
                Spacer()
                Text(loanCadenceDescription)
                    .font(EW.Font.caption)
                    .foregroundStyle(EW.Color.textSecondary)
            }

            if let next = store.nextLoanInstallment {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: EW.Space.one) {
                        Text("Next payment")
                            .font(EW.Font.captionUpper)
                            .foregroundStyle(EW.Color.textTertiary)
                        Text(next.dueDate.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                            .font(EW.Font.body)
                            .foregroundStyle(EW.Color.textPrimary)
                    }
                    Spacer(minLength: EW.Space.four)
                    MoneyAmount(cents: next.amountCents, font: EW.Font.heading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(EW.Space.three)
                .background(EW.Color.card, in: RoundedRectangle(cornerRadius: EW.Radius.medium, style: .continuous))
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("loan-next-payment")
            }

            if !missedLoanInstallments.isEmpty {
                HStack(alignment: .firstTextBaseline) {
                    Text("Missed payments")
                        .font(EW.Font.bodyBold)
                        .foregroundStyle(EW.Color.textPrimary)
                    Spacer()
                    Text("\(missedLoanInstallments.count) missed")
                        .font(EW.Font.caption)
                        .foregroundStyle(EW.Color.textSecondary)
                }
                VStack(spacing: 0) {
                    ForEach(missedLoanInstallments.installments) { installment in
                        HStack {
                            Text(installment.dueDate.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                                .font(EW.Font.body)
                                .foregroundStyle(EW.Color.textPrimary)
                            Spacer()
                            MoneyAmount(cents: installment.amountCents, font: EW.Font.bodyBold)
                        }
                        .frame(minHeight: 44)
                        if installment.id != missedLoanInstallments.installments.last?.id {
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
                    MoneyAmount(cents: missedLoanInstallments.totalCents, font: EW.Font.heading)
                }
                ActionButton(
                    title: "Pay missed payments",
                    icon: "arrow.triangle.2.circlepath",
                    tint: EW.Color.peach700,
                    isEnabled: store.canStartParentMutation && !store.isRecordingMissedLoanInstallments
                ) {
                    confirmedMissedLoanInstallments = missedLoanInstallments
                    isConfirmingRecordAllMissedLoanInstallments = true
                }
                .accessibilityIdentifier("pay-missed-loan-payments")
            } else if let next = store.nextLoanInstallment, next.dueDate <= Calendar.current.startOfDay(for: .now) {
                ActionButton(
                    title: "Pay this payment",
                    icon: "arrow.triangle.2.circlepath",
                    tint: EW.Color.peach700,
                    isEnabled: store.canStartParentMutation
                ) {
                    isConfirmingRecordLoanInstallment = true
                }
                .accessibilityIdentifier("pay-loan-payment")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .ewCard(variant: .alt)
        .accessibilityIdentifier("loan-payments-card")
    }

    private var loanCadenceDescription: String {
        guard let schedule = store.snapshot.loan?.schedule else { return "" }
        let amount = Money(cents: schedule.amountCents).display
        return switch schedule.cadence {
        case .weekly: "\(amount) every week"
        case .monthly: "\(amount) every month"
        }
    }

    private var recordAllMissedLoanInstallmentsAlertTitle: String {
        switch recordAllMissedLoanInstallmentsOutcome {
        case .recorded: "Missed payments paid"
        case .awaitingCloud: "Cloud is confirming the payment"
        case .reviewRequired: "Review the latest loan"
        case .partial: "Missed payments paid"
        case .noMissed, nil: "No missed payments"
        }
    }

    private var recordAllMissedLoanInstallmentsAlertMessage: String {
        switch recordAllMissedLoanInstallmentsOutcome {
        case .recorded(let count, let totalCents):
            "Paid \(count) separate payments totaling \(Money(cents: totalCents).display) toward the loan."
        case .awaitingCloud(let recordedCount, let recordedTotalCents):
            if recordedCount == 0 {
                "Cloud has the payment request. Refresh to confirm the latest loan before paying anything else."
            } else {
                "Paid \(recordedCount) payments totaling \(Money(cents: recordedTotalCents).display). Cloud is confirming the next payment. Refresh before paying anything else."
            }
        case .reviewRequired(let recordedCount, let recordedTotalCents):
            if recordedCount == 0 {
                "The loan payments changed. Review the latest wallet before paying missed payments."
            } else {
                "Paid \(recordedCount) payments totaling \(Money(cents: recordedTotalCents).display). The loan payments changed. Review the latest wallet before paying more."
            }
        case .partial(let recordedCount, let recordedTotalCents, let remaining):
            "Paid \(recordedCount) payments totaling \(Money(cents: recordedTotalCents).display). \(remaining.count) missed payments remain and can be paid after reviewing the latest wallet."
        case .noMissed:
            "There are no past-due loan payments to pay."
        case nil:
            ""
        }
    }

    private var recordLoanInstallmentAlertMessage: String {
        switch recordLoanInstallmentOutcome {
        case .recorded: "Paid this payment toward the loan."
        case .pending: "Cloud has the payment request. Refresh before paying anything else."
        case .rejected, .draft, nil: "This payment was not made and did not change the accepted balance."
        }
    }

    private var recordAllMissedAllowanceAlertTitle: String {
        switch recordAllMissedAllowanceOutcome {
        case .recorded: "Missed allowances paid out"
        case .awaitingCloud: "Cloud is confirming the payout"
        case .scheduleUnavailable: "Refresh the allowance schedule"
        case .reviewRequired: "Review the latest allowance"
        case .partial: "Some missed allowances were paid out"
        case .noMissed, nil: "No missed allowances"
        }
    }

    private var recordAllMissedAllowanceAlertMessage: String {
        switch recordAllMissedAllowanceOutcome {
        case .recorded(let count, let totalCents):
            "Paid out \(count) separate allowance entries totaling \(Money(cents: totalCents).display)."
        case .awaitingCloud(let recordedCount, let recordedTotalCents):
            if recordedCount == 0 {
                "Cloud has the payout request. Refresh to confirm the latest allowance schedule before paying out anything else."
            } else {
                "Paid out \(recordedCount) allowance entries totaling \(Money(cents: recordedTotalCents).display). Cloud is confirming the next payout. Refresh before paying out anything else."
            }
        case .scheduleUnavailable(let recordedCount, let recordedTotalCents):
            "Paid out \(recordedCount) allowance entries totaling \(Money(cents: recordedTotalCents).display). Cloud could not load the latest allowance schedule. Refresh before paying out anything else."
        case .reviewRequired(let recordedCount, let recordedTotalCents):
            if recordedCount == 0 {
                "The allowance schedule changed. Review the latest wallet before paying out missed weeks."
            } else {
                "Paid out \(recordedCount) allowance entries totaling \(Money(cents: recordedTotalCents).display). The allowance schedule changed. Review the latest wallet before paying out more."
            }
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
    private func mutationControlsNotice(_ block: ParentMutationBlock) -> some View {
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
                    path.append(ParentRoute.settings)
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
