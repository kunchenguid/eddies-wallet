# Native app

`EddysWallet.xcodeproj` is a SwiftUI iOS/iPadOS app targeting iOS 17 and device families 1 and 2. The built app bundle identifier is `com.kunchenguid.eddieswallet`, matching the registered Apple App ID and the production Apple audience. The UI uses adaptive `horizontalSizeClass` layouts and native sheets, forms, navigation, Dynamic Type-friendly system fonts, and accessibility labels.

## Production configuration

The app has one shipped API environment. `APIConfiguration.productionBaseURL` is the explicit production base URL:

```text
https://eddieswallet.kunchenguid.com
```

There is no staging or development API configuration in this client. Free mode does not call this API: `LocalWalletRepository` persists the one-child aggregate in protected, backup-excluded Core Data and is the accepted authority on that device. `APIWalletRepository` remains the compatibility implementation for legacy service wallets; `MockWalletRepository` remains available for previews and unit tests.

The optional Cloud path is wired but guarded. `EddysWalletApp` composes one `CloudAPIClient` over the keychain session and a `CloudCoordinator`, and `WalletStore` owns them:

- `CloudAPIClient` is the public `/v1` contract used by this slice: capabilities, context, transaction JWS delivery, bootstrap, changes, household import, legacy context, and session revoke. Field names, optionality, statuses, and the import hash order are pinned by `EddysWalletTests/Fixtures/cloud-api-contract/v1.json` and asserted in `CloudContractTests`.
- Purchase and restore controls appear only when the backend reports `cloudActivationAvailable` **and** StoreKit returns exactly the two Cloud products. Prices always come from StoreKit; the app contains no price string.
- The client never grants Cloud from StoreKit state. A backend-projected `active`/`billing_grace` entitlement permits first activation, while a verified Cloud household permits an existing household to be adopted on another device. A StoreKit transaction is finished only after the projected entitlement grants Cloud; 202, 4xx, and unreadable responses stay pending or rejected without finishing.
- Activation uploads the complete local household once through `CloudImportManifestBuilder` with a reserved operation id, stable idempotency key, and a canonical `aggregateSha256` that matches the service's accepted aggregate byte for byte. A second device for the same parent bootstraps instead of uploading.
- After activation, `CloudWalletRepository` keeps the service as the accepted authority and the protected local aggregate as an offline replica. Runtime money, allowance, and child-profile writes send the replica revision as `If-Match`, then reread `/v1/cloud/changes`; only a stable server entry id or accepted revision can prove observation. The repository persists at most one exact unresolved request before transport starts, including its body, revision, and idempotency key. Response loss, timeout, malformed success, relaunch, and reconnect therefore replay the same request instead of creating a second command. New controls and authority handoffs stay blocked until that request is observed or explicitly rejected.
- A persisted or known-offline Cloud replica stays readable but cannot start a mutation until a successful server read confirms its revision. If connectivity disappears during a request, the parent sees **Waiting to sync** without a balance change. A server-accepted write whose reread fails has distinct accepted-and-waiting copy and is never rendered as **Not recorded**. Explicit mutation rejections leave the accepted replica unchanged; a revision conflict asks the parent to refresh and review before retrying. Authentication failures during reconciliation stay unresolved because they cannot disprove an earlier commit.
- Signing out of a Cloud device or continuing locally after terminal entitlement first catches up with Cloud and refuses the handoff while any mutation is unresolved. The mirrored wallet becomes mutable local authority only after a current reread; the destructive erase warning stays only for local-only wallets.

The checked-in StoreKit configuration is a Debug/Test scheme input for Xcode launches only: it is selected by the shared scheme's Test and Launch actions and is deliberately **not** a member of the app target's Resources, so it never ships. Under `xcodebuild` (including CI), StoreKit ignores the scheme's `StoreKitConfigurationFileReference` and resolves the live App Store sandbox catalog over the network. `CloudDiagnosticsView` is a Debug-only surface that renders what StoreKit resolved (`storekit-product-*`, `storekit-price-*`); `testDebugStoreKitDiagnosticsProvesTheExactCloudProductsAndPrices` drives it in a real Debug app run to prove the live response, while `CloudStoreConfigurationTests` separately keeps the checked-in configuration aligned with the accepted product contract. The matching live StoreKit products are configured but have not been submitted, approved, or proven purchasable; Cloud activation remains under development, so no backup, sync, purchase, or TestFlight success is claimed. See [`docs/app-store-configuration.md`](../docs/app-store-configuration.md) for the exact store state and its unproven boundaries.

When a legacy or Cloud service wallet needs a session, its opaque token is stored with `KeychainSessionStore` using the `com.kunchenguid.eddieswallet.session` service and an after-first-unlock, this-device-only keychain item. Free mode creates no service session. The parent PIN uses `com.kunchenguid.eddieswallet.parent-pin`. The owning parent's opaque Apple user identifier is stored under `com.kunchenguid.eddieswallet.parent-apple-user`; it contains no name, email, or credential and exists only so forgotten-PIN recovery and service-session renewal can verify that a fresh Sign in with Apple presents the same parent account. A different Apple user identifier fails with `WalletAPIError.identityMismatch` before any optional service-session exchange. Identity tokens and Apple private keys are not stored. On upgrade, each keychain store attempts a narrowly scoped in-place service rename from its prior service before reading or writing; this uses `SecItemUpdate` and never logs or copies secret data. If the operating system does not permit access to the prior item after the App ID change, the user must sign in again or set a new PIN. For service-authoritative wallets, a cached accepted snapshot is used for offline display and is marked stale when it cannot be refreshed; an unresolved command is shown as **Waiting to sync** and does not change the accepted balance.

## Local development and tests

```sh
xcodebuild -project EddysWallet.xcodeproj -scheme EddysWallet \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.4' test
```

Unit and contract-style transport tests cover Apple session exchange, bearer sessions, revision and idempotency headers, successful Cloud writes, response loss after acceptance, timeout, malformed response, exact retry, concurrent identical actions, 409 conflicts, entry-id and accepted-revision observation, failed rereads, non-money writes, relaunch, offline replicas, and authority handoffs. Native UI tests use the Debug-only `EW_UITEST_SCENARIO` launch seam in `DebugScenarios.swift` to exercise synthetic signed-in states and capture Recorded, accepted-waiting, unresolved-waiting, Not recorded, and reconnect surfaces; that seam is excluded from Release builds. Normal tests inject fakes and in-memory stores and never call production. `CloudVerticalSliceTests.testSyntheticAppClientToBackendToPostgreSQLWrite` is an opt-in external-boundary test that runs only when its four `EW_CLOUD_E2E_*` loopback variables are supplied and a separately maintained synthetic service and disposable database are already running.

## Apple Sign In signing prerequisite

The source project declares the Sign in with Apple capability and `EddysWallet/EddysWallet.entitlements` contains `com.apple.developer.applesignin`. That source configuration does not guarantee that a locally built app is entitled: the captain must be signed into Xcode with the Apple Development team that owns the explicit App ID `com.kunchenguid.eddieswallet`, with Sign in with Apple enabled and a usable Apple Development certificate/account setup. This is an external prerequisite and cannot be supplied by this public repository. Do not commit a Team ID, provisioning profile, certificate, private key, or Apple account data.

After building, inspect the signed bundle rather than only the project settings:

```sh
rm -rf .derived
xcodebuild -project EddysWallet.xcodeproj -scheme EddysWallet \
  -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.4' \
  -derivedDataPath .derived build
codesign -d --entitlements :- \
  .derived/Build/Products/Debug-iphonesimulator/EddysWallet.app 2>&1
```

The output must contain `com.apple.developer.applesignin` with the `Default` value. If it is absent, the bundle is locally/ad hoc signed without the capability and the Apple Development signing setup must be fixed before testing native Apple authorization. A correctly entitled bundle is required but does not by itself prove that an Apple-side 401 or `AKAuthenticationError -7026` has been resolved.

## Manual simulator sequences

These sequences have **not** been run, so live end-to-end success must not be claimed.

### Free one-device wallet

1. Complete the Apple Development signing prerequisite above. In Apple Developer, confirm the explicit App ID `com.kunchenguid.eddieswallet` has Sign in with Apple enabled. Do not commit the Team ID.
2. Build and run the `EddysWallet` scheme from Xcode on an iOS 17+ simulator with the app's registered bundle identifier. The shared Debug scheme uses the checked-in StoreKit test configuration when Xcode launches the app. Sign in with Apple using the simulator's Apple ID/test account.
3. Confirm the app reaches the parent setup form. Enter a nickname and a four-digit parent PIN, create the free local wallet, and confirm setup completes without requiring the service. The PIN is stored only in the platform keychain and gates the Parent area locally. Setup completion must land in the Parent area with the first-actions handoff and a `Show <child>'s wallet` exit.
4. Confirm the Parent area shows the accepted virtual balance and the fixed notice: “Virtual practice only. These dollars are pretend, cannot be redeemed, and never move real money.”
5. Set the weekly allowance rule. Then record a deposit, an allowed withdrawal, a loan, a partial repayment, and a full repayment. For every action, verify the review screen, `Recorded` result, activity row, exact minor-unit balance, and the loan's remaining amount.
6. Inside the Parent area's Settings section, open `Edit child profile`, edit the child nickname, and confirm the child-named balance and kid home both show the locally saved name after exit. Leave the Parent area with `Done` and confirm the kid home is read-only, has no parent money actions or sign-out, and keeps activity and loan details readable. Relaunch and background or foreground the app and confirm it always returns to the kid home; confirm re-entering the Parent area requires the PIN at the Parent door.
7. Turn off network access and confirm the free wallet remains fully usable: reads and parent-recorded actions continue against protected local authority, actions appear as `Recorded`, and no `Waiting to sync` or service-session state is introduced.
8. Verify the forgotten-PIN path: `Forgot PIN?` on the gate requires the owning parent's Apple account and then allows setting a new PIN without touching wallet data.

### Legacy service-wallet compatibility

This separate operator sequence applies only to an upgrade that already has the legacy configured-wallet marker, cached child snapshot, and service session. It does not describe a newly created free wallet or prove optional Cloud activation.

1. The service operator configures the single production host and TLS for `https://eddieswallet.kunchenguid.com`, sets the backend Apple audience to `com.kunchenguid.eddieswallet`, and verifies `GET https://eddieswallet.kunchenguid.com/healthz` is healthy.
2. Install this build over the configured legacy app without clearing its app data. Confirm startup retains `APIWalletRepository` authority and the kid home refreshes through `/v1/child-view` rather than converting the cached snapshot into local authority.
3. Turn off network access, refresh, and confirm the kid home keeps the last accepted snapshot with kid-worded offline copy and a stale `Last updated` label. Inside the Parent area, submit a command and verify `Waiting to sync` without an accepted-balance change. Restore network, refresh, and verify the service accepts it once using its idempotency key or rejects it as `Not recorded` without changing accepted money.
4. Expire or revoke the service session, make a request, and confirm the app keeps only the cached read-only kid view with the note that a parent needs to sign in again, then requires the owning parent's fresh Sign in with Apple before any parent surface appears.
5. Record the result as an operator test report. Do not mark this repository or pull request as live end-to-end verified until the production endpoint and real-account simulator run are complete.

Remaining operator configuration is intentionally outside this repository: the Apple Development account/certificate and capability setup described above, DNS and TLS for `eddieswallet.kunchenguid.com`, backend `APPLE_AUDIENCES=com.kunchenguid.eddieswallet`, and the production service's backups, exports, and deployment health checks. No Team ID, token, credential, or private key belongs in Git.
