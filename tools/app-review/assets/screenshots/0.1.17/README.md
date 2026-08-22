# 0.1.17 App Store listing screenshots

Live 0.1.17 en-US screenshot sets (GET, run 32555245100): only
`APP_IPHONE_67` and `APP_IPAD_PRO_3GEN_129` have screenshots. Those are the
display types this directory binds.

The captain-approved upload sets live under the display-type directories.
`tools/app-review/manifests/0.1.17.json` binds `fileName`, repo path, bytes,
and SHA-256 per slot. Do not assemble or submit 0.1.17 while it is HELD.

| Directory | Display type | Size | Format |
| --- | --- | --- | --- |
| `APP_IPHONE_67-asc-upload/` | `APP_IPHONE_67` | 1320x2868 | RGB8 PNG, no alpha |
| `APP_IPAD_PRO_3GEN_129-asc-upload/` | `APP_IPAD_PRO_3GEN_129` | 2064x2752 | RGB8 PNG, no alpha |

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

The PNGs at the listing-directory root are the previous locked 0.1.17 bytes
(including the byte-identical iPad parent pair that is still live on App Store
Connect). They are not the bound upload set. Do not replace a file in place.
A later version gets its own directory.

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
