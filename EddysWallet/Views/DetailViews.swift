import SwiftUI

enum ActivityDetailCopy {
    static func attribution(
        for _: WalletEvent,
        audience: ActivityDetailView.Audience
    ) -> (label: String, value: String) {
        switch audience {
        case .kid: ("Changed by", "Your parent")
        case .parent: ("Recorded by", "Parent")
        }
    }

    static func explanation(
        for event: WalletEvent,
        audience: ActivityDetailView.Audience
    ) -> String {
        guard audience == .kid else { return event.explanation }

        let amount = Money(cents: event.amountCents).display
        return switch event.type {
        case .allowance: "Your parent added \(amount) as your allowance."
        case .deposit: "Your parent added \(amount) to your wallet."
        case .withdrawal: "Your parent recorded that \(amount) was used."
        case .loan: "Your parent gave you \(amount) to use now and give back over time."
        case .repayment: "Your parent recorded \(amount) returned toward the loan."
        }
    }
}

struct ActivityDetailView: View {
    @Environment(\.dismiss) private var dismiss
    let event: WalletEvent
    var audience: Audience = .parent

    enum Audience {
        case kid
        case parent
    }

    private var amountColor: Color { event.isPositive ? EW.Color.green700 : EW.Color.textPrimary }

    var body: some View {
        NavigationStack {
            SheetForm {
                VStack(alignment: .leading, spacing: EW.Space.five) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: EW.Space.one) {
                            Text(event.type.title)
                                .font(EW.Font.heading)
                                .foregroundStyle(EW.Color.textPrimary)
                            Text(event.date.formatted(date: .abbreviated, time: .shortened))
                                .font(EW.Font.caption)
                                .foregroundStyle(EW.Color.textTertiary)
                        }
                        Spacer()
                        if audience == .parent {
                            StatusPill(state: event.syncState)
                        }
                    }

                    MoneyAmount(
                        cents: event.signedAmount.cents,
                        font: EW.Font.displayLarge,
                        color: amountColor,
                        announcesVirtualMoney: audience == .parent
                    )

                    if let reason = event.reason, !reason.isEmpty {
                        detailRow(label: event.type == .loan ? "Purpose" : "Reason", value: reason)
                    }
                    let attribution = ActivityDetailCopy.attribution(for: event, audience: audience)
                    detailRow(label: attribution.label, value: attribution.value)
                    if let before = event.balanceBeforeCents, let after = event.balanceAfterCents {
                        detailRow(
                            label: audience == .kid ? "Wallet changed" : "Accepted balance",
                            value: "\(Money(cents: before).display) -> \(Money(cents: after).display)"
                        )
                    }
                    if let rejectionReason = event.rejectionReason {
                        detailRow(label: "Why", value: rejectionReason)
                            .foregroundStyle(EW.Color.red600)
                    }

                    Text(ActivityDetailCopy.explanation(for: event, audience: audience))
                        .font(EW.Font.body)
                        .foregroundStyle(EW.Color.textSecondary)
                        .padding(EW.Space.four)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(EW.Color.cardAlt, in: RoundedRectangle(cornerRadius: EW.Radius.medium, style: .continuous))

                    if audience == .parent {
                        Text("Virtual practice only. These dollars are pretend, cannot be redeemed, and never move real money.")
                            .font(EW.Font.caption)
                            .foregroundStyle(EW.Color.textTertiary)
                    }
                }
            }
            .navigationTitle("Activity detail")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func detailRow(label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(EW.Font.body)
                .foregroundStyle(EW.Color.textSecondary)
            Spacer()
            Text(value)
                .font(EW.Font.bodyBold)
                .foregroundStyle(EW.Color.textPrimary)
                .multilineTextAlignment(.trailing)
        }
    }
}

struct LoanDetailView: View {
    @Environment(\.dismiss) private var dismiss
    let isParent: Bool
    let onRepay: () -> Void
    @EnvironmentObject private var store: WalletStore

    /// The parent's repayment control is the reason this sheet has a bottom
    /// bar: it is an action, not a detail, so it never scrolls away with the
    /// loan copy. The kid's read-only view has no bar at all.
    private var showsRepayAction: Bool {
        isParent && store.canModifyWallet && (store.snapshot.loan.map { !$0.isPaid } ?? false)
    }

    var body: some View {
        NavigationStack {
            Group {
                if showsRepayAction {
                    SheetForm { detail } actions: { repayButton }
                } else {
                    SheetForm { detail }
                }
            }
            .navigationTitle("Loan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }

    private var repayButton: some View {
        Button("Record repayment", action: onRepay)
            .buttonStyle(PrimaryButtonStyle())
            .disabled(!store.canStartParentMutation)
            .opacity(store.canStartParentMutation ? 1 : 0.5)
            .accessibilityIdentifier("loan-record-repayment")
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: EW.Space.five) {
            if let loan = store.snapshot.loan {
                VStack(alignment: .leading, spacing: EW.Space.four) {
                    HStack {
                        IconBadge("hand.raised", foreground: EW.Color.peach700, background: EW.Color.peach100)
                        Text("Loan details")
                            .font(EW.Font.heading)
                            .foregroundStyle(EW.Color.textPrimary)
                    }
                    HStack {
                        Text(loan.isPaid ? "Paid" : "Left to repay")
                            .font(EW.Font.body)
                            .foregroundStyle(EW.Color.textSecondary)
                        Spacer()
                        MoneyAmount(
                            cents: loan.remainingCents,
                            font: EW.Font.display,
                            color: EW.Color.peach700,
                            announcesVirtualMoney: isParent
                        )
                    }
                    if !loan.isPaid {
                        ProgressView(value: loan.progress)
                            .tint(EW.Color.peach700)
                        Text(loan.dueDate.map { "Due \($0.formatted(.dateTime.month(.abbreviated).day()))" } ?? "No due date set")
                            .font(EW.Font.caption)
                            .foregroundStyle(EW.Color.textSecondary)
                    }
                }
                .ewCard(variant: .alt)

                VStack(alignment: .leading, spacing: EW.Space.three) {
                    detailRow(label: "Original loan", value: Money(cents: loan.originalCents).display)
                    if let purpose = loan.purpose, !purpose.isEmpty {
                        detailRow(label: "Purpose", value: purpose)
                    }
                    Text(isParent
                         ? "This virtual loan adds pretend dollars to the accepted balance in \(ChildProfileCopy.walletReference(nickname: store.snapshot.configuredChildNickname)) and keeps an amount to give back over time."
                         : "Your parent gave you dollars to use now. You give them back a little at a time - that is a repayment.")
                        .font(EW.Font.body)
                        .foregroundStyle(EW.Color.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .ewCard()

                if isParent {
                    Text("Virtual practice only. These dollars are pretend, cannot be redeemed, and never move real money.")
                        .font(EW.Font.caption)
                        .foregroundStyle(EW.Color.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text("There is no open loan.")
                    .font(EW.Font.body)
                    .foregroundStyle(EW.Color.textSecondary)
            }
        }
    }

    private func detailRow(label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(EW.Font.body).foregroundStyle(EW.Color.textSecondary)
            Spacer()
            Text(value).font(EW.Font.bodyBold).foregroundStyle(EW.Color.textPrimary)
        }
    }
}
