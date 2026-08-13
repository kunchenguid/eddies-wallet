# 0.1.17 App Store listing screenshots

Captain-approved submission set, 2026-08-13. These ten PNGs are the locked
listing screenshots for Eddie's Wallet 0.1.17: the same five screens on iPhone
6.9" (1320x2868) and iPad 13" (2064x2752). A later `0.1.17` App Review
manifest must bind these exact paths and bytes, and the attended App Store
Connect upload must use this same set.

| File | Device | Screen |
| --- | --- | --- |
| `iphone-6.9-kid-home.png` | iPhone 6.9" | Kid home |
| `iphone-6.9-parent-area.png` | iPhone 6.9" | Parent area |
| `iphone-6.9-parent-loan-payments.png` | iPhone 6.9" | Parent loan payments |
| `iphone-6.9-money-flow-review.png` | iPhone 6.9" | Money flow review |
| `iphone-6.9-cloud-plans.png` | iPhone 6.9" | Cloud plans |
| `ipad-13-kid-home.png` | iPad 13" | Kid home |
| `ipad-13-parent-area.png` | iPad 13" | Parent area |
| `ipad-13-parent-loan-payments.png` | iPad 13" | Parent loan payments |
| `ipad-13-money-flow-review.png` | iPad 13" | Money flow review |
| `ipad-13-cloud-plans.png` | iPad 13" | Cloud plans |

Do not replace a file in place. A later version gets its own directory.

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

Byte-for-byte these must match what is uploaded to App Store Connect. Do not
replace a file in place.
