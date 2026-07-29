# App Store Connect configuration for the optional Cloud subscription

This file records the App Store Connect state that exists today for `com.kunchenguid.eddieswallet`, so a future change does not re-request setup that is already done or drift the app's product identifiers away from the store.

It is a record of configuration, not a claim of product readiness. Nothing here asserts that a purchase, a Sandbox transaction, backend receipt verification, a TestFlight build, or App Review has succeeded. See "What is deliberately not done" below.

## Shared Apple account

Eddie's Wallet ships from a single Apple Developer team that also carries other apps. Two consequences matter for this repository:

- Account-level distribution prerequisites are **already satisfied** and must not be requested again. Another app on the same team sells an approved paid in-app purchase, which is only possible with an active Paid Applications agreement and completed tax and banking setup.
- Team-wide actions taken for another app can affect this one. See "Shared-team signing hazard".

The Apple team ID stays out of Git by repository convention; `release.yml` reads it from the non-secret `APPLE_TEAM_ID` repository variable. See `docs/release.md`.

## App-level state

| Item | Value |
| --- | --- |
| Bundle identifier | `com.kunchenguid.eddieswallet` |
| App Store Connect app Apple ID | `6795664301` |
| Bundle ID capabilities | `APPLE_ID_AUTH`, `IN_APP_PURCHASE` |
| App price schedule | Free, base territory `USA` |
| App Store Server Notifications V2 | Production and Sandbox both set to `https://eddieswallet.kunchenguid.com/v1/app-store/notifications`, version `V2` |
| Billing grace period | Opted in for production and Sandbox, `SIXTEEN_DAYS`, `ALL_RENEWALS` |

In-App Purchase needs no entitlement key. `EddysWallet/EddysWallet.entitlements` declares only Sign in with Apple, which is correct; the capability lives on the App ID, not in the entitlements file.

The notification URL points at the private backend route `POST /v1/app-store/notifications`. That route exists but stays dark until the backend's In-App Purchase configuration is installed, so Apple's notifications are addressed but not yet consumed.

## Cloud subscription group and products

One auto-renewable subscription group, reference name `Cloud`, `en-US` display name `Cloud`, group id `22273828`. The App Store Connect subscription-group localization contract has no description field, so the group description carried in the local StoreKit configuration has no store counterpart; only the display name is set.

| | Monthly | Annual |
| --- | --- | --- |
| Product ID | `com.kunchenguid.eddieswallet.cloud.monthly` | `com.kunchenguid.eddieswallet.cloud.annual` |
| Reference name | `Cloud monthly` | `Cloud annual` |
| Subscription period | `ONE_MONTH` | `ONE_YEAR` |
| US price | $2.99 | $24.99 |
| Plan type | `UPFRONT` | `UPFRONT` |
| Group level | 1 | 1 |
| `en-US` display name | `Cloud monthly` | `Cloud annual` |
| `en-US` description | `Cloud backup and sync for one parent household.` | same |
| Family Sharing | off | off |
| Introductory offer / free trial | none | none |
| Promotional offers, offer codes, win-back offers | none | none |
| Territories priced | 175 (US base price, equalized elsewhere) | 175 (US base price, equalized elsewhere) |
| Availability in new territories | yes | yes |
| App Store review screenshot | present, delivery state `COMPLETE` | present, delivery state `COMPLETE` |
| Product state | `READY_TO_SUBMIT` | `READY_TO_SUBMIT` |

Both products are at the same group level because they are the same service billed at two frequencies, not two service tiers.

`READY_TO_SUBMIT` is the furthest state a product reaches without being attached to a submission. It means the required metadata is complete; it does not mean the product is approved, live, or purchasable.

### Plan type is `UPFRONT` for both products, deliberately

App Store Connect models two subscription plan types. `UPFRONT` means the customer pays the full price for the subscription period at the start of that period. `MONTHLY` means an annual commitment billed in twelve monthly installments.

The accepted product is $2.99 charged each month on a monthly subscription and $24.99 charged once a year on an annual subscription. Both are `UPFRONT` for their own period. `MONTHLY` would convert the annual product into a twelve-month commitment billed monthly, which is not the accepted product, and Apple rejects `MONTHLY` outright for a one-month subscription.

### The local StoreKit configuration is the source of truth for identifiers

`EddysWallet/Configuration/EddysWallet.storekit` must keep matching the store: same product IDs, same periods, same prices, Family Sharing off, and no introductory offer. `EddysWalletTests/CloudStoreConfigurationTests.swift` enforces that, and `EddysWallet/Models/CloudModels.swift` holds the product IDs the client requests at runtime. Changing a price or adding a trial in one place only is a drift bug.

## What is deliberately not done

None of the following has happened, and this file must not be edited to imply otherwise without evidence:

- No purchase, renewal, grace, expiry, refund, or revocation has been exercised in Sandbox or production.
- No backend receipt or transaction verification has run. The backend still needs a distinct **In-App Purchase** key for the App Store Server API; the App Store Connect API key used for uploads is a different key class and the App Store Server API rejects it.
- No Sandbox Apple Account exists on the account, so Sandbox purchase testing cannot start yet. App Store Connect's API can list, modify, and clear purchase history for sandbox testers but cannot create one; that is console-only.
- No submission for App Review, and no request for Apple's test notification.
- The in-app Cloud surface still renders its guarded state, because the backend Cloud path is intentionally off.

## Reconfiguring

Everything in this file was applied through the App Store Connect API with the existing repository API key, not by hand in the console. The operations used, all documented endpoints:

- `PATCH /v1/apps/{id}` for the notification URLs and versions
- `POST /v1/appPriceSchedules` for the free app price
- `PATCH /v1/subscriptionGracePeriods/{id}` for the grace period
- `POST /v1/subscriptionGroups`, `POST /v1/subscriptionGroupLocalizations`
- `POST /v1/subscriptions`, `POST /v1/subscriptionLocalizations`
- `POST /v1/subscriptionPlanAvailabilities` before any price; Apple's pricing subsystem rejects a price with `409 ENTITY_ERROR.RELATIONSHIP.INVALID` until the plan type is available
- `POST /v1/subscriptionPrices` with a `planType` attribute, using a price point from `GET /v1/subscriptions/{id}/pricePoints?filter[territory]=USA&filter[planType]=UPFRONT`
- `GET /v1/subscriptionPricePoints/{id}/equalizations` then one `POST /v1/subscriptionPrices` per territory; there is no bulk endpoint. `adjustedEqualizations` is for converting between plan types and rejects `UPFRONT`.
- `POST /v1/subscriptionAppStoreReviewScreenshots`, upload the bytes to the returned operations, then `PATCH` with `uploaded` and `sourceFileChecksum`

Order matters: app price schedule and plan availability come before any product price.

## Shared-team signing hazard

Apple scopes signing certificates to the team, not to an app. This repository's own release workflow runs `.github/scripts/prune_asc_development_certs.js`, which keeps only the newest few `DEVELOPMENT` certificates and revokes the rest, and other apps on the same team run the same cleanup. Either direction can revoke a development certificate this Mac was using.

When that happens, `Apple Development` reports `CSSMERR_TP_CERT_REVOKED`, this app's development provisioning profile shows as `INVALID`, and running on a physical device fails.

That is not a distribution problem. TestFlight and App Store signing use the separate iOS distribution certificate and are unaffected. The safe recovery is to let Xcode automatic signing regenerate a development certificate; do not hand-edit signing settings and do not assume the release pipeline is broken. `docs/release.md` carries the same warning for release operators.
