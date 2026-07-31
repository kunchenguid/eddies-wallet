# App Store Connect configuration for the optional Cloud subscription

This file records the App Store Connect state that exists today for `com.kunchenguid.eddieswallet`, so a future change does not re-request setup that is already done or drift the app's product identifiers away from the store.

It is a record of configuration and the live evidence boundary, not a claim of product readiness. One Sandbox purchase through TestFlight reached Apple and the backend notification path, but complete client transaction delivery and Cloud activation remain unproven. See "Live Sandbox evidence and remaining boundaries" below.

## Shared Apple account

Eddie's Wallet ships from a single Apple Developer team that also carries other apps. Two consequences matter for this repository:

- Account-level distribution prerequisites are **already satisfied** and must not be requested again. Another app on the same team sells an approved paid in-app purchase, which is only possible with an active Paid Applications agreement and completed tax and banking setup.
- Team-wide certificate cleanup can affect this app's local development signing. The release guide owns that operational warning and recovery procedure.

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

### App Store version and build lineage

App Store Connect holds **one** iOS App Store version record, in `PREPARE_FOR_SUBMISSION`. It was created with the placeholder version string `1.0`, while every build this repository has ever uploaded carries a `0.1.x` marketing version derived from its release tag (`docs/release.md` owns that derivation). Apple will not bind a build to a version record whose version string differs from the build's marketing version, so **the version record must be aligned to the exact candidate's marketing version before that candidate can be attached**. Align App Store Connect to the repository's release lineage; do not invent a version the repository has never cut.

The uploaded builds are TestFlight artifacts, not App Store candidates: a build is only a candidate once it is attached to the version record. All uploaded builds declare `usesNonExemptEncryption = false`, so export compliance is already answered at the build level and App Review does not ask again.

### Review preparation blocked outside this repository

Three review-preparation items cannot be completed truthfully from this repository:

- **Privacy policy URL** is mandatory for an app and its auto-renewable subscription. This repository publishes no privacy policy today, so the field cannot be filled truthfully from anything committed here. Publishing one is a captain decision about real data-handling commitments, not a metadata edit.

- **App Privacy (data collection) answers** have no public API surface; they are entered in the App Store Connect console.
- **App Review contact details** (name, email, phone) are the captain's real contact information. They must never be invented, and no synthetic value belongs in that field.

Guideline 3.1.2 also requires the in-app purchase surface itself to show subscription title, length, and price alongside links to the privacy policy and the terms of use. `CloudStatusView` shows title, price, and period today; the two links remain blocked on the captain's decisions about those published destinations.

The notification URL points at the private backend route `POST /v1/app-store/notifications`. A live Sandbox notification has reached that route, passed the backend's App Store verification, and been persisted.

The backend also needs this app's non-secret identifiers as ordinary host configuration, not as secrets: the app Apple ID above and the Cloud subscription group id below, alongside the issuer and key identifiers of the In-App Purchase key.

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

The uploaded App Store review screenshot is an `EvidenceCaptureUITests` capture of the actual Cloud card. It truthfully shows the guarded, unavailable state because the app cannot render a purchase offer until product propagation and backend enablement are complete. Its successful upload proves only that the review asset is present, not that a purchase offer rendered or a transaction succeeded.

### Plan type is `UPFRONT` for both products, deliberately

App Store Connect models two subscription plan types. `UPFRONT` means the customer pays the full price for the subscription period at the start of that period. `MONTHLY` means an annual commitment billed in twelve monthly installments.

The accepted product is $2.99 charged each month on a monthly subscription and $24.99 charged once a year on an annual subscription. Both are `UPFRONT` for their own period. `MONTHLY` would convert the annual product into a twelve-month commitment billed monthly, which is not the accepted product, and Apple rejects `MONTHLY` outright for a one-month subscription.

### The local StoreKit configuration is the source of truth for identifiers

`EddysWallet/Configuration/EddysWallet.storekit` must keep matching the store: same product IDs, same periods, same prices, Family Sharing off, and no introductory offer. `EddysWalletTests/CloudStoreConfigurationTests.swift` enforces that, and `EddysWallet/Models/CloudModels.swift` holds the product IDs the client requests at runtime. Changing a price or adding a trial in one place only is a drift bug.

## Live Sandbox evidence and remaining boundaries

A captain-supplied live report proves one narrow Sandbox/TestFlight path: Apple completed the purchase, Apple's server notification passed the live backend verifier and persisted, and the app made no transaction-delivery request. This does not prove client delivery, backend-projected entitlement recovery, Cloud activation, backup, sync, renewal, or production purchase behavior.

The client recovery and error-attribution contract is owned by [`EddysWallet/README.md`](../EddysWallet/README.md).

The following remain deliberately unproven or undone:

- No successful client transaction-delivery request or Cloud activation has been exercised live.
- No renewal, grace, expiry, refund, or revocation has been exercised in Sandbox or production.
- The backend's In-App Purchase credential is installed and has verified the observed Sandbox notification. It remains distinct from the App Store Connect API key used for uploads; no new key is needed and none should be requested.
- This App Store Connect configuration work did not cut a TestFlight build or merge release pull request 26. That pull request remains open and captain-owned; this task-scoped boundary does not negate the TestFlight uploads App Store Connect has already accepted for this app.
- No submission for App Review, and no request for Apple's test notification.
- No build is attached to the App Store version record, no App Store listing screenshots exist, and no App Review submission object has been created.

### The guarded state is not a product-discovery failure

The in-app note "Cloud plans are unavailable right now" is selected by the **backend** capability branch, not by StoreKit. `CloudSubscriptionStore.loadProducts()` reads `/v1/capabilities` first and returns before asking StoreKit for anything when activation is unavailable. A screenshot of that note therefore says nothing about whether Apple's catalog resolves the two products.

Product discovery is proven separately, and independently of the backend: `testDebugStoreKitDiagnosticsProvesTheExactCloudProductsAndPrices` drives the Debug-only diagnostics surface, which talks only to StoreKit. Under `xcodebuild` that resolves the **live App Store catalog** rather than the checked-in configuration file, and `ci.yml` runs it on every release tag, so each candidate tag carries its own live proof of both product identifiers, both localized prices, both periods, and Family Sharing being off.

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

See `docs/release.md` for the team-scoped development-certificate cleanup hazard, including this repository's own cleanup script, its symptoms, and the safe recovery procedure.
