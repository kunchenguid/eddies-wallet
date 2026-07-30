import SwiftUI

/// The app's home and only persistent surface: the configured child's
/// read-only wallet. Parent access is a quiet, gated door - never a peer
/// mode. All copy on this screen stays kid-readable (PRD 11).
struct KidHomeView: View {
    @EnvironmentObject private var store: WalletStore
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Larger hero balance on regular widths; rides Dynamic Type via the
    /// large-title metric.
    @ScaledMetric(relativeTo: .largeTitle) private var regularHeroBalanceSize: CGFloat = 46
    @State private var selectedEvent: WalletEvent?
    @State private var isShowingLoan = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: EW.Space.six) {
                header
                if let statusMessage = kidStatusMessage {
                    kidStatusBanner(statusMessage)
                }
                if store.canShowWalletData {
                    heroBalanceCard
                    if let loan = store.snapshot.loan {
                        LoanCardView(loan: loan, isParent: false) {
                            isShowingLoan = true
                        }
                    }
                    if store.snapshot.activities.isEmpty {
                        emptyWalletCard
                    } else {
                        SectionHeader("What's been happening")
                        ActivityListCard(events: store.snapshot.activities, announcesVirtualMoney: false) { event in
                            selectedEvent = event
                        }
                    }
                    FreshnessLabel(date: store.snapshot.lastUpdated, isStale: store.snapshot.isStale)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    cloudReplicaUnavailableCard
                }
            }
            .padding(.horizontal, EW.Space.screenMargin)
            .padding(.top, EW.Space.four)
            .padding(.bottom, EW.Space.ten)
            .frame(maxWidth: 700)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(EW.Color.appBackground.ignoresSafeArea())
        .refreshable {
            await store.refresh()
        }
        .task {
            await store.refresh()
        }
        .sheet(item: $selectedEvent) { event in
            ActivityDetailView(event: event, audience: .kid)
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $isShowingLoan) {
            LoanDetailView(isParent: false, onRepay: {})
                .presentationDetents([.medium, .large])
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: EW.Space.three) {
            Text(ChildProfileCopy.walletTitle(nickname: store.snapshot.configuredChildNickname))
                .font(EW.Font.displayLarge)
                .foregroundStyle(EW.Color.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: EW.Space.two)
            Button {
                store.openParentGate()
            } label: {
                ParentDoorLabel()
            }
            .buttonStyle(.plain)
            .accessibilityLabel(KidCopy.parentDoorAccessibilityLabel())
        }
    }

    /// Calm, kid-worded status line. Technical wording ("accepted balance",
    /// "sync", "session") never appears on this screen.
    private var kidStatusMessage: String? {
        if store.sessionExpired {
            return KidCopy.sessionBanner
        }
        if store.isOffline || store.errorMessage != nil {
            return KidCopy.offlineBanner(lastUpdated: store.snapshot.lastUpdated)
        }
        return nil
    }

    private func kidStatusBanner(_ message: String) -> some View {
        Label(message, systemImage: "cloud")
            .font(EW.Font.caption)
            .foregroundStyle(EW.Color.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(EW.Space.three)
            .background(EW.Color.cardAlt, in: RoundedRectangle(cornerRadius: EW.Radius.medium, style: .continuous))
    }

    private var heroBalanceCard: some View {
        VStack(spacing: EW.Space.three) {
            Image("WalletMark")
                .resizable()
                .scaledToFit()
                .frame(width: 68, height: 68)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            Text(ChildProfileCopy.childGreeting(nickname: store.snapshot.configuredChildNickname))
                .font(EW.Font.headingSmall)
                .foregroundStyle(EW.Color.white.opacity(0.92))
            MoneyAmount(
                cents: store.snapshot.acceptedBalanceCents,
                font: horizontalSizeClass == .regular
                    ? .system(size: regularHeroBalanceSize, weight: .bold, design: .rounded)
                    : EW.Font.displayBalance,
                color: EW.Color.white,
                announcesVirtualMoney: false
            )
            Text(ChildProfileCopy.childBalanceTitle(nickname: store.snapshot.configuredChildNickname))
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
                .rotationEffect(.degrees(reduceMotion ? 0 : 8))
                .padding(EW.Space.four)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(ChildProfileCopy.childBalanceTitle(nickname: store.snapshot.configuredChildNickname)) \(Money(cents: store.snapshot.acceptedBalanceCents).display).")
    }

    private var emptyWalletCard: some View {
        VStack(spacing: EW.Space.three) {
            IconBadge("sparkles", foreground: EW.Color.gold700, background: EW.Color.goldTint, size: 56)
            Text(KidCopy.emptyWalletTitle)
                .font(EW.Font.heading)
                .foregroundStyle(EW.Color.textPrimary)
            Text(KidCopy.emptyWalletMessage)
                .font(EW.Font.body)
                .foregroundStyle(EW.Color.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, EW.Space.six)
        .ewCard()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(KidCopy.emptyWalletTitle) \(KidCopy.emptyWalletMessage)")
    }

    private var cloudReplicaUnavailableCard: some View {
        VStack(spacing: EW.Space.three) {
            IconBadge("icloud.slash", foreground: EW.Color.primaryActive, background: EW.Color.cardAlt, size: 56)
            Text(KidCopy.cloudReplicaUnavailableTitle)
                .font(EW.Font.heading)
                .foregroundStyle(EW.Color.textPrimary)
                .multilineTextAlignment(.center)
            Text(KidCopy.cloudReplicaUnavailableMessage(deviceNoun: DeviceCopy.deviceNoun))
                .font(EW.Font.body)
                .foregroundStyle(EW.Color.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, EW.Space.six)
        .ewCard(variant: .alt)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("kid-cloud-replica-unavailable")
    }
}

#Preview("Kid home") {
    KidHomeView().environmentObject(WalletStore.preview())
}
