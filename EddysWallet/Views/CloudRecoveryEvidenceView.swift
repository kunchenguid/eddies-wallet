import SwiftUI

/// Local, privacy-safe Cloud recovery readout, visible in every build
/// including Release. It renders only aggregate scan counts and outcome
/// classes from `CloudRecoveryEvidence` - never a signed payload, identifier,
/// account value, session value, or error detail - and nothing here persists
/// or leaves the device. It answers "did this device's StoreKit store surface
/// the Cloud transaction at all" without exposing anything about the account.
struct CloudRecoveryEvidenceView: View {
    let subscriptions: CloudSubscriptionStore?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: EW.Space.three) {
                Text("Cloud recovery details")
                    .font(EW.Font.headingSmall)
                Text("Local diagnostics only. Nothing here leaves this \(DeviceCopy.deviceNoun).")
                    .font(EW.Font.caption)
                    .foregroundStyle(EW.Color.textSecondary)
                if let subscriptions {
                    CloudRecoveryEvidenceRows(subscriptions: subscriptions)
                } else {
                    Text("Cloud recovery has not run on this \(DeviceCopy.deviceNoun).")
                        .font(EW.Font.body)
                        .foregroundStyle(EW.Color.textSecondary)
                        .accessibilityIdentifier("cloud-recovery-evidence-empty")
                }
            }
            .padding(EW.Space.five)
        }
        .background(EW.Color.appBackground)
    }
}

private struct CloudRecoveryEvidenceRows: View {
    @ObservedObject var subscriptions: CloudSubscriptionStore

    var body: some View {
        ForEach(subscriptions.recoveryEvidence.displayRows) { row in
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                    .font(EW.Font.body)
                    .foregroundStyle(EW.Color.textPrimary)
                Text(row.value)
                    .font(EW.Font.caption)
                    .foregroundStyle(EW.Color.textSecondary)
                if let detail = row.detail {
                    Text(detail)
                        .font(EW.Font.caption)
                        .foregroundStyle(EW.Color.textTertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .ewCard(variant: .alt)
            .accessibilityIdentifier("cloud-recovery-evidence-\(row.id)")
        }
    }
}
