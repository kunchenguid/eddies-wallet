# Eddie's Wallet privacy policy

**Status: DRAFT for captain review. Not published, not linked from the app, and not submitted to App Review.**
It describes what the app and its service actually do today, checked against the code of both. The remaining open questions at the end are decisions rather than facts, and must be resolved before publication.

Last reviewed against the code: 2026-08-02.

## What this app is

Eddie's Wallet is an iOS app for families. A parent records virtual allowance, deposits, withdrawals, loans, and repayments for one child, and the child sees a read-only wallet. The money in the app is pretend: it cannot be redeemed and never moves real money.

The child never signs in and never has an account. Only a parent signs in.

## What we do not do

- No advertising, ad networks, or ad identifiers.
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
- The service checks that token's signature with Apple and then keeps two things about the parent: the opaque Apple user identifier, and the email address when Apple includes one. Nothing else about the Apple account is kept - no name, no password, no Apple credential. The app itself never receives or displays that email address.
- When the service issues a session, it stores only a hashed form of the session token, never the token itself. Sessions expire on their own after a limited period, and signing out marks the session revoked so it stops working.

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

The wallet ledger is the balance, the list of recorded entries (deposits, withdrawals, allowance, loans, repayments) with their amounts and timestamps, the allowance rule, and loan status. Each entry can carry a short free-text note that the parent types ("Reason" for money entries, "What is this for?" for loans), so it holds whatever the parent chooses to type there.

Where it lives depends on how the app is used:

- **Free, on-device wallet (the default).** The ledger is stored only on the device, in a Core Data database in the app's Application Support directory. The file is marked protected (readable only after first device unlock) and excluded from iCloud/iTunes backups. In this mode, reading and recording wallet actions does not contact any server, and works fully offline.
- **Optional Cloud wallet.** If a parent activates the optional paid Cloud subscription, the app uploads the household once - the child nickname, a family name derived from that nickname (for example "Robin's family"), and every ledger entry and loan including the parent's free-text notes - to the app's service, which then becomes the authority for that wallet. Afterwards, wallet changes are sent to the service and read back from it, and a protected copy stays on the device for offline reading.
- **Existing service wallets.** A device that was already set up against the service before the on-device mode existed continues to read and write its ledger through the service, and keeps a cached copy on the device for offline display.

Wallet data is never included in analytics, notifications, or crash reports, because the app sends none.

### 5. Purchases (StoreKit)

The optional Cloud subscription is an Apple auto-renewable subscription. Apple, not this app, processes the payment.

- The app never sees or handles card numbers, billing addresses, or any payment credential.
- Prices and product names shown in the app come from Apple's App Store at runtime.
- When a purchase or restore produces a transaction, the app sends Apple's signed transaction to the app's service and acts on the subscription state the service reports back. The app itself never grants access, and never sends a transaction that Apple did not verify.
- The service independently checks that the transaction really is signed by Apple, and that it is for this app and one of its subscription products, before it grants anything. From that verified transaction it keeps subscription bookkeeping only: which product, the purchase and expiry dates, whether it was refunded or revoked, and the identifiers Apple issues for the transaction and the subscription. None of that is payment information, and none of it is wallet or child data.
- Each purchase is tagged with an opaque account token that the service supplies. It is not derived from the parent's name, email, or Apple identifier by anything in this app.
- The Parent area has a "Cloud recovery details" readout that helps diagnose subscription problems. It shows only counts and outcome categories - never identifiers, signed transactions, account values, wallet data, or raw error text. It stays on the device, is not persisted, and is never transmitted.

## How long data is kept

- **On your device:** for as long as the wallet exists there. Erasing it from the Parent area removes it immediately.
- **On the service:** a wallet that has been uploaded is kept indefinitely. Nothing on the service deletes households, ledger entries, or parent identities automatically - there is no expiry job and no scheduled clean-up. Letting the Cloud subscription lapse stops the paid features; it does not erase the wallet the service already holds.
- **Sessions:** these do expire. A session stops working once it passes its expiry or is revoked by signing out. The revoked record itself is kept rather than removed.
- **Backups:** the service's host is backed up daily by its hosting provider, so a recent copy of the service's data exists in those backups. An additional encrypted off-site backup is being set up and is not yet in operation.

## Deleting your data

- **Wallet never uploaded to the service:** signing out from the Parent area erases that device's wallet database, the parent PIN, the stored Apple user identifier, and any cached wallet snapshot. This is permanent, and there is no other copy.
- **Cloud wallet:** signing out of Cloud asks the service to revoke that device's session, always removes the local session token, and hands the mirrored wallet back to that device as an ordinary on-device wallet. If the request fails or the device is offline, the server-side session may remain usable until it expires. The service-held wallet still exists, so later erasing the ordinary on-device wallet removes only the device copy.
- **There is no self-service deletion of a service-held wallet today.** The service offers no delete-my-data request of any kind: the only thing the app can ask it to remove is the current session. Deleting an uploaded wallet requires a manual request to the people who run the service, and the route for making that request has not been established yet (see open questions).

## Children

The app is designed so that the child's side needs no account, no sign-in, and no personal details beyond a nickname the parent chooses. First-run setup is gated by the parent's Sign in with Apple; after setup, money actions, the Parent area, and settings sit behind the parent PIN.

## Contact

_To be filled in by the captain before publication (see open questions)._

---

## Open questions for the captain (remove before publication)

Everything the code determines has been written into the policy above. What remains here are decisions, not facts - each one needs a choice from the captain, and none may be answered with plausible-sounding text instead:

1. **Selling, renting, or sharing data with third parties.** The policy above makes no such commitment, because this is a promise about how the product is run rather than something code can establish. Decide what the published policy should commit to.
2. **Contact address** for privacy questions and deletion requests.
3. **Deletion route for a service-held wallet.** The policy now states the current reality truthfully: no self-service deletion exists, and no request channel has been established. Apple requires an account-deletion path for apps that create accounts, so decide whether to build one in the app or to name a request channel here - and then this text must be updated to match.
4. **Legal footing statements** (controller identity, jurisdiction, COPPA/GDPR-K posture, lawful basis). This draft deliberately makes none; a legal review should decide whether any are required for the App Store listing and the markets targeted.
5. **Email scope - a small product choice.** The behavior is now described accurately above: the app asks Apple for the email scope, never uses the address itself, and the service keeps it when Apple provides one. Decide whether to keep that or drop the scope request, which would let the policy say the email address is never collected at all.
6. **Publication address and revision practice.** No address is published and no update process exists yet. Confirm where the policy will live and how future revisions will be dated and announced, so the published version can describe it truthfully.

This list is not a fixed set. Every genuine decision or unverifiable claim belongs here as an open question; none of these entries may be deleted to reach a particular count, and none may be answered with invented text instead of a captain decision. Equally, nothing that the app or service code actually determines belongs here - that gets investigated and written as plain policy text.

Once the encrypted off-site backup described above is actually in operation, the backup wording needs a factual update.
