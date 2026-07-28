import SwiftUI
import UIKit

/// UI copy that names the device ("iPad"/"iPhone"). The fixed sync
/// vocabulary ("Draft on this iPad", PRD 10) is deliberately not derived
/// from this.
enum DeviceCopy {
    static func deviceNoun(for idiom: UIUserInterfaceIdiom) -> String {
        idiom == .pad ? "iPad" : "iPhone"
    }

    @MainActor
    static var deviceNoun: String {
        deviceNoun(for: UIDevice.current.userInterfaceIdiom)
    }
}

/// Card components shared by the kid home and the Parent area.

struct ActivityListCard: View {
    let events: [WalletEvent]
    let onSelect: (WalletEvent) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(events.enumerated()), id: \.element.id) { index, event in
                ActivityRowView(event: event) {
                    onSelect(event)
                }
                if index < events.count - 1 {
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
}

struct ActivityRowView: View {
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
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(event.displayReason), \(event.signedAmount.display), \(event.syncState.label)")
    }
}

struct LoanCardView: View {
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
                    .fixedSize(horizontal: false, vertical: true)
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
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .buttonStyle(.plain)
        .ewCard(variant: .alt)
        .accessibilityHint(isParent ? "Opens loan details and repayment" : "Opens read-only loan details")
    }
}

/// Shared geometry for parent-area action controls. Background fill, stroke,
/// and hit target must use this same continuous corner radius so the tinted
/// fill never leaves unfilled wedges at the corners.
enum ActionButtonMetrics {
    static let cornerRadius = EW.Radius.medium
    static let minHeight: CGFloat = 52
    static let horizontalPadding = EW.Space.four
    static var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }
}

struct ActionButton: View {
    let title: String
    let icon: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon)
        }
        .buttonStyle(ActionButtonStyle(tint: tint))
    }
}

/// Draws fill and chrome with one continuous rounded rect so the visual shape
/// and hit target stay aligned (unlike `.bordered`, whose system capsule does
/// not match an outer `EW.Radius.medium` card background).
private struct ActionButtonStyle: ButtonStyle {
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(EW.Font.bodyBold)
            .foregroundStyle(tint)
            .labelStyle(.titleAndIcon)
            .frame(maxWidth: .infinity, minHeight: ActionButtonMetrics.minHeight, alignment: .leading)
            .padding(.horizontal, ActionButtonMetrics.horizontalPadding)
            .background(
                tint.opacity(configuration.isPressed ? 0.22 : 0.14),
                in: ActionButtonMetrics.shape
            )
            .overlay {
                ActionButtonMetrics.shape
                    .stroke(tint.opacity(configuration.isPressed ? 0.45 : 0.28), lineWidth: 1)
            }
            .contentShape(ActionButtonMetrics.shape)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct AppleSignInButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(EW.Font.bodyBold)
            .foregroundStyle(Color.white)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(Color.black, in: RoundedRectangle(cornerRadius: EW.Radius.medium, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
