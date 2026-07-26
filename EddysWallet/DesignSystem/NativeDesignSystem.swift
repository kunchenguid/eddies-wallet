import SwiftUI

/// Native SwiftUI owner for the values copied from design-system/tokens.
public enum EW {
    public enum Color {
        public static let green50 = SwiftUI.Color(red: 0.94, green: 0.98, blue: 0.96)
        public static let green100 = SwiftUI.Color(red: 0.87, green: 0.95, blue: 0.90)
        public static let green300 = SwiftUI.Color(red: 0.57, green: 0.82, blue: 0.68)
        public static let green500 = SwiftUI.Color(red: 0.23, green: 0.68, blue: 0.47)
        public static let green600 = SwiftUI.Color(red: 0.13, green: 0.58, blue: 0.39)
        public static let green700 = SwiftUI.Color(red: 0.10, green: 0.47, blue: 0.31)
        public static let green900 = SwiftUI.Color(red: 0.08, green: 0.29, blue: 0.21)

        public static let gold50 = SwiftUI.Color(red: 1.00, green: 0.98, blue: 0.91)
        public static let gold100 = SwiftUI.Color(red: 0.98, green: 0.94, blue: 0.77)
        public static let gold300 = SwiftUI.Color(red: 0.94, green: 0.79, blue: 0.40)
        public static let gold500 = SwiftUI.Color(red: 0.88, green: 0.67, blue: 0.16)
        public static let gold600 = SwiftUI.Color(red: 0.74, green: 0.54, blue: 0.10)
        public static let gold700 = SwiftUI.Color(red: 0.55, green: 0.39, blue: 0.08)

        public static let peach50 = SwiftUI.Color(red: 1.00, green: 0.97, blue: 0.93)
        public static let peach100 = SwiftUI.Color(red: 0.99, green: 0.91, blue: 0.82)
        public static let peach300 = SwiftUI.Color(red: 0.95, green: 0.72, blue: 0.54)
        public static let peach500 = SwiftUI.Color(red: 0.89, green: 0.53, blue: 0.34)
        public static let peach600 = SwiftUI.Color(red: 0.80, green: 0.40, blue: 0.25)
        public static let peach700 = SwiftUI.Color(red: 0.65, green: 0.30, blue: 0.19)

        public static let red100 = SwiftUI.Color(red: 0.98, green: 0.88, blue: 0.85)
        public static let red600 = SwiftUI.Color(red: 0.69, green: 0.23, blue: 0.18)

        public static let ink900 = SwiftUI.Color(red: 0.15, green: 0.18, blue: 0.20)
        public static let ink700 = SwiftUI.Color(red: 0.31, green: 0.34, blue: 0.36)
        public static let ink500 = SwiftUI.Color(red: 0.49, green: 0.51, blue: 0.52)
        public static let ink300 = SwiftUI.Color(red: 0.72, green: 0.73, blue: 0.73)
        public static let ink200 = SwiftUI.Color(red: 0.82, green: 0.82, blue: 0.80)
        public static let ink100 = SwiftUI.Color(red: 0.90, green: 0.90, blue: 0.88)
        public static let cream50 = SwiftUI.Color(red: 1.00, green: 0.99, blue: 0.96)
        public static let cream100 = SwiftUI.Color(red: 0.98, green: 0.96, blue: 0.91)
        public static let cream200 = SwiftUI.Color(red: 0.95, green: 0.92, blue: 0.84)
        public static let white = SwiftUI.Color.white

        public static let appBackground = cream100
        public static let card = white
        public static let cardAlt = cream200
        public static let textPrimary = ink900
        public static let textSecondary = ink700
        public static let textTertiary = ink500
        public static let border = ink100
        public static let primary = green500
        public static let primaryHover = green600
        public static let primaryActive = green700
        public static let primaryTint = green100
        public static let goldTint = gold100
        public static let peachTint = peach100
        public static let dangerTint = red100
    }

    public enum Space {
        public static let one: CGFloat = 4
        public static let two: CGFloat = 8
        public static let three: CGFloat = 12
        public static let four: CGFloat = 16
        public static let five: CGFloat = 20
        public static let six: CGFloat = 24
        public static let seven: CGFloat = 32
        public static let eight: CGFloat = 40
        public static let nine: CGFloat = 48
        public static let ten: CGFloat = 64
        public static let screenMargin: CGFloat = 20
    }

    public enum Radius {
        public static let small: CGFloat = 10
        public static let medium: CGFloat = 16
        public static let large: CGFloat = 20
        public static let extraLarge: CGFloat = 28
        public static let pill: CGFloat = 999
    }

    public enum Font {
        public static let display = SwiftUI.Font.system(.title, design: .rounded).weight(.bold)
        public static let displayLarge = SwiftUI.Font.system(.largeTitle, design: .rounded).weight(.bold)
        public static let displayBalance = SwiftUI.Font.system(.largeTitle, design: .rounded).weight(.bold)
        public static let heading = SwiftUI.Font.system(.title3, design: .rounded).weight(.bold)
        public static let headingSmall = SwiftUI.Font.system(.headline, design: .rounded).weight(.semibold)
        public static let body = SwiftUI.Font.system(.body, design: .rounded)
        public static let bodyBold = SwiftUI.Font.system(.body, design: .rounded).weight(.bold)
        public static let caption = SwiftUI.Font.system(.caption, design: .rounded).weight(.semibold)
        public static let captionUpper = SwiftUI.Font.system(.caption2, design: .rounded).weight(.bold)
    }
}

public extension View {
    func ewCard(variant: CardVariant = .standard) -> some View {
        self
            .padding(EW.Space.six)
            .background(variant == .alt ? EW.Color.cardAlt : EW.Color.card, in: RoundedRectangle(cornerRadius: EW.Radius.large, style: .continuous))
            .overlay {
                if variant == .standard {
                    RoundedRectangle(cornerRadius: EW.Radius.large, style: .continuous)
                        .stroke(EW.Color.border, lineWidth: 1)
                }
            }
            .shadow(color: EW.Color.ink900.opacity(0.06), radius: 3, x: 0, y: 1)
    }
}

public enum CardVariant {
    case standard
    case alt
}

public struct MoneyAmount: View {
    public let cents: Int
    public let font: SwiftUI.Font
    public let color: SwiftUI.Color

    public init(cents: Int, font: SwiftUI.Font = EW.Font.heading, color: SwiftUI.Color = EW.Color.textPrimary) {
        self.cents = cents
        self.font = font
        self.color = color
    }

    public var body: some View {
        Text(Money(cents: cents).display)
            .font(font)
            .foregroundStyle(color)
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .accessibilityLabel("\(Money(cents: cents).display) virtual dollars")
    }
}

public struct StatusPill: View {
    public let state: SyncState

    public init(state: SyncState) { self.state = state }

    private var icon: String {
        switch state {
        case .recorded: "checkmark.circle.fill"
        case .pending: "clock.fill"
        case .rejected: "exclamationmark.circle.fill"
        case .draft: "pencil"
        }
    }

    private var foreground: SwiftUI.Color {
        switch state {
        case .recorded: EW.Color.green700
        case .pending: EW.Color.gold700
        case .rejected: EW.Color.red600
        case .draft: EW.Color.textSecondary
        }
    }

    private var background: SwiftUI.Color {
        switch state {
        case .recorded: EW.Color.green100
        case .pending: EW.Color.goldTint
        case .rejected: EW.Color.dangerTint
        case .draft: EW.Color.ink100
        }
    }

    public var body: some View {
        Label(state.label, systemImage: icon)
            .font(EW.Font.captionUpper)
            .foregroundStyle(foreground)
            .padding(.horizontal, EW.Space.three)
            .padding(.vertical, EW.Space.two)
            .background(background, in: Capsule())
            .accessibilityElement(children: .combine)
            .accessibilityLabel(state.label)
    }
}

public struct RoleSwitcher: View {
    @Binding public var role: UserRole
    public let childTitle: String
    public let onSelect: (UserRole) -> Void

    public init(role: Binding<UserRole>, childTitle: String = "Child's view", onSelect: @escaping (UserRole) -> Void) {
        self._role = role
        self.childTitle = childTitle
        self.onSelect = onSelect
    }

    public var body: some View {
        HStack(spacing: 2) {
            ForEach(UserRole.allCases) { item in
                Button {
                    onSelect(item)
                } label: {
                    Text(item == .child ? childTitle : item.title)
                        .font(EW.Font.bodyBold)
                        .foregroundStyle(role == item ? EW.Color.white : EW.Color.textSecondary)
                        .padding(.horizontal, EW.Space.four)
                        .padding(.vertical, EW.Space.two + 2)
                        .frame(minHeight: 40)
                        .background(role == item ? EW.Color.primary : .clear, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(role == item ? .isSelected : [])
            }
        }
        .padding(4)
        .background(EW.Color.cardAlt, in: Capsule())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Switch person")
    }
}

public struct SectionHeader: View {
    public let title: String
    public let actionTitle: String?
    public let action: (() -> Void)?

    public init(_ title: String, actionTitle: String? = nil, action: (() -> Void)? = nil) {
        self.title = title
        self.actionTitle = actionTitle
        self.action = action
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(EW.Font.heading)
                .foregroundStyle(EW.Color.textPrimary)
            Spacer()
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(EW.Font.bodyBold)
                    .foregroundStyle(EW.Color.primaryActive)
            }
        }
    }
}

public struct IconBadge: View {
    public let systemName: String
    public let foreground: SwiftUI.Color
    public let background: SwiftUI.Color
    public let size: CGFloat

    public init(_ systemName: String, foreground: SwiftUI.Color, background: SwiftUI.Color, size: CGFloat = 44) {
        self.systemName = systemName
        self.foreground = foreground
        self.background = background
        self.size = size
    }

    public var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size * 0.45, weight: .semibold))
            .foregroundStyle(foreground)
            .frame(width: size, height: size)
            .background(background, in: Circle())
            .accessibilityHidden(true)
    }
}

public struct PrimaryButtonStyle: ButtonStyle {
    public var compact = false

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(EW.Font.bodyBold)
            .foregroundStyle(EW.Color.white)
            .frame(maxWidth: .infinity, minHeight: compact ? 42 : 52)
            .padding(.horizontal, compact ? EW.Space.four : EW.Space.six)
            .background(EW.Color.primary, in: RoundedRectangle(cornerRadius: EW.Radius.medium, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

public struct SecondaryButtonStyle: ButtonStyle {
    public var compact = false

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(EW.Font.bodyBold)
            .foregroundStyle(EW.Color.textPrimary)
            .frame(maxWidth: .infinity, minHeight: compact ? 42 : 52)
            .padding(.horizontal, compact ? EW.Space.four : EW.Space.six)
            .background(EW.Color.cardAlt, in: RoundedRectangle(cornerRadius: EW.Radius.medium, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

public struct FreshnessLabel: View {
    public let date: Date
    public let isStale: Bool

    public init(date: Date, isStale: Bool) {
        self.date = date
        self.isStale = isStale
    }

    public var body: some View {
        Label {
            Text("Last updated \(date.formatted(date: .omitted, time: .shortened))")
        } icon: {
            Image(systemName: isStale ? "arrow.clockwise" : "checkmark.circle")
        }
        .font(EW.Font.caption)
        .foregroundStyle(isStale ? EW.Color.textSecondary : EW.Color.green700)
        .accessibilityElement(children: .combine)
    }
}
