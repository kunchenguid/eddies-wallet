#if DEBUG
import StoreKit
import SwiftUI

/// Debug-only StoreKit proof surface.
///
/// It asks StoreKit for the two Cloud products and renders exactly what the
/// store returned, so a running Debug app (or a UI test driving it) can prove
/// the checked-in StoreKit Configuration selected by the shared scheme resolves
/// the real product identifiers and localized prices. It never grants Cloud,
/// never talks to the backend, and is compiled out of Release.
struct CloudDiagnosticsView: View {
    @State private var rows: [Row] = []
    @State private var status = "loading"

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
                Text("Debug-only. Values come from StoreKit's selected configuration.")
                    .font(EW.Font.caption)
                    .foregroundStyle(EW.Color.textSecondary)
                Text(status)
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
            status = rows.count == CloudProductID.ordered.count ? "loaded \(rows.count) products" : "missing products (\(rows.count))"
        } catch {
            rows = []
            status = "storekit error"
        }
    }
}
#endif
