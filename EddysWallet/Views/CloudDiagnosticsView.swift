#if DEBUG
import StoreKit
import SwiftUI

/// What the proof surface currently knows.
///
/// `loading` is deliberately distinguishable from every terminal outcome: an
/// operator - or a UI test - must be able to tell "StoreKit has not answered
/// yet" from "StoreKit answered, and the answer is wrong". Resolving products
/// can take an unbounded first call (under `xcodebuild` it is a live App Store
/// round trip), so a surface that blurred the two would make a slow store
/// indistinguishable from a broken one.
enum CloudDiagnosticsStatus: Equatable {
    /// StoreKit has not answered yet. Never a verdict about the products.
    case loading
    case loaded(count: Int)
    case missingProducts(found: Int)
    case storeKitError

    var label: String {
        switch self {
        case .loading: "loading"
        case .loaded(let count): "loaded \(count) products"
        case .missingProducts(let found): "missing products (\(found))"
        case .storeKitError: "storekit error"
        }
    }

    /// True once StoreKit has answered, whatever the answer was.
    var isTerminal: Bool { self != .loading }
}

/// Debug-only StoreKit proof surface.
///
/// It asks StoreKit for the two Cloud products and renders exactly what the
/// store returned, so a running Debug app (or a UI test driving it) can prove
/// StoreKit resolves the real product identifiers and localized prices. Which
/// store answers depends on how the app was launched: Xcode applies the shared
/// scheme's StoreKit Configuration, while `xcodebuild` ignores that setting and
/// lets StoreKit resolve the live App Store catalog. Either way this surface
/// reports only what it was told - it never grants Cloud, never talks to the
/// backend, and is compiled out of Release.
struct CloudDiagnosticsView: View {
    @State private var rows: [Row] = []
    @State private var status: CloudDiagnosticsStatus = .loading

    private struct Row: Identifiable {
        let id: String
        let displayPrice: String
        let period: String
        let familyShareable: Bool
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: EW.Space.three) {
                Text("StoreKit diagnostics")
                    .font(EW.Font.headingSmall)
                Text("Debug-only. Values come from whichever store StoreKit resolved.")
                    .font(EW.Font.caption)
                    .foregroundStyle(EW.Color.textSecondary)
                Text(status.label)
                    .font(EW.Font.caption)
                    .foregroundStyle(EW.Color.textTertiary)
                    .accessibilityIdentifier("storekit-diagnostics-status")
                ForEach(rows) { row in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.id)
                            .font(EW.Font.body)
                            .accessibilityIdentifier("storekit-product-\(row.id)")
                        Text(row.displayPrice)
                            .font(EW.Font.caption)
                            .accessibilityIdentifier("storekit-price-\(row.id)")
                        Text("\(row.period) · family shareable: \(row.familyShareable ? "yes" : "no")")
                            .font(EW.Font.caption)
                            .foregroundStyle(EW.Color.textSecondary)
                            .accessibilityIdentifier("storekit-terms-\(row.id)")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .ewCard(variant: .alt)
                }
            }
            .padding(EW.Space.five)
        }
        .background(EW.Color.appBackground)
        .task { await load() }
    }

    private func load() async {
        do {
            let products = try await Product.products(for: CloudProductID.ordered)
            rows = CloudProductID.ordered.compactMap { identifier in
                guard let product = products.first(where: { $0.id == identifier }) else { return nil }
                // A deterministic, lowercase description so the proof surface is
                // stable across locales and StoreKit's own formatting.
                let period: String = {
                    guard let subscription = product.subscription else { return "no subscription period" }
                    let unit: String = switch subscription.subscriptionPeriod.unit {
                    case .day: "day"
                    case .week: "week"
                    case .month: "month"
                    case .year: "year"
                    @unknown default: "period"
                    }
                    return "\(subscription.subscriptionPeriod.value) \(unit)"
                }()
                return Row(
                    id: product.id,
                    displayPrice: product.displayPrice,
                    period: period,
                    familyShareable: product.isFamilyShareable
                )
            }
            status = rows.count == CloudProductID.ordered.count
                ? .loaded(count: rows.count)
                : .missingProducts(found: rows.count)
        } catch {
            rows = []
            status = .storeKitError
        }
    }
}
#endif
