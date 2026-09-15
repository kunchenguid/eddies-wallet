# 0.1.19 App Store listing screenshots

0.1.19 reuses the approved 0.1.17 listing and Cloud review screenshot
bytes. The reviewed screens are unchanged: #133 keeps amount fields
visible above the keyboard and dismisses a finished allowance sheet, but
the bound slots are kid home, parent area, missed-loan parent area,
deposit review (not the focused amount field), and Cloud plans.

Engine asset path is `{sourceRoot}/{listing.screenshotDirectory joined}/{fileName}`.
This directory is `listing.screenshotDirectory`. The captain-approved manifest
binds `{displayType,width,height,files[{fileName,fileSize,sha256}]}`. The engine
computes MD5 of those bytes as Apple's `sourceFileChecksum`.

| File prefix | Display type | Size | Format |
| --- | --- | --- | --- |
| `iphone-6.9-*.png` | `APP_IPHONE_67` | 1320x2868 | RGB8 PNG, no alpha |
| `ipad-13-*.png` | `APP_IPAD_PRO_3GEN_129` | 2064x2752 | RGB8 PNG, no alpha |

`python3 tools/app-review/screenshot_preflight.py --version 0.1.19` proves every
required slot is present, the PNG is the approved size and format, no two files
in a size are byte-identical, and checksums match the manifest.

| Slot | Scenario | Evidence name |
| --- | --- | --- |
| kid-home | `configured` kid home | `listing-kid-home` |
| parent-area | `configured` parent area | `listing-parent-area` |
| parent-loan-payments | `loan-installments-missed` parent area | `listing-parent-loan-payments` |
| money-flow-review | `configured` deposit review | `listing-money-flow-review` |
| cloud-plans | `cloud-plans-no-price` | `listing-cloud-plans` |

## Cloud subscription review screenshots

| File | Device | Role |
| --- | --- | --- |
| `iap-review-cloud-plans-priced-iphone-6.9.png` | iPhone 6.9" (1320x2868) | Bound as `inAppPurchases[].reviewScreenshot` for both Cloud products. |
| `iap-review-cloud-plans-priced-ipad-13.png` | iPad 13" (2064x2752) | Alternate capture. Committed for completeness; not the file the manifest binds. |
