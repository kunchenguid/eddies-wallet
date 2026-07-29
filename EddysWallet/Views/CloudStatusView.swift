import SwiftUI

/// Parent-only Cloud status. Price and purchase controls are intentionally
/// absent until the backend capability and real StoreKit products both load.
struct CloudStatusView: View {
    @EnvironmentObject private var store: WalletStore

    var body: some View {
        VStack(alignment: .leading, spacing: EW.Space.three) {
            Label("Cloud backup & sync", systemImage: "icloud")
                .font(EW.Font.headingSmall)
                .foregroundStyle(EW.Color.textPrimary)
            switch store.cloudEntitlement {
            case .active(let accessUntil, _):
                Text("Cloud is on through \(accessUntil.formatted(date: .abbreviated, time: .omitted)). Backed up and synced across devices using the same parent Apple account.")
                    .font(EW.Font.body)
                    .foregroundStyle(EW.Color.textSecondary)
            case .billingGrace:
                Text("Cloud is still on while the App Store retries billing.")
                    .font(EW.Font.body)
                    .foregroundStyle(EW.Color.textSecondary)
            case .expired, .refunded, .revoked, .billingRetry:
                Text("Cloud ended. This wallet now works on this device only. Nothing was deleted.")
                    .font(EW.Font.body)
                    .foregroundStyle(EW.Color.textSecondary)
            default:
                Text("This wallet is saved only on this \(DeviceCopy.deviceNoun). Cloud adds backup and sync on devices using the same parent Apple account.")
                    .font(EW.Font.body)
                    .foregroundStyle(EW.Color.textSecondary)
                Text("Cloud plans are unavailable right now. Your wallet still works on this device.")
                    .font(EW.Font.caption)
                    .foregroundStyle(EW.Color.gold700)
            }
            Text("Cloud is optional. Your wallet keeps working on this device without it.")
                .font(EW.Font.caption)
                .foregroundStyle(EW.Color.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .ewCard(variant: .alt)
        .accessibilityIdentifier("cloud-backup-sync-card")
    }
}
