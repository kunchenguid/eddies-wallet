# Eddie's Wallet privacy policy

Last reviewed against the code: 2026-08-11.

This policy is published at https://eddies-wallet.kunchenguid.com/. Future revisions will update the "Last reviewed against the code" date on this page.

## What this app is

Eddie's Wallet is an iOS app for families. A parent pays out virtual allowance and records deposits, withdrawals, loans, and repayments for one child, and the child sees a read-only wallet. The money in the app is pretend: it cannot be redeemed and never moves real money.

The child never signs in and never has an account. Only a parent signs in.

## What we do not do

- No advertising, ad networks, or ad identifiers.
- We do not sell, rent, or share your data with third parties.
- No behavioral analytics, tracking, or third-party analytics SDKs. The app bundles no third-party SDKs at all.
- No access to contacts, location, camera roll, microphone, or health data.
- No chat, public profiles, or sharing between families.

## What the app handles

### 1. Sign in with Apple

A parent signs in with Apple. Apple gives the app an opaque Apple user identifier for that parent, plus a short-lived identity token proving the sign-in.

- The opaque Apple user identifier is stored on the device in the iOS keychain. It contains no name, email address, or password. It exists so that "Forgot PIN?" recovery and any later session renewal can check that the same Apple account is signing in again. A different Apple account is refused.
- The identity token is short-lived proof. It is kept in memory only for the duration of that one sign-in and is never written to the device.
- Whenever a service session is needed, the app sends the short-lived identity token and sign-in nonce to the app's service at `eddieswallet.kunchenguid.com`. This happens during first-run existing-wallet discovery and any later Cloud sign-in or session renewal. If first-run discovery finds no wallet, fails, or the device is offline, the app continues with an ordinary on-device wallet.
- The sign-in request asks Apple for the email scope. The app's own code never reads, displays, or stores an email address. The token the app forwards is issued and signed by Apple and may carry the account's email address, which is a private relay address if the parent chose to hide their email.
- The service checks that token's signature with Apple and then keeps two things about the parent: the opaque Apple user identifier, and the email address when Apple includes one. Nothing else about the Apple account is kept - no name, no password, no Apple credential. The app itself never reads, displays, or stores that email address.
- When the service issues a session, it stores only a hashed form of the session token, never the token itself. Sessions expire on their own after a limited period. Signing out always removes the local token. A Cloud-wallet sign-out also asks the service to mark that session revoked; if that request fails or the device is offline, the service session may remain usable until it expires.

### 2. Parent identity and parent PIN

- A four-digit parent PIN gates the Parent area. It is stored in the iOS keychain on that device only, is never sent anywhere, and is never included in any request. It protects a shared family device from casual switching; it is not device-wide parental control.
- If the app has a service session, that session is an opaque token stored in the iOS keychain on that device only. Keychain items are marked accessible only after first unlock and only on that device.
- Parent identity is not shared with the child side of the app, and the Parent area is not reachable from the child's wallet without the PIN.

### 3. Child nickname

- The only information the app asks for about the child is a nickname. Optionally the underlying wallet record can carry an avatar image URL, but no screen in the app collects one.
- The app never asks for the child's real name, email address, phone number, birth date, photo, contacts, or location.
- The nickname is stored with the wallet on the device. It leaves the device only if the wallet itself does (see below).
- The parent can change the nickname in the Parent area. The child's screens never expose profile editing.

### 4. Wallet ledger

The wallet ledger is the balance, the list of recorded entries (deposits, withdrawals, allowance, loans, repayments) with their amounts and timestamps, the allowance rule, and each loan's status and optional payment plan, including its cadence, payment amount, due dates, and whether each scheduled payment was recorded. Each entry can carry a short free-text note that the parent types ("Reason" for money entries, "What is this for?" for loans), so it holds whatever the parent chooses to type there.

Where it lives depends on how the app is used:

- **Free, on-device wallet (the default).** The ledger is stored only on the device, in a Core Data database in the app's Application Support directory. The file is marked protected (readable only after first device unlock) and excluded from iCloud/iTunes backups. In this mode, reading and recording wallet actions does not contact any server, and works fully offline.
- **Optional Cloud wallet.** If a parent activates the optional paid Cloud subscription, the app uploads the household once - the child nickname, a family name derived from that nickname (for example "Robin's family"), and every ledger entry and loan, including optional loan payment plans and the parent's free-text notes - to the app's service, which then becomes the authority for that wallet. Afterwards, wallet changes are sent to the service and read back from it, and a protected copy stays on the device for offline reading.
- **Existing service wallets.** A device that was already set up against the service before the on-device mode existed continues to read and write its ledger through the service, and keeps a cached copy on the device for offline display.

Wallet data is never included in analytics, notifications, or crash reports, because the app sends none.

### 5. Connection details

When a service request fails, the app keeps a privacy-safe description of that attempt in memory so it can describe the connection honestly and help a parent report the problem.

- It keeps only the failure category and numeric code, whether the system attached an underlying error (yes or no, never the error itself), a fixed route template, the HTTP status if the service answered, how long the attempt took, and when it ended.
- It never keeps the full URL or query, request or response body, raw error details, account or session information, or child, family, or wallet data. Identifiers in request paths are replaced with `{id}`, and an unknown path is fully redacted.
- The child sees only a calm status message. The exact details are available only in the Parent area after a request has failed.
- The details are not persisted and the app never transmits them automatically. They leave the device only if a parent deliberately uses **Copy details** and shares the copied text.

### 6. Purchases (StoreKit)

The optional Cloud subscription is an Apple auto-renewable subscription. Apple, not this app, processes the payment.

- The app never sees or handles card numbers, billing addresses, or any payment credential.
- Prices and product names shown in the app come from Apple's App Store at runtime.
- When a purchase or restore produces a transaction, the app sends Apple's signed transaction to the app's service and acts on the subscription state the service reports back. The app itself never grants access, and never sends a transaction that Apple did not verify.
- The service independently checks that the transaction really is signed by Apple, and that it is for this app and one of its subscription products, before it grants anything. From that verified transaction it keeps subscription bookkeeping only: which product, the purchase and expiry dates, whether it was refunded or revoked, and the identifiers Apple issues for the transaction and the subscription. None of that is payment information, and none of it is wallet or child data.
- Each purchase is tagged with an opaque account token that the service supplies. It is not derived from the parent's name, email, or Apple identifier by anything in this app.
- The app collects local "Cloud recovery details" to help diagnose subscription problems in every build. These details contain only counts and outcome categories - never identifiers, signed transactions, account values, wallet data, or raw error text. They stay on the device, are not persisted, and are never transmitted. A readout of these details is available only in an internal Debug build launched with diagnostics enabled; it is not part of the shipped app.

## How long data is kept

- **On your device:** for as long as the wallet exists there. Account deletion first removes this device's wallet database and cached wallet state, then asks the service to remove the account. The session, Apple user identifier, and parent PIN are removed after a confirmed service result.
- **On the service:** a wallet that has been uploaded is kept until the parent deletes their account and wallet in the app. Letting the Cloud subscription lapse stops the paid features; it does not erase the wallet the service already holds.
- **Sessions:** these expire. A session stops working once it passes its expiry or is revoked by signing out. The revoked record itself is kept rather than removed.
- **Backups:** the service's host is backed up daily by its hosting provider. The service also keeps encrypted off-site database backups. A deleted account can remain in an encrypted off-site backup for up to 30 days; those backup copies are then deleted automatically.

## Deleting your data

- **In-app account deletion:** a parent can open **Parent area** > **Account** > **Delete account and wallet**. The action is behind the parent PIN and requires typing `DELETE`. An acknowledgement is also required when the Apple subscription is known to be or could still be auto-renewing.
- **What is deleted now:** the app first removes this device's wallet copy and cached wallet state, then the service removes the parent account and sign-in, household, child profile and nickname, wallet balance and ledger history, allowance rules, loans, repayments, Cloud entitlement and StoreKit subscription records. The session, Apple user identifier, and parent PIN are cleared on this device only after the service confirms the deletion. If the device database cannot be erased, no service deletion is sent and the intact wallet remains available. After a successful device erase, an unconfirmed service result or failed credential cleanup is shown as incomplete so the parent can retry or sign in later to finish.
- **Subscription-lineage record:** to safely reconnect an already-active Apple subscription if the same Apple ID returns, the service retains only the App Store environment and `original_transaction_id` for each deleted subscription lineage. It retains no name, child data, wallet data, token, hash, or other personal information. Those two lineage identifiers are kept indefinitely unless the same Apple ID returns; after that reconnect consumes the retained lineage, the service removes them.
- **Backup timeline:** the live account and wallet data are removed from the service right away. Encrypted off-site backup copies can remain for up to 30 days and are then deleted automatically.
- **Other devices:** if the wallet is on another family device, that device keeps its own saved copy. To remove it, delete the app from that device.
- **Cloud billing:** deleting an account does not cancel an Apple auto-renewable Cloud subscription. For a known or potentially auto-renewing subscription, the deletion screen warns that billing may continue through Apple, asks the parent to acknowledge that warning, and provides a link to Apple's subscription management settings. A known non-renewing subscription instead says access continues until expiry without renewal, and a confirmed no-subscription state makes no billing claim. Apple keeps the subscription, Apple ID, and Apple purchase history.
- **Returning after deletion:** a parent who signs in again starts with a fresh account. If the same Apple ID has an active Cloud subscription, the app restores the existing StoreKit entitlement instead of asking Apple to charge for a second subscription.
- **Wallet never uploaded to the service:** signing out from the Parent area erases that device's wallet database, the parent PIN, the stored Apple user identifier, and any cached wallet snapshot. This is permanent, and there is no other copy.
- **Cloud wallet sign-out:** signing out of Cloud asks the service to revoke that device's session, always removes the local session token, and hands the mirrored wallet back to that device as an ordinary on-device wallet. If the request fails or the device is offline, the server-side session may remain usable until it expires. The service-held wallet still exists, so later erasing the ordinary on-device wallet removes only the device copy.

## Children

The app is designed so that the child's side needs no account, no sign-in, and no personal details beyond a nickname the parent chooses. First-run setup is gated by the parent's Sign in with Apple; after setup, money actions, the Parent area, and settings sit behind the parent PIN.

## Contact

For privacy questions, email eddies-wallet@kunchenguid.com.
