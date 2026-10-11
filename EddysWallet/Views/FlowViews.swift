import SwiftUI

public enum MoneyFlowKind: String, Identifiable, CaseIterable {
    case deposit
    case withdrawal
    case loan
    case repayment

    public var id: String { rawValue }

    var title: String {
        switch self {
        case .deposit: "Add deposit"
        case .withdrawal: "Record withdrawal"
        case .loan: "Create loan"
        case .repayment: "Pay toward loan"
        }
    }

    var commandKind: WalletCommandKind {
        switch self {
        case .deposit: .deposit
        case .withdrawal: .withdrawal
        case .loan: .loan
        case .repayment: .repayment
        }
    }
}

/// The parent's one money-recording sheet.
///
/// A deposit, a withdrawal and a loan payment are one step: the amount and an
/// optional reason, the balance the wallet will show, the virtual-money
/// notice, and a button that names the result ("Add US$5.00"), followed by a
/// short Recorded confirmation in the same sheet. Creating a loan sets a plan,
/// so it keeps a review step between amount and result.
///
/// Every step is a `SheetForm`, so the control that carries the step forward
/// lives in the pinned bottom bar and never scrolls away, whatever the sheet
/// height, text size, or keyboard state. Losing that control under the fold
/// is how a parent records nothing, or the wrong thing.
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
        case .deposit:
            return nil
        }
    }

    private var resultingBalance: Int {
        guard let cents = parsedCents else { return store.snapshot.acceptedBalanceCents }
        switch kind {
        case .withdrawal, .repayment: return store.snapshot.acceptedBalanceCents - cents
        case .deposit, .loan: return store.snapshot.acceptedBalanceCents + cents
        }
    }

    /// Creating a loan sets a plan, so it alone keeps a review step.
    private var usesReview: Bool { kind == .loan }

    private var canConfirm: Bool {
        parsedCents != nil && validationMessage == nil && !isSubmitting
    }

    /// The one-step button is the review sentence: it names what the tap
    /// records, with the amount, or just the action until there is one.
    private var primaryTitle: String {
        guard let cents = parsedCents else { return kind.title }
        let money = Money(cents: cents).display
        return switch kind {
        case .deposit: "Add \(money)"
        case .withdrawal: "Record \(money) used"
        case .repayment: "Pay \(money) toward loan"
        case .loan: "Review"
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

                if !usesReview {
                    VStack(alignment: .leading, spacing: EW.Space.three) {
                        reviewRow(label: "Balance after", value: Money(cents: resultingBalance).display)
                        if kind == .repayment, let loan = store.snapshot.loan {
                            reviewRow(
                                label: "Left to repay after",
                                value: Money(cents: max(loan.remainingCents - (parsedCents ?? 0), 0)).display
                            )
                        }
                    }
                    .ewCard()
                    virtualMoneyNotice
                }
            }
        } actions: {
            if usesReview {
                Button("Review") {
                    if validationMessage == nil {
                        focusedAmount = nil
                        step = .review
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(parsedCents == nil || validationMessage != nil)
                .opacity(parsedCents == nil || validationMessage != nil ? 0.45 : 1)
            } else {
                Button {
                    Task { await confirm() }
                } label: {
                    if isSubmitting {
                        ProgressView()
                            .frame(maxWidth: .infinity, minHeight: 52)
                    } else {
                        Text(primaryTitle)
                            .frame(maxWidth: .infinity, minHeight: 52)
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(!canConfirm)
                .opacity(canConfirm ? 1 : 0.45)
                .accessibilityIdentifier("money-flow-primary")
            }
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

                virtualMoneyNotice
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

    private var virtualMoneyNotice: some View {
        Text("Virtual practice only. These dollars are pretend, cannot be redeemed, and never move real money.")
            .font(EW.Font.body)
            .foregroundStyle(EW.Color.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(EW.Space.four)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(EW.Color.cardAlt, in: RoundedRectangle(cornerRadius: EW.Radius.medium, style: .continuous))
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
        }
    }

    /// A loan is paid back, so its review names paying; everything else that
    /// reaches a review is recorded.
    private var reviewHeading: String {
        switch kind {
        case .repayment: "Review before paying"
        case .deposit, .withdrawal, .loan: "Review before recording"
        }
    }

    private var confirmActionTitle: String {
        switch kind {
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
        guard let cents = parsedCents, validationMessage == nil, !isSubmitting else { return }
        isSubmitting = true
        focusedAmount = nil
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
            let childReference = ChildProfileCopy.childReference(nickname: store.snapshot.configuredChildNickname)
            let money = Money(cents: cents).display
            let balance = Money(cents: store.snapshot.acceptedBalanceCents).display
            resultMessage = switch kind {
            case .deposit: "Added \(money) to \(walletReference). New balance \(balance)."
            case .withdrawal: "Recorded \(money) used from \(walletReference). New balance \(balance)."
            case .repayment: "Paid \(money) toward the loan. \(Money(cents: store.snapshot.loan?.remainingCents ?? 0).display) left to repay."
            case .loan: "Lent \(money) to \(childReference) and added it to \(walletReference). \(money) to repay over time."
            }
        case .acceptedScheduleUnavailable:
            resultState = .recorded
            resultMessage = "This was recorded, but Cloud could not load the latest allowance schedule. Refresh before paying out allowance."
        case .pending(let event, _):
            resultState = .pending
            resultMessage = event.explanation
        case .acceptedAwaitingReplica(let event, _):
            resultState = .pending
            resultMessage = event.explanation
        case .rejected(let event):
            resultState = .rejected
            let refusal = switch kind {
            case .repayment: "This payment was not made and did not change the accepted balance."
            case .deposit, .withdrawal, .loan: "This action was not recorded and did not change the accepted balance."
            }
            resultMessage = event.rejectionReason ?? refusal
        }
        isSubmitting = false
        step = .result
    }
}

/// Shared parent-facing words for a weekly plan, so the editor, the Parent
/// area and the action tile all describe the same plan the same way.
enum AllowanceCopy {
    static func dayName(_ weekday: Int, calendar: Calendar = .current) -> String {
        calendar.weekdaySymbols[((weekday % 7) + 7) % 7]
    }

    static func veryShortDayName(_ weekday: Int, calendar: Calendar = .current) -> String {
        calendar.veryShortWeekdaySymbols[((weekday % 7) + 7) % 7]
    }

    /// "US$10.00 every Friday".
    static func summary(amountCents: Int, weekday: Int) -> String {
        "\(Money(cents: amountCents).display) every \(dayName(weekday))"
    }

    /// The amount the way the editor's field shows it: "10.00".
    static func fieldText(cents: Int) -> String {
        String(format: "%d.%02d", cents / 100, cents % 100)
    }
}

/// The weekly allowance editor.
///
/// It opens on the plan the wallet has - the current amount and payout day -
/// and keeps the day the plan started fixed, because the service refuses a
/// save that moves it and moving it would rewrite weeks already settled. A
/// changed amount or day saves in one step; the button itself is the review
/// sentence. With no live plan it is the create form: amount, payout day and
/// a start date. The sheet closes by itself once the wallet shows the saved
/// plan, and stays open with its status when Cloud has not confirmed it yet.
struct AllowanceView: View {
    @EnvironmentObject private var store: WalletStore
    @Environment(\.dismiss) private var dismiss
    /// Called with the saved plan's summary just before the sheet closes, so
    /// the Parent area can confirm the change in its own words.
    var onSaved: ((String) -> Void)?
    @State private var amount = ""
    @State private var weekday = 5
    @State private var startDate: Date
    @State private var didSeed = false
    /// The plan this sheet opened on, fixed for as long as it is up: a save
    /// that Cloud accepted without a readable schedule puts the plan into the
    /// wallet while the sheet is still open, and the sheet must not turn from
    /// the create form into the editor under the parent's thumb.
    @State private var editedPlan: AllowancePlan?
    @State private var resultState: SyncState?
    @State private var resultMessage = ""
    @State private var isSubmitting = false
    @FocusState private var isAmountFocused: Bool

    init(onSaved: ((String) -> Void)? = nil) {
        self.onSaved = onSaved
        #if DEBUG
        let initialStartDate = DebugLaunchScenario.allowanceStartDate() ?? .now
        #else
        let initialStartDate = Date.now
        #endif
        _startDate = State(initialValue: initialStartDate)
    }

    /// The plan being edited, or `nil` when the wallet had none (or the last
    /// one ended) when the sheet opened, which makes this the create form.
    private var existingPlan: AllowancePlan? { editedPlan }

    private var livePlan: AllowancePlan? {
        store.snapshot.allowance.flatMap { $0.isExhausted ? nil : $0 }
    }

    private var isEditing: Bool { existingPlan != nil }

    private var parsedCents: Int? { Money.parse(amount)?.cents }

    private var hasChanges: Bool {
        guard let plan = existingPlan else { return parsedCents != nil }
        guard let cents = parsedCents else { return false }
        return cents != plan.amountCents || weekday != plan.weekday
    }

    private var awaitsScheduleRefresh: Bool {
        store.latestParentMutationOutcome == .acceptedScheduleUnavailable && resultState != .recorded
    }

    private var canSave: Bool {
        parsedCents != nil && hasChanges && !isSubmitting && !awaitsScheduleRefresh
    }

    /// The first payout day the saved plan would wait for: the next chosen
    /// day on or after the start date, past any week already recorded.
    private var nextPayoutDate: Date {
        if let plan = existingPlan {
            let edited = try? plan.editing(amountCents: parsedCents ?? plan.amountCents, weekday: weekday, endDate: plan.endDate)
            return edited?.nextDate ?? plan.nextDate
        }
        return AllowancePlan.nextPayoutDay(onOrAfter: startDate, weekday: weekday)
    }

    private var saveTitle: String {
        guard let cents = parsedCents else { return "Save allowance" }
        if isEditing, !hasChanges { return "No changes yet" }
        return "Save \(AllowanceCopy.summary(amountCents: cents, weekday: weekday))"
    }

    private var intro: String {
        let child = ChildProfileCopy.childReference(nickname: store.snapshot.configuredChildNickname)
        return isEditing
            ? "Change how much \(child) gets each week, or the day it arrives. Weeks already added stay as they are."
            : "Set one simple weekly plan for \(child). Each week's allowance is added on its own once it is due."
    }

    var body: some View {
        NavigationStack {
            SheetForm {
                VStack(alignment: .leading, spacing: EW.Space.five) {
                    Text(intro)
                        .font(EW.Font.body)
                        .foregroundStyle(EW.Color.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    VStack(alignment: .leading, spacing: EW.Space.four) {
                        VStack(alignment: .leading, spacing: EW.Space.two) {
                            Text("Amount each week")
                                .font(EW.Font.captionUpper)
                                .foregroundStyle(EW.Color.textTertiary)
                            HStack {
                                Text("US$").foregroundStyle(EW.Color.textTertiary).font(EW.Font.bodyBold)
                                TextField("0.00", text: $amount)
                                    .font(EW.Font.heading)
                                    .keyboardType(.decimalPad)
                                    .textFieldStyle(.plain)
                                    .focused($isAmountFocused)
                                    .accessibilityLabel("Amount each week in virtual dollars")
                                    .accessibilityIdentifier("allowance-weekly-amount")
                            }
                            .padding(EW.Space.four)
                            .background(EW.Color.card, in: RoundedRectangle(cornerRadius: EW.Radius.medium, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: EW.Radius.medium, style: .continuous)
                                    .stroke(isAmountFocused ? EW.Color.primary : EW.Color.border, lineWidth: isAmountFocused ? 2 : 1)
                            }
                            .ewAmountKeyboardAnchor("allowance-weekly-amount", isFocused: isAmountFocused)
                        }
                        VStack(alignment: .leading, spacing: EW.Space.two) {
                            Text("Payout day")
                                .font(EW.Font.captionUpper)
                                .foregroundStyle(EW.Color.textTertiary)
                            dayRow
                        }
                        if let plan = existingPlan {
                            fixedStartRow(plan)
                        } else {
                            DatePicker("Starts", selection: $startDate, displayedComponents: .date)
                                .font(EW.Font.body)
                                .tint(EW.Color.primaryActive)
                        }
                    }
                    .ewCard(variant: .alt)

                    Text(nextPayoutCopy)
                        .font(EW.Font.caption)
                        .foregroundStyle(EW.Color.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("allowance-next-payout")

                    if let resultState {
                        VStack(alignment: .leading, spacing: EW.Space.two) {
                            StatusPill(state: resultState)
                            if !resultMessage.isEmpty {
                                Text(resultMessage)
                                    .font(EW.Font.caption)
                                    .foregroundStyle(resultState == .rejected ? EW.Color.red600 : EW.Color.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("allowance-result")
                    }
                }
            } actions: {
                if awaitsScheduleRefresh {
                    Button("Refresh allowance schedule") {
                        Task { await refreshAllowanceSchedule() }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(store.isLoading)
                }
                Button {
                    Task { await save() }
                } label: {
                    if isSubmitting {
                        ProgressView()
                            .frame(maxWidth: .infinity, minHeight: 52)
                    } else {
                        Text(saveTitle)
                            .frame(maxWidth: .infinity, minHeight: 52)
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(!canSave)
                .opacity(canSave ? 1 : 0.45)
                .accessibilityIdentifier("allowance-save")
            }
            .navigationTitle(isEditing ? "Allowance" : "Set allowance")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isSubmitting)
                }
            }
            .onAppear(perform: seed)
        }
        .interactiveDismissDisabled(isSubmitting)
    }

    private var dayRow: some View {
        HStack(spacing: EW.Space.two) {
            ForEach(0..<7, id: \.self) { day in
                let isSelected = day == weekday
                Button {
                    weekday = day
                } label: {
                    Text(AllowanceCopy.veryShortDayName(day))
                        .font(EW.Font.bodyBold)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .foregroundStyle(isSelected ? EW.Color.white : EW.Color.textSecondary)
                        .background(isSelected ? EW.Color.gold600 : EW.Color.card, in: RoundedRectangle(cornerRadius: EW.Radius.small, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: EW.Radius.small, style: .continuous)
                                .stroke(EW.Color.border, lineWidth: isSelected ? 0 : 1)
                        }
                        .contentShape(RoundedRectangle(cornerRadius: EW.Radius.small, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(AllowanceCopy.dayName(day))
                .accessibilityAddTraits(isSelected ? [.isSelected] : [])
                .accessibilityIdentifier("allowance-weekday-\(day)")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("allowance-weekday")
    }

    /// The start date is a creation-time fact of the plan, shown but never
    /// edited: the service refuses a save that moves it, and moving it would
    /// rewrite weeks already settled.
    private func fixedStartRow(_ plan: AllowancePlan) -> some View {
        HStack(alignment: .top, spacing: EW.Space.three) {
            Image(systemName: "lock.fill")
                .foregroundStyle(EW.Color.textTertiary)
                .accessibilityHidden(true)
            Text(Self.fixedStartCopy(startDate: plan.startDate))
                .font(EW.Font.caption)
                .foregroundStyle(EW.Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(EW.Space.three)
        .background(EW.Color.card, in: RoundedRectangle(cornerRadius: EW.Radius.medium, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("allowance-fixed-start")
    }

    static func fixedStartCopy(startDate: Date?) -> String {
        let started = startDate.map { "Started \($0.formatted(.dateTime.month(.abbreviated).day().year())). " } ?? ""
        return "\(started)The start date stays with the plan. Changing it would rewrite weeks already settled."
    }

    private var nextPayoutCopy: String {
        let day = nextPayoutDate.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        let lead = isEditing ? "Next payout \(day)\(hasChanges ? " at the new amount or day" : "")." : "First payout \(day)."
        if isEditing, !store.missedAllowancePayouts.isEmpty {
            return "\(lead) Saving a change moves the plan past the \(store.missedAllowancePayouts.count) missed weeks, so pay those out first if they are owed."
        }
        return "\(lead) Each week's allowance is added on its own once it is due; weeks that were missed show under Missed allowance."
    }

    private func seed() {
        guard !didSeed else { return }
        didSeed = true
        editedPlan = livePlan
        if let plan = editedPlan {
            amount = AllowanceCopy.fieldText(cents: plan.amountCents)
            weekday = plan.weekday
        } else {
            amount = "10.00"
            // The amount is what a new plan is about, so the create form opens
            // ready to type; the editor opens on the plan instead.
            isAmountFocused = true
        }
    }

    private func save() async {
        guard let cents = parsedCents, canSave else { return }
        isSubmitting = true
        isAmountFocused = false
        let command = if let plan = existingPlan {
            AllowanceRuleCommand(editing: plan, amountCents: cents, weekday: weekday)
        } else {
            AllowanceRuleCommand(
                amountCents: cents,
                weekday: weekday,
                startDate: AllowancePlan.nextPayoutDay(onOrAfter: startDate, weekday: weekday)
            )
        }
        let recorded = await store.setAllowance(command)
        let submittedRuleID = store.latestSubmittedAllowanceRuleID
        let outcome = store.latestParentMutationOutcome ?? .notRecorded
        let refreshedPlan = store.snapshot.allowance
        resultState = outcome.syncState
        switch outcome {
        case .recorded:
            resultMessage = "The weekly plan was saved."
        case .waitingForCloud, .acceptedAwaitingReplica, .acceptedScheduleUnavailable:
            resultMessage = outcome.message
        case .notRecorded:
            resultMessage = store.errorMessage ?? outcome.message
        }
        isSubmitting = false
        if recorded,
           outcome == .recorded,
           let submittedRuleID,
           let refreshedPlan,
           refreshedPlan.remoteID == submittedRuleID {
            onSaved?(AllowanceCopy.summary(amountCents: refreshedPlan.amountCents, weekday: refreshedPlan.weekday))
            dismiss()
        }
    }

    private func refreshAllowanceSchedule() async {
        await store.refresh()
        guard store.errorMessage == nil, store.canStartParentMutation else {
            resultMessage = store.errorMessage ?? ParentMutationOutcome.acceptedScheduleUnavailable.message
            return
        }
        guard let submittedAllowanceRuleID = store.latestSubmittedAllowanceRuleID,
              let plan = store.snapshot.allowance,
              plan.remoteID == submittedAllowanceRuleID else {
            resultMessage = ParentMutationOutcome.acceptedScheduleUnavailable.message
            return
        }
        resultState = .recorded
        resultMessage = "The weekly plan was saved. The latest allowance schedule is ready."
        onSaved?(AllowanceCopy.summary(amountCents: plan.amountCents, weekday: plan.weekday))
        dismiss()
    }
}

#Preview("Deposit flow") {
    MoneyFlowView(kind: .deposit).environmentObject(WalletStore.preview())
}
