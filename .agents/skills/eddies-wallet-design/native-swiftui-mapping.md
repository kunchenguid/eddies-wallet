# Native SwiftUI mapping

The source design system in this directory is the visual source of truth. The production iOS implementation lives in `EddysWallet/DesignSystem/NativeDesignSystem.swift` and maps the same tokens to native SwiftUI.

| Source token/component | Native owner | Notes |
| --- | --- | --- |
| `tokens/colors.css` | `EW.Color` | Warm cream surfaces, emerald primary, gold allowance/pending, peach loans, red only for rejection. CSS OKLCH values are represented by sRGB SwiftUI colors with the same visual intent. |
| `tokens/spacing.css` | `EW.Space` | 4px-derived scale; screen margin is 20px. |
| `tokens/radii.css` | `EW.Radius` | 10 / 16 / 20 / 28px and pill. |
| `tokens/shadows.css` | `View.ewCard` | Warm charcoal, low-opacity elevation. |
| `tokens/typography.css` | `EW.Font` | Uses Dynamic Type-compatible rounded system fonts. |
| `Button`, `IconButton` | `PrimaryButtonStyle`, `SecondaryButtonStyle`, native `Button` | Native touch targets and accessibility labels. |
| `StatusPill` | `StatusPill` | Fixed Recorded / Waiting to sync / Not recorded / Draft on this iPad vocabulary. |
| `RoleSwitch` | retired; `ParentDoorLabel` + `ParentGateView` | The peer role switch was replaced by the kid-first model (2026-07): the kid home shows a quiet Parent door, and the PIN gate opens a transient full-screen Parent area managed by `WalletStore` elevation. |
| `BalanceDisplay` | `MoneyAmount` and wallet hero cards | Exact minor-unit money formatting with `US$` and two decimals. |
| `ActivityRow` | `ActivityRowView` | Native SF Symbols stand in for the supplied Lucide-derived SVGs. |
| `LoanCard` | `LoanCardView` | Peach treatment, progress, and parent-only repayment affordance. |
| `PinPad` | `PINKeypad` in `ParentGateView` | Native buttons, full-screen gate, bounded retries with cooldown, no child access to parent controls. |
| `Card`, `Modal` | `ewCard` and SwiftUI `.sheet` | Native sheets provide the review/detail presentation. |

## Asset notes

- `assets/app-icon/` in this skill is copied into `EddysWallet/Assets.xcassets/AppIcon.appiconset` for the native app icon. iOS applies its own corner mask and gloss.
- The supplied icons are SVGs. SwiftUI uses the closest native SF Symbols so the app remains vector, Dynamic Type-aware, and accessible. The icon set remains copied for future asset replacement.
- The supplied fonts are WOFF2 web fonts. iOS does not load WOFF2 directly as a bundled font, so the native implementation uses `Font.system(..., design: .rounded)` as the documented fallback. If approved font files become available in OTF/TTF form, `EW.Font` is the single replacement point.
- No web/React runtime is embedded in the app. `ui_kits/ios-app/` is retained as provenance and interaction reference only.

## Provenance

Copied from `/Users/kunchen/Downloads/eddies-wallet-design` on 2026-07-26. The source design system identifies Lucide icons and Baloo 2 / Fredoka / Nunito Sans as flagged substitutions; see `README.md` and `github.md` for the original attribution and caveats.
