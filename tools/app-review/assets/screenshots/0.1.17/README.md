# 0.1.17 App Store listing screenshots

Live 0.1.17 en-US screenshot sets (GET, run 32555245100): only
`APP_IPHONE_67` and `APP_IPAD_PRO_3GEN_129` have screenshots. Those are the
display types this directory binds.

Engine asset path is `{sourceRoot}/{listing.screenshotDirectory joined}/{fileName}`.
This directory is `listing.screenshotDirectory`. The captain-approved manifest
binds `{displayType,width,height,files[{fileName,fileSize,sha256}]}`. The engine
computes MD5 of those bytes as Apple's `sourceFileChecksum`. Do not assemble,
upload, or submit 0.1.17 while it is HELD.

| File prefix | Display type | Size | Format |
| --- | --- | --- | --- |
| `iphone-6.9-*.png` | `APP_IPHONE_67` | 1320x2868 | RGB8 PNG, no alpha |
| `ipad-13-*.png` | `APP_IPAD_PRO_3GEN_129` | 2064x2752 | RGB8 PNG, no alpha |

`python3 tools/app-review/screenshot_preflight.py` proves every required slot
is present, the PNG is the approved size and format, no two files in a size
are byte-identical, and checksums match the manifest.

These listing files are produced by `EvidenceCaptureUITests.testAppStoreListingScreenshots`
on the matching simulator (iPhone 6.9" / iPhone 17 Pro Max, and iPad 13"),
then copied here as RGB8 PNG.

| Slot | Scenario | Evidence name |
| --- | --- | --- |
| kid-home | `configured` kid home | `listing-kid-home` |
| parent-area | `configured` parent area | `listing-parent-area` |
| parent-loan-payments | `loan-installments-missed` parent area | `listing-parent-loan-payments` |
| money-flow-review | `configured` deposit review | `listing-money-flow-review` |
| cloud-plans | `cloud-plans-no-price` | `listing-cloud-plans` |

Parent-area and parent-loan-payments must never be byte-identical. On iPad 13"
the missed-loan card is already fully on screen, so two captures of that same
viewport collapse and the assemble engine refuses them.

## Cloud subscription review screenshots

These two `iap-review-cloud-plans-priced-*` files are the Cloud subscription
REVIEW screenshots (priced offer with real prices $2.99/mo and $24.99/yr, and
Guideline 3.1.2 Terms of Use + Privacy Policy links visible). They are distinct
from the marketing `*-cloud-plans.png` listing shots above, which show no
prices.

| File | Device | Role |
| --- | --- | --- |
| `iap-review-cloud-plans-priced-iphone-6.9.png` | iPhone 6.9" (1320x2868) | Uploaded to App Store Connect on both Cloud monthly and Cloud annual. The 0.1.17 App Review manifest binds this file as `inAppPurchases[].reviewScreenshot` for both products. |
| `iap-review-cloud-plans-priced-ipad-13.png` | iPad 13" (2064x2752) | Alternate capture. Committed for completeness; not currently uploaded to App Store Connect and not the file the manifest binds. |
