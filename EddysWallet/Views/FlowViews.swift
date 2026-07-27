import SwiftUI

public enum MoneyFlowKind: String, Identifiable, CaseIterable {
    case deposit
    case withdrawal
    case loan
    case repayment
    case allowance

    public var id: String { rawValue }

    var title: String {
        switch self {
        case .deposit: "Add deposit"
        case .withdrawal: "Record withdrawal"
        case .loan: "Create loan"
        case .repayment: "Record repayment"
        case .allowance: "Record allowance"
        }
    }

    var commandKind: WalletCommandKind {
        switch self {
        case .deposit: .deposit
        case .withdrawal: .withdrawal
        case .loan: .loan
        case .repayment: .repayment
        case .allowance: .allowance
        }
    }
}

struct MoneyFlowView: View {
    @EnvironmentObject private var store: WalletStore
    @Environment(\.dismiss) private var dismiss
    let kind: MoneyFlowKind
    @State private var amount = ""
    @State private var reason = ""
    @State private var dueDate = Date().addingTimeInterval(60 * 60 * 24 * 30)
    @State private var step: Step = .amount
    @State private var resultState: SyncState?
    @State private var resultMessage = ""
    @State private var isSubmitting = false

    private enum Step { case amount, review, result }

    private var parsedCents: Int? { Money.parse(amount)?.cents }

    private var validationMessage: String? {
        guard let cents = parsedCents else { return "Enter an amount greater than US$0.00." }
        switch kind {
        case .withdrawal:
            return cents > store.snapshot.acceptedBalanceCents ? "The amount is greater than the accepted balance." : nil
        case .repayment:
            guard let loan = store.snapshot.loan else { return "There is no open loan to repay." }
            if cents > loan.remainingCents { return "The repayment is greater than the amount left to repay." }
            if cents > store.snapshot.acceptedBalanceCents { return "The repayment is greater than the accepted balance." }
            return nil
        case .loan:
            if let loan = store.snapshot.loan, !loan.isPaid { return "Finish the open loan before creating another one." }
            return nil
        case .deposit, .allowance:
            return nil
        }
    }

    private var resultingBalance: Int {
        guard let cents = parsedCents else { return store.snapshot.acceptedBalanceCents }
        switch kind {
        case .withdrawal, .repayment: return store.snapshot.acceptedBalanceCents - cents
        case .deposit, .loan, .allowance: return store.snapshot.acceptedBalanceCents + cents
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                switch step {
                case .amount: amountForm
                case .review: review
                case .result: result
                }
            }
            .background(EW.Color.appBackground)
            .navigationTitle(kind.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if step != .result {
                        Button("Cancel") { dismiss() }
                    }
                }
            }
        }
    }

    private var amountForm: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: EW.Space.six) {
                Text(formIntro)
                    .font(EW.Font.body)
                    .foregroundStyle(EW.Color.textSecondary)
                VStack(alignment: .leading, spacing: EW.Space.three) {
                    Text("Amount")
                        .font(EW.Font.captionUpper)
                        .foregroundStyle(EW.Color.textTertiary)
                    HStack(spacing: EW.Space.two) {
                        Text("US$")
                            .font(EW.Font.bodyBold)
                            .foregroundStyle(EW.Color.textTertiary)
                        TextField("0.00", text: $amount)
                            .font(EW.Font.heading)
                            .keyboardType(.decimalPad)
                            .textFieldStyle(.plain)
                            .accessibilityLabel("Amount in virtual dollars")
                    }
                    .padding(.horizontal, EW.Space.four)
                    .frame(minHeight: 56)
                    .background(EW.Color.card, in: RoundedRectangle(cornerRadius: EW.Radius.medium, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: EW.Radius.medium, style: .continuous)
                            .stroke(validationMessage == nil ? EW.Color.border : EW.Color.red600, lineWidth: 1.5)
                    }
                    if let validationMessage {
                        Text(validationMessage)
                            .font(EW.Font.caption)
                            .foregroundStyle(EW.Color.red600)
                    }
                }

                VStack(alignment: .leading, spacing: EW.Space.two) {
                    Text(kind == .loan ? "Purpose (optional)" : "Reason (optional)")
                        .font(EW.Font.captionUpper)
                        .foregroundStyle(EW.Color.textTertiary)
                    TextField(kind == .loan ? "What is this for?" : "Add a note", text: $reason)
                        .font(EW.Font.body)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel(kind == .loan ? "Loan purpose" : "Reason")
                }

                if kind == .loan {
                    DatePicker("Due date (optional)", selection: $dueDate, displayedComponents: .date)
                        .font(EW.Font.body)
                        .tint(EW.Color.primaryActive)
                }

                Button("Review") {
                    if validationMessage == nil { step = .review }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(parsedCents == nil || validationMessage != nil)
                .opacity(parsedCents == nil || validationMessage != nil ? 0.45 : 1)
            }
            .padding(EW.Space.screenMargin)
            .frame(maxWidth: 620)
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private var review: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: EW.Space.five) {
                VStack(alignment: .leading, spacing: EW.Space.three) {
                    Label("Review before recording", systemImage: "checkmark.circle")
                        .font(EW.Font.heading)
                        .foregroundStyle(EW.Color.textPrimary)
                    reviewRow(label: "Event", value: kind.title)
                    reviewRow(label: "Amount", value: Money(cents: parsedCents ?? 0).display)
                    if !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        reviewRow(label: kind == .loan ? "Purpose" : "Reason", value: reason)
                    }
                    Divider()
                    reviewRow(label: "Resulting accepted balance", value: Money(cents: resultingBalance).display)
                    if kind == .loan, let cents = parsedCents {
                        reviewRow(label: "Amount left to repay", value: Money(cents: cents).display)
                    }
                }
                .ewCard()

                Text("Virtual practice only. These dollars are pretend, cannot be redeemed, and never move real money.")
                    .font(EW.Font.body)
                    .foregroundStyle(EW.Color.textSecondary)
                    .padding(EW.Space.four)
                    .background(EW.Color.cardAlt, in: RoundedRectangle(cornerRadius: EW.Radius.medium, style: .continuous))

                Button("Confirm \(kind.title.lowercased())") {
                    Task { await confirm() }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(isSubmitting)
                .opacity(isSubmitting ? 0.45 : 1)
                Button("Back") { step = .amount }
                    .buttonStyle(SecondaryButtonStyle(compact: true))
            }
            .padding(EW.Space.screenMargin)
            .frame(maxWidth: 620)
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private var result: some View {
        VStack(spacing: EW.Space.five) {
            Spacer()
            Image(systemName: resultState == .recorded ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.system(size: 58))
                .foregroundStyle(resultState == .recorded ? EW.Color.green600 : EW.Color.red600)
            if let resultState {
                StatusPill(state: resultState)
            }
            Text(resultMessage)
                .font(EW.Font.body)
                .foregroundStyle(EW.Color.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 420)
            Spacer()
            Button("Done") { dismiss() }
                .buttonStyle(PrimaryButtonStyle())
                .padding(.horizontal, EW.Space.screenMargin)
        }
        .padding(.vertical, EW.Space.seven)
    }

    private var formIntro: String {
        let walletReference = ChildProfileCopy.walletReference(nickname: store.snapshot.configuredChildNickname)
        let childReference = ChildProfileCopy.childReference(nickname: store.snapshot.configuredChildNickname)
        return switch kind {
        case .deposit: "Add pretend dollars to the accepted balance in \(walletReference)."
        case .withdrawal: "Record virtual dollars as used from \(walletReference)."
        case .loan: "Give \(childReference) virtual dollars to use now and give back over time."
        case .repayment: "Record virtual dollars returned toward the open loan."
        case .allowance: "Record this virtual allowance in \(walletReference)."
        }
    }

    private func reviewRow(label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(EW.Font.body)
                .foregroundStyle(EW.Color.textSecondary)
            Spacer(minLength: EW.Space.four)
            Text(value)
                .font(EW.Font.bodyBold)
                .foregroundStyle(EW.Color.textPrimary)
                .multilineTextAlignment(.trailing)
        }
    }

    private func confirm() async {
        guard let cents = parsedCents, !isSubmitting else { return }
        isSubmitting = true
        let command = WalletCommand(
            kind: kind.commandKind,
            amountCents: cents,
            reason: reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : reason,
            dueDate: kind == .loan ? dueDate : nil
        )
        let result = await store.submit(command)
        switch result {
        case .accepted:
            resultState = .recorded
            resultMessage = "This virtual money event was accepted and added to \(ChildProfileCopy.walletReference(nickname: store.snapshot.configuredChildNickname))."
        case .pending:
            resultState = .pending
            resultMessage = "This parent action is queued locally. It is not included in the accepted balance until it syncs."
        case .rejected(let event):
            resultState = .rejected
            resultMessage = event.rejectionReason ?? "This action was not recorded and did not change the accepted balance."
        }
        isSubmitting = false
        step = .result
    }
}

struct AllowanceView: View {
    @EnvironmentObject private var store: WalletStore
    @Environment(\.dismiss) private var dismiss
    @State private var amount = "10.00"
    @State private var startDate = Date().addingTimeInterval(60 * 60 * 24 * 5)
    @State private var showDraft = false
    @State private var showReview = false
    @State private var resultState: SyncState?
    @State private var resultMessage = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: EW.Space.five) {
                    Text("Set one simple weekly plan for \(ChildProfileCopy.childReference(nickname: store.snapshot.configuredChildNickname)). A plan is separate from an allowance event until it is recorded.")
                        .font(EW.Font.body)
                        .foregroundStyle(EW.Color.textSecondary)
                    VStack(alignment: .leading, spacing: EW.Space.three) {
                        Text("Weekly amount")
                            .font(EW.Font.captionUpper)
                            .foregroundStyle(EW.Color.textTertiary)
                        HStack {
                            Text("US$").foregroundStyle(EW.Color.textTertiary).font(EW.Font.bodyBold)
                            TextField("0.00", text: $amount)
                                .font(EW.Font.heading)
                                .keyboardType(.decimalPad)
                                .textFieldStyle(.plain)
                        }
                        .padding(EW.Space.four)
                        .background(EW.Color.card, in: RoundedRectangle(cornerRadius: EW.Radius.medium, style: .continuous))
                        DatePicker("Starts", selection: $startDate, displayedComponents: .date)
                            .tint(EW.Color.primaryActive)
                    }
                    .ewCard()

                    if showDraft {
                        HStack {
                            StatusPill(state: .draft)
                            Text("This plan is local only until it is recorded.")
                                .font(EW.Font.caption)
                                .foregroundStyle(EW.Color.textSecondary)
                        }
                    }
                    if let resultState {
                        StatusPill(state: resultState)
                        if !resultMessage.isEmpty {
                            Text(resultMessage)
                                .font(EW.Font.caption)
                                .foregroundStyle(EW.Color.textSecondary)
                        }
                    }

                    Button("Review allowance") { showReview = true }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(Money.parse(amount) == nil)
                        .opacity(Money.parse(amount) == nil ? 0.45 : 1)
                    Button("Save as draft on this iPad") { showDraft = true }
                        .buttonStyle(SecondaryButtonStyle(compact: true))
                }
                .padding(EW.Space.screenMargin)
                .frame(maxWidth: 620)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .background(EW.Color.appBackground)
            .navigationTitle("Set allowance")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
            .sheet(isPresented: $showReview) {
                AllowanceReviewView(amountCents: Money.parse(amount)?.cents ?? 0, startDate: startDate) {
                    let calendar = Calendar(identifier: .gregorian)
                    let weekday = calendar.component(.weekday, from: startDate) - 1
                    let command = AllowanceRuleCommand(
                        amountCents: Money.parse(amount)?.cents ?? 0,
                        weekday: weekday,
                        startDate: startDate
                    )
                    let accepted = await store.setAllowance(command)
                    resultState = accepted ? .recorded : .rejected
                    resultMessage = accepted
                        ? "The weekly allowance plan was recorded. Its next occurrence is separate from an allowance event until your parent records it."
                        : (store.errorMessage ?? "The allowance plan was not recorded.")
                    showReview = false
                    showDraft = false
                }
                .presentationDetents([.medium])
            }
        }
    }
}

private struct AllowanceReviewView: View {
    @Environment(\.dismiss) private var dismiss
    let amountCents: Int
    let startDate: Date
    let confirm: () async -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: EW.Space.five) {
            Text("Review allowance")
                .font(EW.Font.heading)
                .foregroundStyle(EW.Color.textPrimary)
            Text("Add \(Money(cents: amountCents).display) virtual dollars each week starting \(startDate.formatted(.dateTime.month(.abbreviated).day())).")
                .font(EW.Font.body)
                .foregroundStyle(EW.Color.textSecondary)
            Text("This creates a plan for future occurrences. The plan is not an allowance event until it is accepted.")
                .font(EW.Font.caption)
                .foregroundStyle(EW.Color.textTertiary)
            Button("Confirm allowance") {
                Task {
                    await confirm()
                    dismiss()
                }
            }
            .buttonStyle(PrimaryButtonStyle())
            Button("Back") { dismiss() }
                .buttonStyle(SecondaryButtonStyle(compact: true))
        }
        .padding(EW.Space.screenMargin)
    }
}

#Preview("Deposit flow") {
    MoneyFlowView(kind: .deposit).environmentObject(WalletStore.preview())
}
