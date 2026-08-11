import SwiftUI
import UIKit

/// Parent-only readout of the last request this device could not complete.
///
/// The kid home says only what a kid needs ("hard to reach right now"); the
/// exact failure lives here, behind the parent PIN, so a parent who is
/// reporting a problem can say what actually happened instead of "it didn't
/// work". It renders exactly `TransportDiagnostic.displayRows` - a failure
/// class, its numeric code, whether an underlying error existed, the route
/// template, the HTTP status when there was a response, how long it took, and
/// when - and the copy action shares the same rows, so the copied text can
/// never say more than this screen does. Nothing here is stored and nothing is
/// sent anywhere; it leaves the device only if a parent pastes it somewhere.
///
/// It opens at full height rather than the usual detail half-sheet: the whole
/// point is to read the readout and copy it in one pass, and a half sheet would
/// hide most of it behind a drag.
struct ConnectionDetailsView: View {
    let diagnostic: TransportDiagnostic
    @Environment(\.dismiss) private var dismiss
    @State private var didCopy = false

    var body: some View {
        NavigationStack {
            SheetForm {
                VStack(alignment: .leading, spacing: EW.Space.four) {
                    Text("This is what happened the last time this \(DeviceCopy.deviceNoun) could not finish a wallet request. It holds no name, account, sign-in, or wallet information, so it is safe to share if you report the problem.")
                        .font(EW.Font.body)
                        .foregroundStyle(EW.Color.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    VStack(spacing: 0) {
                        ForEach(Array(diagnostic.displayRows.enumerated()), id: \.element.id) { index, row in
                            if index > 0 {
                                Divider().overlay(EW.Color.border)
                            }
                            detailRow(row)
                        }
                    }
                    .padding(.horizontal, EW.Space.five)
                    .background(EW.Color.card, in: RoundedRectangle(cornerRadius: EW.Radius.large, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: EW.Radius.large, style: .continuous)
                            .stroke(EW.Color.border, lineWidth: 1)
                    }
                }
            } actions: {
                Button {
                    UIPasteboard.general.string = diagnostic.shareableSummary
                    didCopy = true
                } label: {
                    Label(didCopy ? "Copied" : "Copy details", systemImage: didCopy ? "checkmark" : "doc.on.doc")
                        .frame(maxWidth: .infinity, minHeight: 52)
                }
                .buttonStyle(PrimaryButtonStyle())
                .accessibilityIdentifier("copy-connection-details")
            }
            .navigationTitle("Connection details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func detailRow(_ row: TransportDiagnostic.Row) -> some View {
        VStack(alignment: .leading, spacing: EW.Space.one) {
            Text(row.title)
                .font(EW.Font.captionUpper)
                .foregroundStyle(EW.Color.textTertiary)
            Text(row.value)
                .font(EW.Font.bodyBold)
                .foregroundStyle(EW.Color.textPrimary)
                .textSelection(.enabled)
            if let detail = row.detail {
                Text(detail)
                    .font(EW.Font.caption)
                    .foregroundStyle(EW.Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .padding(.vertical, EW.Space.three)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("connection-detail-\(row.id)")
    }
}

#Preview("Connection details") {
    ConnectionDetailsView(
        diagnostic: TransportDiagnostic(
            category: .timedOut,
            code: -1001,
            hasUnderlyingError: true,
            route: "/v1/child-view",
            httpStatus: nil,
            elapsedMilliseconds: 30_012
        )
    )
}
