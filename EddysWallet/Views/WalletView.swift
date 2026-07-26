import SwiftUI

struct WalletView: View {
    @EnvironmentObject private var store: WalletStore
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var selectedEvent: WalletEvent?
    @State private var isShowingLoan = false
    @State private var isShowingLesson = false
    @State private var flow: MoneyFlowKind?
    @State private var isShowingAllowance = false

    private var columns: [GridItem] {
        horizontalSizeClass == .regular
            ? [GridItem(.flexible(), spacing: EW.Space.five), GridItem(.flexible(), spacing: EW.Space.five)]
            : [GridItem(.flexible())]
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: EW.Space.six) {
                    roleSwitcher
                    if let errorMessage = store.errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .font(EW.Font.caption)
                            .foregroundStyle(EW.Color.red600)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(EW.Space.three)
                            .background(EW.Color.dangerTint, in: RoundedRectangle(cornerRadius: EW.Radius.medium, style: .continuous))
                    }
                    if store.role == .parent {
                        parentWallet
                    } else {
                        childWallet
                    }
                }
                .padding(.horizontal, EW.Space.screenMargin)
                .padding(.top, EW.Space.two)
                .padding(.bottom, EW.Space.ten)
                .frame(maxWidth: 980)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .background(EW.Color.appBackground.ignoresSafeArea())
            .navigationTitle(ChildProfileCopy.walletTitle(nickname: store.snapshot.configuredChildNickname))
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Sign out", systemImage: "rectangle.portrait.and.arrow.right") {
                            store.signOut()
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .foregroundStyle(EW.Color.textSecondary)
                    }
                    .accessibilityLabel("Wallet menu")
                }
            }
        }
        .task(id: store.role) {
            await store.refresh()
        }
        .refreshable {
            await store.refresh()
        }
        .sheet(item: $selectedEvent) { event in
            ActivityDetailView(event: event)
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $isShowingLoan) {
            LoanDetailView(isParent: store.role == .parent, onRepay: {
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
        .sheet(isPresented: $isShowingLesson) {
            LessonView()
                .presentationDetents([.large])
        }
        .sheet(isPresented: $store.isShowingPinGate) {
            PinGateView()
                .presentationDetents([.medium, .large])
                .interactiveDismissDisabled(false)
        }
    }

    private var roleSwitcher: some View {
        HStack {
            RoleSwitcher(
                role: Binding(get: { store.role }, set: { store.switchRole(to: $0) }),
                childTitle: ChildProfileCopy.roleTitle(nickname: store.snapshot.configuredChildNickname)
            ) { nextRole in
                store.switchRole(to: nextRole)
            }
            Spacer()
            if store.role == .child {
                Label("Read-only", systemImage: "eye")
                    .font(EW.Font.caption)
                    .foregroundStyle(EW.Color.textSecondary)
            }
        }
    }

    @ViewBuilder
    private var parentWallet: some View {
        VStack(alignment: .leading, spacing: EW.Space.six) {
            LazyVGrid(columns: columns, alignment: .leading, spacing: EW.Space.five) {
                parentBalanceCard
                allowanceCard
                if let loan = store.snapshot.loan {
                    LoanCardView(loan: loan, isParent: true) {
                        isShowingLoan = true
                    }
                }
            }

            if !store.snapshot.pendingEvents.isEmpty {
                syncStatusCard
            }

            SectionHeader("Recent activity")
            activityCard

            SectionHeader("Parent actions")
            actionGrid
        }
    }

    @ViewBuilder
    private var childWallet: some View {
        VStack(alignment: .leading, spacing: EW.Space.six) {
            childBalanceCard
            LazyVGrid(columns: columns, alignment: .leading, spacing: EW.Space.five) {
                if let loan = store.snapshot.loan {
                    LoanCardView(loan: loan, isParent: false) {
                        isShowingLoan = true
                    }
                }
                nextLessonCard
            }
            SectionHeader("What's been happening")
            activityCard
            FreshnessLabel(date: store.snapshot.lastUpdated, isStale: store.snapshot.isStale)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var parentBalanceCard: some View {
        VStack(alignment: .leading, spacing: EW.Space.three) {
            Text(ChildProfileCopy.parentBalanceTitle(nickname: store.snapshot.configuredChildNickname))
                .font(EW.Font.captionUpper)
                .foregroundStyle(EW.Color.textTertiary)
                .textCase(.uppercase)
            MoneyAmount(cents: store.snapshot.acceptedBalanceCents, font: EW.Font.displayBalance)
            Text("Virtual practice only. These dollars are pretend, cannot be redeemed, and never move real money.")
                .font(EW.Font.body)
                .foregroundStyle(EW.Color.textSecondary)
            FreshnessLabel(date: store.snapshot.lastUpdated, isStale: store.snapshot.isStale)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .ewCard()
    }

    private var childBalanceCard: some View {
        VStack(spacing: EW.Space.three) {
            Image("WalletMark")
                .resizable()
                .scaledToFit()
                .frame(width: 68, height: 68)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            Text(ChildProfileCopy.childGreeting(nickname: store.snapshot.configuredChildNickname))
                .font(EW.Font.headingSmall)
                .foregroundStyle(EW.Color.white.opacity(0.92))
            MoneyAmount(cents: store.snapshot.acceptedBalanceCents, font: EW.Font.displayBalance, color: EW.Color.white)
            Text("Pretend dollars for practice - not real money.")
                .font(EW.Font.body)
                .foregroundStyle(EW.Color.white.opacity(0.88))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, EW.Space.six)
        .padding(.horizontal, EW.Space.five)
        .background(EW.Color.primary, in: RoundedRectangle(cornerRadius: EW.Radius.extraLarge, style: .continuous))
        .overlay(alignment: .topTrailing) {
            Text("Nice job")
                .font(EW.Font.caption)
                .foregroundStyle(EW.Color.white)
                .padding(.horizontal, EW.Space.three)
                .padding(.vertical, EW.Space.two)
                .background(EW.Color.gold500, in: Capsule())
                .rotationEffect(.degrees(8))
                .padding(EW.Space.four)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(ChildProfileCopy.childBalanceTitle(nickname: store.snapshot.configuredChildNickname)) \(Money(cents: store.snapshot.acceptedBalanceCents).display). Pretend dollars for practice, not real money.")
    }

    private var allowanceCard: some View {
        Button {
            isShowingAllowance = true
        } label: {
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
                        Text("Set a weekly virtual allowance")
                            .font(EW.Font.body)
                            .foregroundStyle(EW.Color.textSecondary)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .foregroundStyle(EW.Color.textTertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .ewCard(variant: .alt)
        .accessibilityHint("Opens allowance setup")
    }

    private var syncStatusCard: some View {
        VStack(alignment: .leading, spacing: EW.Space.three) {
            Label("Sync status", systemImage: "arrow.triangle.2.circlepath")
                .font(EW.Font.headingSmall)
                .foregroundStyle(EW.Color.textPrimary)
            ForEach(store.snapshot.pendingEvents) { event in
                Button {
                    selectedEvent = event
                } label: {
                    HStack(spacing: EW.Space.three) {
                        IconBadge(event.type.iconName, foreground: stateColor(event.syncState), background: stateTint(event.syncState), size: 36)
                        VStack(alignment: .leading, spacing: EW.Space.one) {
                            Text(event.displayReason)
                                .font(EW.Font.bodyBold)
                                .foregroundStyle(EW.Color.textPrimary)
                            MoneyAmount(cents: event.amountCents, font: EW.Font.caption, color: EW.Color.textSecondary)
                        }
                        Spacer()
                        StatusPill(state: event.syncState)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .ewCard(variant: .alt)
    }

    private var activityCard: some View {
        VStack(spacing: 0) {
            ForEach(Array(store.snapshot.activities.enumerated()), id: \.element.id) { index, event in
                ActivityRowView(event: event) {
                    selectedEvent = event
                }
                if index < store.snapshot.activities.count - 1 {
                    Divider().overlay(EW.Color.border)
                }
            }
        }
        .padding(.horizontal, EW.Space.five)
        .background(EW.Color.card, in: RoundedRectangle(cornerRadius: EW.Radius.large, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: EW.Radius.large, style: .continuous).stroke(EW.Color.border, lineWidth: 1)
        }
        .shadow(color: EW.Color.ink900.opacity(0.06), radius: 3, y: 1)
    }

    private var actionGrid: some View {
        LazyVGrid(columns: columns, spacing: EW.Space.three) {
            ActionButton(title: "Add deposit", icon: "arrow.down.circle", tint: EW.Color.primary) { flow = .deposit }
            ActionButton(title: "Record withdrawal", icon: "arrow.up.circle", tint: EW.Color.textSecondary) { flow = .withdrawal }
            ActionButton(title: "Create loan", icon: "hand.raised", tint: EW.Color.peach700) { flow = .loan }
            ActionButton(title: "Record repayment", icon: "arrow.triangle.2.circlepath", tint: EW.Color.green700) { flow = .repayment }
            ActionButton(title: "Record allowance", icon: "gift", tint: EW.Color.gold700) { flow = .allowance }
        }
    }

    private var nextLessonCard: some View {
        Button {
            isShowingLesson = true
        } label: {
            HStack(spacing: EW.Space.three) {
                IconBadge("book.closed", foreground: EW.Color.white, background: EW.Color.gold500, size: 56)
                VStack(alignment: .leading, spacing: EW.Space.one) {
                    Text("Next lesson")
                        .font(EW.Font.headingSmall)
                        .foregroundStyle(EW.Color.textPrimary)
                    Text("Borrow and repay · 3 of 4")
                        .font(EW.Font.body)
                        .foregroundStyle(EW.Color.textSecondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .foregroundStyle(EW.Color.gold700)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .ewCard(variant: .alt)
        .accessibilityHint("Opens the next lesson")
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

private struct ActionButton: View {
    let title: String
    let icon: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.bordered)
        .tint(tint)
        .controlSize(.large)
        .font(EW.Font.bodyBold)
        .background(EW.Color.card, in: RoundedRectangle(cornerRadius: EW.Radius.medium, style: .continuous))
    }
}

private struct ActivityRowView: View {
    let event: WalletEvent
    let action: () -> Void

    private var tint: Color {
        switch event.type {
        case .allowance: EW.Color.gold700
        case .deposit, .repayment: EW.Color.green700
        case .withdrawal: EW.Color.textSecondary
        case .loan: EW.Color.peach700
        }
    }

    private var tintBackground: Color {
        switch event.type {
        case .allowance: EW.Color.goldTint
        case .deposit, .repayment: EW.Color.green100
        case .withdrawal: EW.Color.ink100
        case .loan: EW.Color.peachTint
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: EW.Space.four) {
                IconBadge(event.type.iconName, foreground: tint, background: tintBackground)
                VStack(alignment: .leading, spacing: 2) {
                    Text(event.displayReason)
                        .font(EW.Font.bodyBold)
                        .foregroundStyle(EW.Color.textPrimary)
                        .lineLimit(1)
                    Text("\(event.type.title) · \(event.date.formatted(.dateTime.month(.abbreviated).day()))")
                        .font(EW.Font.caption)
                        .foregroundStyle(EW.Color.textTertiary)
                }
                Spacer(minLength: EW.Space.two)
                VStack(alignment: .trailing, spacing: 4) {
                    MoneyAmount(cents: event.isPositive ? event.amountCents : -event.amountCents, font: EW.Font.headingSmall, color: event.isPositive ? EW.Color.green700 : EW.Color.textPrimary)
                    if event.syncState != .recorded {
                        StatusPill(state: event.syncState)
                    }
                }
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(EW.Color.textTertiary)
            }
            .padding(.vertical, EW.Space.three)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(event.displayReason), \(event.signedAmount.display), \(event.syncState.label)")
    }
}

private struct LoanCardView: View {
    let loan: Loan
    let isParent: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: EW.Space.four) {
                HStack(spacing: EW.Space.three) {
                    IconBadge("hand.raised", foreground: EW.Color.peach700, background: EW.Color.white)
                    VStack(alignment: .leading, spacing: EW.Space.one) {
                        Text(loan.isPaid ? "Loan paid off" : "\(Money(cents: loan.remainingCents).display) left to repay")
                            .font(EW.Font.headingSmall)
                            .foregroundStyle(EW.Color.textPrimary)
                        Text(isParent ? "Secondary wallet card" : "A little at a time is okay")
                            .font(EW.Font.caption)
                            .foregroundStyle(EW.Color.textSecondary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .foregroundStyle(EW.Color.peach700)
                }
                if !loan.isPaid {
                    ProgressView(value: loan.progress)
                        .tint(EW.Color.peach700)
                    HStack {
                        Text(loan.dueDate.map { "Due \($0.formatted(.dateTime.month(.abbreviated).day()))" } ?? "No due date set")
                        Spacer()
                        Text("of \(Money(cents: loan.originalCents).display)")
                    }
                    .font(EW.Font.caption)
                    .foregroundStyle(EW.Color.textSecondary)
                    if isParent {
                        Text("Record repayment")
                            .font(EW.Font.bodyBold)
                            .foregroundStyle(EW.Color.peach700)
                    }
                } else {
                    Text("Kept in history as Paid.")
                        .font(EW.Font.body)
                        .foregroundStyle(EW.Color.textSecondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .ewCard(variant: .alt)
        .accessibilityHint(isParent ? "Opens loan details and repayment" : "Opens read-only loan details")
    }
}

#Preview("Parent wallet") {
    WalletView().environmentObject(WalletStore.preview())
}

#Preview("Child wallet") {
    let store = WalletStore.preview()
    store.switchRole(to: .child)
    return WalletView().environmentObject(store)
}
