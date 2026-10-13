# Parent-redesign App Store listing screenshots

The 0.1.20 Parent area redesign put the four money actions (Add deposit,
Record withdrawal, Create loan or Pay toward loan, Allowance) right under the
balance, moved Cloud, the child profile, and the parent PIN onto a Settings
screen behind the gear, and turned each money flow into one sheet. The
`0.1.17` set, which 0.1.19 and 0.1.21 reused, still shows the old Parent area.
This directory is the listing set for the next App Store version after 0.1.21,
and `app-review.config.json` `listing.screenshotDirectory` names it.

The files are produced by `EvidenceCaptureUITests.testAppStoreListingScreenshots`
through `test/sim.sh` on iPhone 17 Pro Max (6.9") and iPad Pro 13-inch (M5).
The captures are already RGB8 PNG without alpha and are copied unchanged. Slot
names, order, and scenarios are unchanged from `0.1.17`; the deposit slot now
shows the one-step sheet instead of the retired review step.

Engine asset path is `{sourceRoot}/{listing.screenshotDirectory joined}/{fileName}`.
The captain-approved manifest binds `{displayType,width,height,files[{fileName,fileSize,sha256}]}`,
and the engine computes MD5 of those bytes as Apple's `sourceFileChecksum`.

| File prefix | Display type | Size | Format |
| --- | --- | --- | --- |
| `iphone-6.9-*.png` | `APP_IPHONE_67` | 1320x2868 | RGB8 PNG, no alpha |
| `ipad-13-*.png` | `APP_IPAD_PRO_3GEN_129` | 2064x2752 | RGB8 PNG, no alpha |

| Slot | Scenario | Evidence name | Shows |
| --- | --- | --- | --- |
| kid-home | `configured` kid home | `listing-kid-home` | The child's read-only wallet and the Parent door. |
| parent-area | `configured` parent area | `listing-parent-area` | The gear, the balance, the four action tiles, and sync status. |
| parent-loan-payments | `loan-installments-missed` parent area | `listing-parent-loan-payments` | The four action tiles above the loan payments card with three missed payments. |
| money-flow-review | `configured` deposit sheet | `listing-money-flow-review` | Add deposit with US$5.25 entered, Balance after US$29.25, and the Add US$5.25 button, without the keyboard. |
| cloud-plans | `cloud-plans-no-price` | `listing-cloud-plans` | Cloud backup & sync at the top of the Settings screen behind the gear, with both plans and no prices. |

Parent-area and parent-loan-payments must never be byte-identical; the
capture test asserts it, and `screenshot_preflight.py` refuses two identical
files in one size.

Cloud subscription review screenshots are not part of this set. The approved,
live Cloud subscriptions keep the review screenshot under `0.1.19/`.
