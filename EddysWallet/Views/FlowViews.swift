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
        case .repayment: "Pay toward loan"
        case .allowance: "Pay out allowance"
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

/// The parent's one money-recording flow: amount, review, result.
///
/// Every step is a `SheetForm`, so the control that carries the step forward -
/// Review, Confirm, Done - lives in the pinned bottom bar and never scrolls
/// away, whatever the sheet height, text size, or keyboard state. Losing the
/// confirm control under the fold is how a parent records nothing, or the
/// wrong thing.
struct MoneyFlowView: View {
    @EnvironmentObject private var store: WalletStore
    @Environment(\.dismiss) private var dismiss
    let kind: MoneyFlowKind
    @State private var amount = ""
    @State private var reason = ""
    @State private var dueDate = Date().addingTimeInterval(60 * 60 * 24 * 30)
    /// `nil` keeps the loan scheduleless, which is exactly what every loan was
    /// before payment plans existed: no reminder, no installments, and the
    /// one-shot repayment path.
    @State private var installmentCadence: LoanInstallmentCadence?
    @State private var installmentAmount = ""
    @State private var step: Step = .amount
    @State private var resultState: SyncState?
    @State private var resultMessage = ""
    @State private var isSubmitting = false
    @FocusState private var focusedAmount: AmountFocus?

    private enum AmountFocus: Hashable {
        case amount
        case installment
    }

    private enum Step { case amount, review, result }

    private var parsedCents: Int? { Money.parse(amount)?.cents }

    private var parsedInstallmentCents: Int? { Money.parse(installmentAmount)?.cents }

    /// The plan a parent has actually completed. A chosen cadence without a
    /// usable payment amount is not a plan, and the step's validation blocks
    /// review until it is one.
    private var installmentPlan: LoanInstallmentPlan? {
        guard kind == .loan, let installmentCadence, let cents = parsedInstallmentCents, cents > 0 else { return nil }
        return LoanInstallmentPlan(cadence: installmentCadence, amountCents: cents)
    }

    /// A parent who has not typed yet has done nothing wrong, so an untouched
    /// amount field is never marked as an error.
    private var showsValidation: Bool { !amount.isEmpty }

    private var visibleValidationMessage: String? {
        showsValidation ? validationMessage : nil
    }

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
            if installmentCadence != nil, installmentPlan == nil {
                return "Enter a payment amount greater than US$0.00."
            }
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
        SheetForm {
            VStack(alignment: .leading, spacing: EW.Space.six) {
                Text(formIntro)
                    .font(EW.Font.body)
                    .foregroundStyle(EW.Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    #if DEBUG
                    // Evidence capture taps this copy to resign the amount field
                    // so iPad screenshots are not covered by the software keyboard.
                    .onTapGesture { focusedAmount = nil }
                    #endif
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
                            .focused($focusedAmount, equals: .amount)
                            .accessibilityLabel("Amount in virtual dollars")
                    }
                    .padding(.horizontal, EW.Space.four)
                    .frame(minHeight: 56)
                    .background(EW.Color.card, in: RoundedRectangle(cornerRadius: EW.Radius.medium, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: EW.Radius.medium, style: .continuous)
                            .stroke(amountFieldStroke, lineWidth: focusedAmount == .amount && visibleValidationMessage == nil ? 2 : 1.5)
                    }
                    .ewAmountKeyboardAnchor("money-amount", isFocused: focusedAmount == .amount)
                    if let visibleValidationMessage {
                        Text(visibleValidationMessage)
                            .font(EW.Font.caption)
                            .foregroundStyle(EW.Color.red600)
                            .fixedSize(horizontal: false, vertical: true)
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
                    installmentPlanFields
                }
            }
        } actions: {
            Button("Review") {
                if validationMessage == nil {
                    focusedAmount = nil
                    step = .review
                }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(parsedCents == nil || validationMessage != nil)
            .opacity(parsedCents == nil || validationMessage != nil ? 0.45 : 1)
        }
        // The amount is the only thing this step is for, so it opens ready to
        // type: focused, keyboard already up, no extra tap.
        .onAppear { focusedAmount = .amount }
    }

    /// Choosing a cadence is what turns a loan into a scheduled one. The
    /// named amount is what each payment settles; the last payment is not part
    /// of the plan, because it is always whatever is left to repay.
    private var installmentPlanFields: some View {
        VStack(alignment: .leading, spacing: EW.Space.three) {
            Text("Payment plan (optional)")
                .font(EW.Font.captionUpper)
                .foregroundStyle(EW.Color.textTertiary)
            Picker("Payment plan", selection: $installmentCadence) {
                Text("No plan").tag(LoanInstallmentCadence?.none)
                Text("Weekly").tag(LoanInstallmentCadence?.some(.weekly))
                Text("Monthly").tag(LoanInstallmentCadence?.some(.monthly))
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("loan-payment-plan")

            if installmentCadence != nil {
                VStack(alignment: .leading, spacing: EW.Space.two) {
                    Text("Amount for each payment")
                        .font(EW.Font.captionUpper)
                        .foregroundStyle(EW.Color.textTertiary)
                    HStack(spacing: EW.Space.two) {
                        Text("US$")
                            .font(EW.Font.bodyBold)
                            .foregroundStyle(EW.Color.textTertiary)
                        TextField("0.00", text: $installmentAmount)
                            .font(EW.Font.bodyBold)
                            .keyboardType(.decimalPad)
                            .textFieldStyle(.plain)
                            .focused($focusedAmount, equals: .installment)
                            .accessibilityLabel("Amount for each loan payment")
                            .accessibilityIdentifier("loan-payment-amount")
                    }
                    .padding(.horizontal, EW.Space.four)
                    .frame(minHeight: 56)
                    .background(EW.Color.card, in: RoundedRectangle(cornerRadius: EW.Radius.medium, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: EW.Radius.medium, style: .continuous)
                            .stroke(EW.Color.border, lineWidth: 1.5)
                    }
                    .ewAmountKeyboardAnchor("loan-payment-amount", isFocused: focusedAmount == .installment)
                    Text("The last payment is whatever is left to repay, so it can be smaller than this amount.")
                        .font(EW.Font.caption)
                        .foregroundStyle(EW.Color.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var installmentPlanSummary: String {
        guard let plan = installmentPlan else { return "No plan" }
        let amount = Money(cents: plan.amountCents).display
        return switch plan.cadence {
        case .weekly: "\(amount) every week"
        case .monthly: "\(amount) every month"
        }
    }

    private var amountFieldStroke: Color {
        if visibleValidationMessage != nil { return EW.Color.red600 }
        return focusedAmount == .amount ? EW.Color.primary : EW.Color.border
    }

    private var review: some View {
        SheetForm {
            VStack(alignment: .leading, spacing: EW.Space.five) {
                VStack(alignment: .leading, spacing: EW.Space.three) {
                    Label(reviewHeading, systemImage: "checkmark.circle")
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
                        reviewRow(label: "Payment plan", value: installmentPlanSummary)
                    }
                }
                .ewCard()

                Text("Virtual practice only. These dollars are pretend, cannot be redeemed, and never move real money.")
                    .font(EW.Font.body)
                    .foregroundStyle(EW.Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(EW.Space.four)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(EW.Color.cardAlt, in: RoundedRectangle(cornerRadius: EW.Radius.medium, style: .continuous))
            }
        } actions: {
            Button(confirmActionTitle) {
                Task { await confirm() }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(isSubmitting)
            .opacity(isSubmitting ? 0.45 : 1)
            Button("Back") { step = .amount }
                .buttonStyle(SecondaryButtonStyle(compact: true))
        }
    }

    private var result: some View {
        SheetForm {
            VStack(spacing: EW.Space.five) {
                Image(systemName: resultIcon)
                    .font(.system(size: 58))
                    .foregroundStyle(resultColor)
                if let resultState {
                    StatusPill(state: resultState)
                }
                Text(resultMessage)
                    .font(EW.Font.body)
                    .foregroundStyle(EW.Color.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 420)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, EW.Space.six)
        } actions: {
            Button("Done") { dismiss() }
                .buttonStyle(PrimaryButtonStyle())
        }
        .defaultScrollAnchor(.top)
        .id("money-result-\(resultState?.rawValue ?? "none")")
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("money-flow-result")
    }

    private var resultIcon: String {
        switch resultState {
        case .recorded: "checkmark.circle.fill"
        case .pending: "clock.fill"
        case .rejected, .draft, nil: "exclamationmark.circle.fill"
        }
    }

    private var resultColor: Color {
        switch resultState {
        case .recorded: EW.Color.green600
        case .pending: EW.Color.gold700
        case .rejected, .draft, nil: EW.Color.red600
        }
    }

    private var formIntro: String {
        let walletReference = ChildProfileCopy.walletReference(nickname: store.snapshot.configuredChildNickname)
        let childReference = ChildProfileCopy.childReference(nickname: store.snapshot.configuredChildNickname)
        return switch kind {
        case .deposit: "Add pretend dollars to the accepted balance in \(walletReference)."
        case .withdrawal: "Record virtual dollars as used from \(walletReference)."
        case .loan: "Give \(childReference) virtual dollars to use now and give back over time."
        case .repayment: "Pay virtual dollars back toward the open loan."
        case .allowance: "Pay out this virtual allowance in \(walletReference)."
        }
    }

    /// The two settlement flows own their own verbs - allowance is paid out,
    /// a loan is paid back - so neither borrows the generic "record" wording
    /// that every other money event uses.
    private var reviewHeading: String {
        switch kind {
        case .allowance: "Review before paying out"
        case .repayment: "Review before paying"
        case .deposit, .withdrawal, .loan: "Review before recording"
        }
    }

    private var confirmActionTitle: String {
        switch kind {
        case .allowance: "Pay out allowance"
        case .repayment: "Pay toward loan"
        case .deposit, .withdrawal, .loan: "Confirm \(kind.title.lowercased())"
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
            dueDate: kind == .loan ? dueDate : nil,
            installmentPlan: installmentPlan
        )
        let result = await store.submit(command)
        switch result {
        case .accepted:
            resultState = .recorded
            let walletReference = ChildProfileCopy.walletReference(nickname: store.snapshot.configuredChildNickname)
            resultMessage = switch kind {
            case .allowance: "This virtual allowance was paid out and added to \(walletReference)."
            case .repayment: "This virtual payment was accepted toward the open loan."
            case .deposit, .withdrawal, .loan: "This virtual money event was accepted and added to \(walletReference)."
            }
        case .acceptedScheduleUnavailable:
            resultState = .recorded
            resultMessage = "This virtual allowance was paid out, but Cloud could not load the latest allowance schedule. Refresh before paying out another week."
        case .pending(let event, _):
            resultState = .pending
            resultMessage = event.explanation
        case .acceptedAwaitingReplica(let event, _):
            resultState = .pending
            resultMessage = event.explanation
        case .rejected(let event):
            resultState = .rejected
            let refusal = switch kind {
            case MoneyFlowKind.allowance: "This allowance was not paid out and did not change the accepted balance."
            case .repayment: "This payment was not made and did not change the accepted balance."
            case .deposit, .withdrawal, .loan: "This action was not recorded and did not change the accepted balance."
            }
            resultMessage = event.rejectionReason ?? refusal
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
    @FocusState private var isAmountFocused: Bool

    var body: some View {
        NavigationStack {
            SheetForm {
                VStack(alignment: .leading, spacing: EW.Space.five) {
                    Text("Set one simple weekly plan for \(ChildProfileCopy.childReference(nickname: store.snapshot.configuredChildNickname)). A plan is separate from an allowance event until it is paid out.")
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
                                .focused($isAmountFocused)
                                .accessibilityIdentifier("allowance-weekly-amount")
                        }
                        .padding(EW.Space.four)
                        .background(EW.Color.card, in: RoundedRectangle(cornerRadius: EW.Radius.medium, style: .continuous))
                        .ewAmountKeyboardAnchor("allowance-weekly-amount", isFocused: isAmountFocused)
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
                }
            } actions: {
                if store.latestParentMutationOutcome == .acceptedScheduleUnavailable, resultState != .recorded {
                    Button("Refresh allowance schedule") {
                        Task { await refreshAllowanceSchedule() }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(store.isLoading)
                }
                Button("Review allowance") { showReview = true }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(Money.parse(amount) == nil || (store.latestParentMutationOutcome == .acceptedScheduleUnavailable && resultState != .recorded))
                    .opacity(Money.parse(amount) == nil || (store.latestParentMutationOutcome == .acceptedScheduleUnavailable && resultState != .recorded) ? 0.45 : 1)
                Button("Save as draft on this \(DeviceCopy.deviceNoun)") { showDraft = true }
                    .buttonStyle(SecondaryButtonStyle(compact: true))
                    .accessibilityIdentifier("allowance-save-draft")
            }
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
                    let recorded = await store.setAllowance(command)
                    let outcome = store.latestParentMutationOutcome ?? .notRecorded
                    resultState = outcome.syncState
                    switch outcome {
                    case .recorded:
                        resultMessage = "The weekly allowance plan was recorded. Its next occurrence is separate from an allowance event until your parent pays it out."
                    case .waitingForCloud, .acceptedAwaitingReplica, .acceptedScheduleUnavailable:
                        resultMessage = outcome.message
                    case .notRecorded:
                        resultMessage = store.errorMessage ?? outcome.message
                    }
                    showReview = false
                    showDraft = false
                    // A successful create must leave the Parent area, with the
                    // new schedule visible. Staying on this sheet is what made
                    // a finished create look like it never completed.
                    if recorded || outcome != .notRecorded {
                        dismiss()
                    }
                }
                .ewDetailSheetPresentation()
            }
        }
    }

    private func refreshAllowanceSchedule() async {
        await store.refresh()
        guard store.errorMessage == nil, store.canStartParentMutation else {
            resultMessage = store.errorMessage ?? ParentMutationOutcome.acceptedScheduleUnavailable.message
            return
        }
        resultState = .recorded
        resultMessage = "The weekly allowance plan was recorded. The latest allowance schedule is ready."
    }
}

private struct AllowanceReviewView: View {
    @Environment(\.dismiss) private var dismiss
    let amountCents: Int
    let startDate: Date
    let confirm: () async -> Void

    var body: some View {
        SheetForm {
            VStack(alignment: .leading, spacing: EW.Space.five) {
                Text("Review allowance")
                    .font(EW.Font.heading)
                    .foregroundStyle(EW.Color.textPrimary)
                Text("Add \(Money(cents: amountCents).display) virtual dollars each week starting \(startDate.formatted(.dateTime.month(.abbreviated).day())).")
                    .font(EW.Font.body)
                    .foregroundStyle(EW.Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("This creates a plan for future occurrences. The plan is not an allowance event until it is accepted.")
                    .font(EW.Font.caption)
                    .foregroundStyle(EW.Color.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } actions: {
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
    }
}

#Preview("Deposit flow") {
    MoneyFlowView(kind: .deposit).environmentObject(WalletStore.preview())
}
