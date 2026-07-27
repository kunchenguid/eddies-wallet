# App Icon — Eddie's Wallet

Piggy-bank mark, white on brand green (`--brand-primary`), flat/solid per brand rules (no gradient, no inner shadow — iOS applies its own corner mask and gloss).

## Files (`assets/app-icon/`)
- `icon-1024.png` — App Store listing
- `icon-180.png` — iPhone @3x (60pt)
- `icon-167.png` — iPad Pro @2x (83.5pt)
- `icon-152.png` — iPad @2x (76pt)
- `icon-120.png` — iPhone @2x (60pt) / Spotlight @3x
- `icon-87.png` — Settings @3x
- `icon-80.png` — Spotlight @2x
- `icon-60.png` — Spotlight @1x (iPad)
- `icon-58.png` — Settings @2x
- `icon-40.png` — Spotlight @1x / Notification @2x
- `icon-29.png` — Settings @1x
- `icon-20.png` — Notification @1x

Drop these directly into your app's `Assets.xcassets/AppIcon.appiconset` (match filenames to the corresponding slots, or let Xcode's "single size" 1024 App Store slot use `icon-1024.png` and fill the rest from your asset catalog generator).
