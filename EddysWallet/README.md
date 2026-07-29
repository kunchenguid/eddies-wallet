# Native app

`EddysWallet.xcodeproj` is a SwiftUI iOS/iPadOS app targeting iOS 17 and device families 1 and 2. The built app bundle identifier is `com.kunchenguid.eddieswallet`, matching the registered Apple App ID and the production Apple audience. The UI uses adaptive `horizontalSizeClass` layouts and native sheets, forms, navigation, Dynamic Type-friendly system fonts, and accessibility labels.

## Production configuration

The app has one shipped API environment. `APIConfiguration.productionBaseURL` is the explicit production base URL:

```text
https://eddieswallet.kunchenguid.com
```

There is no staging or development API configuration in this client. Free mode does not call this API: `LocalWalletRepository` persists the one-child aggregate in protected, backup-excluded Core Data and is the accepted authority on that device. `CloudAPIClient` contains the guarded public `/v1` contract for capabilities, context, transaction JWS delivery, bootstrap, changes, import, legacy transition, session revoke, and revision conflicts. `APIWalletRepository` remains the compatibility implementation for legacy service wallets; `MockWalletRepository` remains available for previews and unit tests. StoreKit configuration is checked in for deterministic local development and tests. The matching live StoreKit products are configured but have not been submitted, approved, or proven purchasable; Cloud activation remains under development, so no backup, sync, purchase, or TestFlight success is claimed. See [`docs/app-store-configuration.md`](../docs/app-store-configuration.md) for the exact store state and its unproven boundaries.

When a legacy or Cloud service wallet needs a session, its opaque token is stored with `KeychainSessionStore` using the `com.kunchenguid.eddieswallet.session` service and an after-first-unlock, this-device-only keychain item. Free mode creates no service session. The parent PIN uses `com.kunchenguid.eddieswallet.parent-pin`. The owning parent's opaque Apple user identifier is stored under `com.kunchenguid.eddieswallet.parent-apple-user`; it contains no name, email, or credential and exists only so forgotten-PIN recovery and service-session renewal can verify that a fresh Sign in with Apple presents the same parent account. A different Apple user identifier fails with `WalletAPIError.identityMismatch` before any optional service-session exchange. Identity tokens and Apple private keys are not stored. On upgrade, each keychain store attempts a narrowly scoped in-place service rename from its prior service before reading or writing; this uses `SecItemUpdate` and never logs or copies secret data. If the operating system does not permit access to the prior item after the App ID change, the user must sign in again or set a new PIN. For service-authoritative wallets, a cached accepted snapshot is used for offline display and is marked stale when it cannot be refreshed; an unaccepted command is shown as **Waiting to sync** and does not change the accepted balance.

## Local development and tests

```sh
xcodebuild -project EddysWallet.xcodeproj -scheme EddysWallet \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.4' test
```

Unit and contract-style transport tests cover Apple session exchange, bearer sessions, idempotency headers, authoritative virtual-money responses, pending network commands, expired sessions, and invalid responses. Native UI tests use the Debug-only `EW_UITEST_SCENARIO` launch seam in `DebugScenarios.swift` to exercise synthetic signed-in states; that seam is excluded from Release builds. Tests inject fakes and in-memory stores and do not call the production service.

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
2. Build and run the `EddysWallet` scheme on an iOS 17+ simulator with the app's registered bundle identifier. The shared Debug scheme uses the checked-in StoreKit test configuration. Sign in with Apple using the simulator's Apple ID/test account.
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
