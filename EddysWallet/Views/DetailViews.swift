import SwiftUI

struct ActivityDetailView: View {
    @Environment(\.dismiss) private var dismiss
    let event: WalletEvent

    private var amountColor: Color { event.isPositive ? EW.Color.green700 : EW.Color.textPrimary }

    var body: some View {
        NavigationStack {
            ScrollView {
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
                        StatusPill(state: event.syncState)
                    }

                    MoneyAmount(cents: event.signedAmount.cents, font: EW.Font.displayLarge, color: amountColor)

                    if let reason = event.reason, !reason.isEmpty {
                        detailRow(label: event.type == .loan ? "Purpose" : "Reason", value: reason)
                    }
                    detailRow(label: "Recorded by", value: "Parent")
                    if let before = event.balanceBeforeCents, let after = event.balanceAfterCents {
                        detailRow(
                            label: "Accepted balance",
                            value: "\(Money(cents: before).display) -> \(Money(cents: after).display)"
                        )
                    }
                    if let rejectionReason = event.rejectionReason {
                        detailRow(label: "Why", value: rejectionReason)
                            .foregroundStyle(EW.Color.red600)
                    }

                    Text(event.explanation)
                        .font(EW.Font.body)
                        .foregroundStyle(EW.Color.textSecondary)
                        .padding(EW.Space.four)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(EW.Color.cardAlt, in: RoundedRectangle(cornerRadius: EW.Radius.medium, style: .continuous))

                    Text("Virtual practice only. These dollars are pretend, cannot be redeemed, and never move real money.")
                        .font(EW.Font.caption)
                        .foregroundStyle(EW.Color.textTertiary)
                }
                .padding(EW.Space.screenMargin)
                .frame(maxWidth: 620)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .background(EW.Color.appBackground)
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

    var body: some View {
        NavigationStack {
            ScrollView {
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
                                MoneyAmount(cents: loan.remainingCents, font: EW.Font.display, color: EW.Color.peach700)
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
                                 : "Your parent gave you virtual dollars to use now. You give them back a little at a time - that is a repayment.")
                                .font(EW.Font.body)
                                .foregroundStyle(EW.Color.textSecondary)
                        }
                        .ewCard()

                        if isParent && !loan.isPaid {
                            Button("Record repayment", action: onRepay)
                                .buttonStyle(PrimaryButtonStyle())
                        }

                        Text("Virtual practice only. These dollars are pretend, cannot be redeemed, and never move real money.")
                            .font(EW.Font.caption)
                            .foregroundStyle(EW.Color.textTertiary)
                    } else {
                        Text("There is no open loan.")
                            .font(EW.Font.body)
                            .foregroundStyle(EW.Color.textSecondary)
                    }
                }
                .padding(EW.Space.screenMargin)
                .frame(maxWidth: 620)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .background(EW.Color.appBackground)
            .navigationTitle("Loan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
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
