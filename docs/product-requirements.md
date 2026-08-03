# Eddie's Wallet

## Product requirements document

**Status:** Accepted freemium Cloud MVP direction
**Product:** iPad/iOS virtual allowance app for a configurable child profile
**Audience:** Product, design, engineering, and review collaborators

> This document is the preserved product requirements record. A native SwiftUI implementation of this MVP now exists in this repository; for current status, setup instructions, and known limitations, see the [root README](../README.md).

Eddie's Wallet is the product brand: a calm, parent-managed family ledger that helps a child practice everyday money concepts. Parents record changes. The configured child profile can understand and review them. The balance uses familiar local currency vocabulary, initially US dollars, but it is always **virtual, pretend, and nonredeemable**. No real money moves through the product.

**Brand identity vs everyday chrome:** **Eddie's Wallet** is the external app/store/marketing name (install display name, public docs, legal/support copy, and at most one intentional welcome/onboarding wordmark). It is **not** the recurring identity of the kid home or Parent area. Daily kid and parent main screens must never lead with a static brand possessive, because a child not named Eddie may think the wallet belongs to somebody else.

- **Kid surfaces:** child-personal when the configured nickname is known (`Maya's Wallet`, `Hi, Maya`); neutral otherwise (`Your wallet`, `Your allowance balance`). Own reusable profile-derived strings in `ChildProfileCopy`.
- **Parent surfaces:** family/child-centric (`Parent area`, child nickname, `Maya's virtual balance`, handoff back to the child's wallet) - not recurring `Eddie's ...` chrome.
- **Configured nickname Eddie:** still valid personal data. Personal copy such as `Eddie's Wallet` for a child actually named Eddie is correct and must not be stripped as a false brand leak. Synthetic fixture nickname `Eddie` is test data, not a brand requirement.
- **External keep list:** App Store/install display name, package/repository/bundle identifiers, support URLs, legal/About/copyright, and the welcome wordmark (`ProductBrand.displayName`).

This document is the product starting point for the first MVP. The public repository is frontend-only; the service implementation and operations are maintained separately. This document defines client-facing behavior and does not include service or deployment implementation.

## 1. Settled decisions

These decisions are the current product direction and should not be reopened during MVP implementation without an explicit product decision:

- Use familiar local currency vocabulary, initially **US dollars**. Parent-facing setup, controls, review, balance cards, and safety notices must keep firm virtual, pretend, and nonredeemable labeling. Kid everyday surfaces use plain allowance language instead of stacking those disclaimers.
- Do not connect to banks, cards, payment processors, cash, or any other real-money rail.
- The Parent area on a shared iPad is protected by a **parent-set PIN** behind a visually secondary Parent door on the kid home. The PIN is a local gate against casual access; it does not replace service authorization when the wallet is service-authoritative.
- The first child experience is a **parent-managed child profile**, not an independent child login or Apple identity.
- **Apple Sign In is required** for the parent MVP. Google Sign In is future scope only.
- Do not include child-initiated money requests in the smallest MVP.
- Show loans as a secondary card on the wallet with a detail flow. Do not make Loans a prominent top-level navigation area.
- Show Recent Activity directly on the wallet. Do not add a duplicate Recent Activity entry point when the activity list is already visible there.
- The external service must remain vendor-neutral from the app's perspective. Its implementation and hosting are outside this public frontend repository.
- The initial recovery expectation for the external service is daily backups plus a nightly encrypted export. This is intentionally a minimal recovery plan, not an enterprise audit specification.

Research reports are context, not hidden requirements. In particular, a research recommendation for a hosted service, extra authentication mode, interest-bearing loans, or a larger education system is not adopted unless this PRD says so.

## 2. Problem and opportunity

Parents want a simple way to give children practice with allowance, spending, borrowing, and repayment without opening a bank account, handing over a payment card, or moving real money. Existing allowance products tend to provide only a ledger, permit child money changes, use real-money rails, or omit loans and structured learning.

Eddie's Wallet addresses the gap with a small, closed virtual economy:

1. A parent creates and controls the configured child profile.
2. The parent records allowance, deposits, withdrawals, loans, and repayments.
3. The child sees an understandable, read-only wallet and activity history.
4. The app stays honest about sync state. Parents repeatedly see that the balance cannot be spent or redeemed; kids see a plain allowance relationship without that legal framing on every glance.

## 3. Target user and roles

### Primary user: parent

A parent or guardian uses a shared iPad or iOS device to set up the family, manage the child profile, and record virtual money events. The parent needs confidence that the ledger is understandable, recoverable, and protected from accidental child changes.

### Child profile

The configured child profile uses a simple child view to check an allowance balance, understand activity, and inspect an open loan. The child does not need an email address, Apple identity, password, or independent account in the MVP.

### MVP authority model

- The MVP has one signed-in parent owner and one parent-managed child profile.
- The parent is the only role that can create or change wallet data, the allowance rule, the child profile, or the parent PIN.
- The kid home is a view of the configured child profile, not a second account with independent authority.
- Future co-parent members and independent child-device identities must not be implied by MVP UI.

## 4. Product boundary

### In scope

- One family, one parent owner, and one child profile for the smallest launch slice.
- Parent authentication with Apple Sign In.
- Parent-set local PIN for entering the temporary Parent area on a shared iPad.
- A single virtual wallet for the child profile.
- A familiar US-dollar display vocabulary with persistent virtual/nonredeemable labeling on parent and safety surfaces, and plain allowance language on kid everyday surfaces.
- Parent-created allowance, deposits, withdrawals, loans, and repayments.
- A visible wallet activity list and activity details.
- A secondary open-loan card and loan detail flow.
- Honest offline, pending, rejected, and stale-data states.
- Minimal privacy, backup, export, and recovery safeguards.

### Explicitly outside the boundary

- Real money, cash-out, bank accounts, debit or credit cards, payment processing, cryptocurrency, or investment products.
- Child purchases or merchant spending.
- Independent child login or child-owned Apple identity.
- Child-initiated money requests.
- Chores, rewards, goals, jars, multiple wallets, multiple currencies, or social features.
- Interest-bearing loans, late fees, credit scoring, or implicit overdrafts.
- Ads, behavioral tracking, public profiles, chat, contacts access, or location collection.
- Enterprise audit, complex compliance dashboards, or a multi-region operations platform.

## 5. MVP goals and non-goals

### Goals

1. Make virtual money practice feel safe and unambiguous rather than like a bank account.
2. Give the parent a small set of reliable, understandable money controls.
3. Give the child a genuinely read-only view of accepted wallet activity.
4. Make borrowing and repayment understandable without making debt prominent or punitive.
5. Preserve trust when a device is offline or a command is rejected.
6. Minimize child data and keep the initial operational model simple.

### Non-goals

- Replacing a bank, allowance card, financial account, or payment app.
- Teaching every financial topic in the first release.
- Automating a full household allowance and chore system.
- Supporting arbitrary family roles, permissions, or account recovery policies.
- Optimizing for engagement through streaks, competition, rewards, or notifications.
- Choosing a particular service implementation or hosting vendor before cost, backup, monitoring, and on-call responsibilities are confirmed.

## 6. Money model and vocabulary

### Virtual balance and split-audience copy

The amount is a simulated accounting value only. It is not a dollar claim, stored cash, credit, or promise from the parent or Eddie's Wallet. The allowance relationship is real in the family; the app currency is practice accounting.

**Parent and safety surfaces** (setup, welcome, Parent area balance cards, parent activity/loan details, review flows, validation, public product claims, and legal-ish notices) keep firm virtual, nonredeemable, and no-real-money-moves clarity. The following copy must be persistent and easy to find on those surfaces, not hidden only in onboarding:

> Virtual practice only. These dollars are pretend, cannot be redeemed, and never move real money.

Parent balance framing uses the configured nickname, such as **Maya's virtual balance**, or **Your child's virtual balance** when no nickname is set.

**Kid everyday surfaces** (kid home hero, empty-wallet ready state, kid activity list/detail, kid loan card/detail, and kid status/accessibility text) stay plain and relational. The primary kid balance label is exactly **Your allowance balance**. Do not stack `pretend`, `virtual practice`, `not real money`, `nonredeemable`, or similar complexity on the kid home or routine kid detail glances. Kid activity lines stay human (“Your parent added…”) without a heavy disclaimer on every row.

Do not use a bank-card design or wording that implies spendable funds, banks, cards, cash-out, or payments on any surface.

### Ledger rules

- Each child has one wallet in the MVP.
- Store and calculate amounts as exact minor units suitable for two-decimal dollar display; do not use floating-point money arithmetic.
- An accepted positive event increases the wallet. An accepted withdrawal or repayment decreases it.
- The wallet cannot go below zero. A loan is the explicit way to give the child additional virtual dollars that must be repaid; it is not an accidental overdraft.
- A balance is the result of accepted events. Pending events are not accepted money.
- Accepted events are not edited or deleted. A parent correction, if needed, is a new clearly labeled compensating event.
- Every accepted event has a type, amount, date, reason where applicable, and the fact that it was recorded by the parent.

### Vocabulary

| Parent-facing term | Child-facing explanation |
| --- | --- |
| Allowance | A plan for when dollars are added. |
| Deposit | Your parent added dollars to your wallet. |
| Withdrawal | Your parent recorded that dollars were used. |
| Loan | Dollars your parent gave you to use now and give back later. |
| Repayment | Dollars returned toward the loan. |
| Virtual balance (parent) | Practice ledger value that cannot be redeemed or spent as real money. |
| Allowance balance (kid) | Your allowance balance - plain relational framing without pretend/nonredeemable stacking. |

The UI may use the familiar words deposit, withdrawal, loan, and repayment, but must not use them to suggest a financial service. Kid-facing surfaces use calm, everyday language rather than technical phrases such as “accepted balance,” “sync,” or “session,” and rather than heavy virtual/pretend disclaimers; parent surfaces retain the precise ledger, status, and nonredeemable vocabulary.

## 7. Core user journeys

### Journey A: parent setup

1. The parent opens the app and sees the virtual/nonredeemable explanation, including that signing in also checks their Apple account for a wallet they already have.
2. The parent signs in with Apple. On a device with no wallet, the app then checks that exact account for a wallet the parent already set up elsewhere.
3. If a recoverable wallet exists, the parent is offered a deliberate choice to bring it to this device before any setup form appears. Accepting recovers the complete existing wallet without re-setup; declining sends nothing and continues to fresh setup. If the check cannot be completed, setup stays available with a truthful note and a way to check again, and no wallet is ever moved without that explicit acceptance.
4. The parent creates the free one-device wallet and child profile with a nickname and optional avatar. No child email or exact birth date is required.
5. The parent sets a PIN. The app confirms that it protects the Parent area on this iPad and is not a device-wide parental control. A parent who recovered an existing wallet instead sets that PIN at the Parent door on first use.
6. The parent lands in the Parent area with a clear next action: set an allowance or add a first deposit, plus a prominent handoff that shows the child's wallet. Every later configured launch opens directly to the child's wallet.

Free setup commits directly to protected local authority and does not require the service. If setup is interrupted before that local save succeeds, the app must not imply that the wallet or child profile was saved. Optional Cloud activation is a separate parent flow and must never change authority until StoreKit verification and the service both accept it.

### Journey B: shared-iPad access through the parent door

1. A configured, signed-in device always opens to the child's read-only wallet. The kid home is the app's resting state on every cold launch and relaunch; there is no permanently visible role switch.
2. The kid home shows a small, clearly labeled **Parent** door with at least a 44-point touch target. Opening it always presents the full-screen PIN gate, which reveals no family or parent data.
3. A correct parent-set PIN opens a visually distinct, temporary **Parent area** with an explicit, always-visible way back to the child's wallet.
4. A wrong PIN stays on the gate without exposing parent content. Five consecutive misses pause the keypad for 30 seconds; the cooldown survives closing and reopening the gate but not process death. PIN changes require the existing PIN and happen only inside the Parent area.
5. Backgrounding, locking, or relaunching the app closes the Parent area and any parent flow in progress and returns to the child's wallet. Parent access is never persisted.
6. A forgotten or missing parent PIN is recovered through a fresh Sign in with Apple by the owning parent, after which the parent chooses a new PIN. Family data is unchanged, and full sign-out or re-setup is not required. There is no recovery-code system.
7. Signing out is available only inside the Parent area, asks for confirmation that explains the local removal, and returns the device to a neutral state with no usable family data.

The PIN is a local gate. It does not grant a role, change service permissions, or make a child session into a parent session.

### Journey C: parent records a money event

1. The parent opens the child's wallet and chooses a parent action.
2. The parent enters the amount and, where relevant, a reason, date, or loan due date.
3. A review step shows the event type, resulting wallet balance, and loan impact before confirmation.
4. The app shows the event as **Recorded** or **Not recorded** for free local authority. Service-authoritative wallets may also show **Waiting to sync**, with distinct copy when the service accepted the action but this device has not observed it in the wallet. It never presents an unresolved event as recorded.
5. Once accepted and observed by the current wallet authority, the event appears in the wallet activity list. It is immediately available to the child on the free one-device wallet and becomes available after synchronization for a service-authoritative wallet.
6. The child can open the event explanation but cannot edit, reverse, hide, or create a related event.

### Journey D: child reviews the wallet

1. The child sees the plain **Your allowance balance** label, the current accepted balance, the wallet activity list, and any open-loan card - without a persistent pretend/nonredeemable disclaimer on the hero.
2. The child taps an activity row or the loan card for details.
3. The child sees what changed, why it changed (human parent attribution), and whether the data is current.
4. The child cannot add, withdraw, loan, repay, request, edit, delete, or approve wallet dollars.

### Journey E: offline and session recovery

1. The free one-device wallet remains fully usable without network access. Reads and parent actions use protected local authority, never use a service session, and show accepted actions as **Recorded** without introducing a **Waiting to sync** state.
2. A service-authoritative wallet shown offline keeps its last accepted snapshot with a **Last updated** time, but that snapshot is read-only.
3. A service-authoritative wallet starts no money, allowance, or profile mutation while known offline or until a successful server read has confirmed the persisted replica revision. If connectivity is lost after an exact request has been protected and transport has started, the action is clearly marked **Waiting to sync** without changing the accepted balance.
4. On reconnect, the client reconciles only that protected request with the same body, expected revision, and idempotency key. The service either accepts it once or explicitly rejects it with a plain-language reason. A rejected command never changes the accepted balance.
5. An allowance or profile form may retain unsaved input while it remains open, but it must not create an offline rule, profile change, or queued mutation.
6. If a service session expires, the app keeps the cached read-only kid snapshot and explains in kid wording that a parent needs to sign in again. The Parent door then requires a fresh Sign in with Apple by the owning parent before the PIN gate; the child is not sent to Welcome and no parent content appears before reauthentication.

## 8. MVP screens and behavior

### 8.1 Welcome and sign-in

- Explain virtual, pretend, and nonredeemable dollars before asking for family data.
- Provide the parent Apple Sign In path, and say plainly that signing in also checks the parent's Apple account for a wallet they already have.
- Do not show Google Sign In in the MVP.
- A signed-out or failed first-run state contains no family balance or child data.
- The existing-wallet check is scoped to the exact signed-in parent, reads only, and never moves a wallet on its own. Recovery is a separate, clearly worded acceptance; declining, an unavailable service, and an account with no wallet all continue to ordinary free local setup.

### 8.2 Parent setup and child profile

- Parent creates one free one-device wallet and the configurable child profile.
- Required child data is limited to a nickname. Avatar is optional. Exact birth date, child email, contacts, and location are out of scope.
- Parent can update the nickname and avatar behind the PIN.
- The child profile is not an independent login and cannot be claimed by a child.

### 8.3 Kid home, Parent door, and Parent area

- The child's read-only wallet, labeled with the configured nickname when available and neutral wording otherwise, is the home screen and the app's only persistent surface.
- Parent access is a transient elevation entered through the labeled Parent door and the parent-set PIN. It is never persisted: cold launch, relaunch, and backgrounding always return to the kid home and close any parent flow in progress.
- The full-screen PIN gate always shows a visible Cancel, cannot be casually swiped away, and never exposes parent content on failure. Five consecutive misses use the 30-second cooldown defined in Journey B.
- A missing or forgotten PIN is reset only after a fresh Sign in with Apple by the owning parent (Journey B). PIN setup is never reachable from an un-elevated child session outside initial authenticated setup.
- Never leave hidden or disabled parent money controls in the child's wallet. Omit them; they exist only inside the visually distinct Parent area, together with PIN change and sign-out.

### 8.4 Wallet screens

The child's wallet is the app's home screen. The Parent area presents the parent view of the same wallet as a temporary, full-screen administrative space behind the PIN gate.

**Parent area** includes:

1. A parent-only editor for the configured child nickname.
2. The configured child profile's virtual balance and last update or authority state.
3. Next allowance information.
4. A secondary open-loan card, if a loan exists. Tapping it opens loan details.
5. Recent Activity visible directly on the wallet, with rows opening activity details.
6. Parent actions for allowance, deposit, withdrawal, loan, and repayment.
7. A minimal settings surface for changing the parent PIN (with the current PIN) and signing out (with confirmation).
8. An unmistakable Parent area header and a persistent, explicit exit back to the child's wallet.

**Kid home** includes:

1. The child's accepted balance under the plain label **Your allowance balance** (no stacked pretend/virtual/nonredeemable hero disclaimer).
2. Recent Activity directly on the wallet, or a friendly ready-state message while the wallet is still empty. There is no separate Recent Activity navigation item in the MVP.
3. The open-loan card and read-only loan details when applicable, in plain relational language.
4. Last-updated or stale status for a service-authoritative wallet when offline, in calm child wording.
5. The Parent door, visually secondary to the child content.

The kid home must not include a child request button, money action button, edit control, delete control, approval control, sign-out, or any other parent control.

### 8.5 Activity list and details

- The wallet contains the visible recent activity list. A parent can scroll it to review prior events; a separate Recent Activity entry point is not needed.
- Each accepted row opens details with type, amount, date, reason, and a plain-language explanation.
- Parent details may show before and after balances and keep the virtual/nonredeemable notice. Child details use simple wording such as “Your parent added US$10.00 as your weekly allowance.” without a heavy disclaimer footer.
- Unresolved parent events in a service-authoritative wallet show **Waiting to sync**, not a recorded state. Copy distinguishes an unconfirmed request from a service-accepted change that the device has not observed. Free-local actions are recorded immediately or fail without entering a pending state.
- Rejected events are visible to the parent with the reason and are not shown as accepted child activity.
- Accepted activity cannot be edited or deleted.

### 8.6 Allowance

The parent can create one simple active allowance rule for the child profile in the MVP.

Flow:

1. Choose **Set allowance**.
2. Enter an amount, a simple cadence initially centered on weekly allowance, a start date, and an optional end date.
3. Review a sentence such as “Add US$10.00 virtual dollars every Friday starting August 1.”
4. Save the rule behind the parent PIN.
5. Show the next expected date and distinguish the rule from an actual allowance entry.
6. When an allowance is due, the MVP may present a parent action to record it. It must not claim that an allowance was credited until the event is accepted.

Free-local authority records a valid rule immediately in protected local storage. A service-authoritative wallet must confirm its current replica revision online before submitting a rule change and must not queue an offline rule edit.

Editing or pausing a rule affects future occurrences only. It must not rewrite past activity. Exact automatic background scheduling, missed-occurrence catch-up, and additional cadences are open or future decisions.

### 8.7 Deposit flow

1. Parent chooses **Add deposit** from the wallet.
2. Parent enters a positive virtual dollar amount and an optional reason.
3. Review shows the resulting accepted balance and the persistent virtual-money notice.
4. With free-local authority, confirmation records the deposit immediately in protected local storage or reports **Not recorded** without changing the balance.
5. With service authority, confirmation requires a current online replica. If connectivity becomes ambiguous after submission, the exact protected command remains **Waiting to sync** and the child sees it only after service acceptance and synchronization are observed.

A deposit is bookkeeping inside Eddie's Wallet. It never charges, moves, or reserves real money.

### 8.8 Withdrawal flow

1. Parent chooses **Record withdrawal** or **Record dollars used**.
2. Parent enters an amount no greater than the accepted wallet balance and an optional reason.
3. Review shows the resulting balance. The app prevents accidental overdraft.
4. With free-local authority, confirmation records the withdrawal immediately in protected local storage or reports **Not recorded** without changing the balance.
5. With service authority, confirmation requires a current online replica and remains **Waiting to sync** if the submitted command's outcome becomes ambiguous. If another accepted event changes the balance first, the withdrawal is rejected rather than silently reduced.

The child has no spending or withdrawal control. A withdrawal means the parent recorded a virtual use of dollars; it is not a cash withdrawal.

### 8.9 Loan and repayment flow

The MVP loan model is parent-to-child, virtual, interest-free, and simple. It supports one open loan at a time for the child profile. The parent can optionally set a due date. Interest, fees, installments, and automatic repayment are out of scope.

**Create loan:**

1. Parent opens the wallet and chooses **Create loan**.
2. Parent enters principal, optional purpose, and optional due date.
3. Review explains that the loan adds virtual dollars to the child's wallet and creates an amount to repay.
4. Free-local authority records a valid loan immediately. Service authority records it only after service acceptance.
5. The wallet shows a secondary loan card such as “US$10.00 left to repay.”

**Repay:**

1. Parent opens the loan card and chooses **Record repayment**.
2. Parent enters a partial or full repayment amount.
3. The app shows the remaining principal after repayment and refuses an amount above the outstanding principal or available accepted wallet balance.
4. Free-local authority records a valid repayment immediately. Service authority requires a current online replica and records it after acceptance is observed; an ambiguous submitted request remains **Waiting to sync**.
5. A paid loan remains in history as **Paid** rather than disappearing.

**Child loan view:** The child can see the original loan, accepted repayments, and amount left to repay in plain language. The child cannot create a loan, repay, change terms, forgive a loan, or request money. The loan card remains on the wallet; there is no Loans tab in the MVP. Parent loan details keep the virtual/nonredeemable notice.


## 9. Roles and permissions

| Capability | Parent | Kid home |
| --- | --- | --- |
| Sign in with Apple | Required | Not required |
| Enter the Parent area | PIN required | Never |
| View accepted wallet and activity | Yes | Yes, read-only |
| Create/edit/pause allowance rule | Yes | No |
| Record deposit or withdrawal | Yes | No |
| Create loan or record repayment | Yes | No |
| View loan details | Yes | Yes, read-only |
| Edit/delete accepted money events | No; use a compensating event if needed | No |
| Create or edit child profile | Yes | No |
| Change parent PIN | Yes, with current PIN | No |
| Mark a money event complete or approved | No separate concept | No |
| Initiate a money request | No MVP workflow | No |
| Export or delete family data | Parent-only, behind the gate | No |

For a service-authoritative wallet, the external service must enforce the same boundary as the UI. A local child profile selection or PIN must never be treated as proof that a client may write parent data.

## 10. State, sync, and error behavior

Use the same status words everywhere:

| State | Required meaning |
| --- | --- |
| **Recorded** | Accepted by the current wallet authority and included in the accepted balance. In free mode that authority is protected local storage on this device; in paid Cloud mode it is the service. |
| **Waiting to sync** | A protected parent action is unresolved on this device. The service may not have confirmed it yet, or may have accepted it without the device observing the resulting entry or revision. It does not change the displayed accepted balance. |
| **Not recorded** | The current authority explicitly rejected the action, or free-local storage failed before acceptance. It does not change the accepted balance. |
| **Last updated** | Child or parent is viewing a cached snapshot whose freshness is shown. |
| **Draft on this iPad** | A setup or allowance form is local only and has not created a family rule. |

Acceptance and rejection must use text and icons, not color alone. A stale child screen may remain readable, but it must not call its balance current. A service outage must preserve the last good view and offer retry rather than showing an empty wallet.

## 11. Privacy and safety

- Keep the product clearly virtual. Do not use bank, cash-out, card, investment, or payment language except when explaining that those real-world concepts are outside the app.
- Collect only what is needed for the parent identity and the child profile: parent Apple identity, child nickname, and optional avatar.
- Do not require a child email, phone number, exact birth date, contacts, location, public profile, or free-text upload.
- Put family management, exports, account deletion, and external links behind the parent gate.
- Do not include child names, balances, loan details, or invite-like secrets in analytics, URLs, notifications, screenshots, or crash reports.
- Ship without ads, behavioral analytics, tracking, chat, public sharing, or payment integrations.
- Explain that the PIN protects this shared iPad from casual switching. It is not device-wide parental control and is not a substitute for server-side authorization.
- Keep child language calm and nonjudgmental. Do not call the child “in debt,” “bad with money,” or “behind.” Show repayment as a practice concept, not a punishment.
- Provide parent-controlled data export before public launch. Deletion behavior and retention are owned by the [privacy policy](privacy-policy.md).
- Before paid Cloud is offered, require the external service to meet the minimal recovery posture: daily backups and a nightly encrypted export, with a tested restore procedure. Do not add an enterprise audit console to the MVP.

## 12. External service boundary

This is a product constraint and client integration boundary, not an implementation plan. The service is maintained outside this public frontend repository.

- Free mode is fully useful on one device. Its protected local repository is authoritative for the one-child aggregate, accepted ledger events, balances, allowance rules, and loans. Paid Cloud mode uses the service as the sole accepted authority; the client never grants Cloud entitlement.
- The service must support idempotent parent commands so retries cannot duplicate deposits, withdrawals, loans, or repayments.
- Child reads must not have a path to mutate wallet, profile, allowance, loan, membership, or parent-PIN data.
- Before paid Cloud launch, the service must meet the recovery expectations in this document, including daily backups, a nightly encrypted export, and restore testing.
- Keep the app's product boundary independent of the service implementation and hosting. Do not expose provider-specific behavior in parent or child copy.

Apple Sign In is the only parent authentication method in the MVP. Google Sign In, identity linking, independent child authentication, and other providers are future scope.

## 13. Future ideas, not MVP requirements

These ideas may be valuable later but must not appear as required MVP work:

- Additional parents, multiple children, co-parent permissions, and independent child-device identities.
- Google Sign In and provider linking.
- Automatic background allowance scheduling, catch-up rules, push notifications, and richer cadence options.
- Child-initiated requests represented as a separate approval object.
- Interest-bearing loans, installments, due-date reminders, or configurable loan terms.
- Savings goals, jars, chores, rewards, multiple wallets, and multiple currencies.
- Restore tools, point-in-time recovery, advanced monitoring, and a larger operational control plane.
- Localized currency vocabulary beyond the initial US-dollar experience.

## 14. Open questions

These questions do not block the product boundary above. Questions that affect the free wallet must be answered before public launch; service-specific questions must be answered before paid Cloud is offered:

1. Which exact iOS/iPadOS versions and oldest iPad models are supported? *(Current implementation answer: the Xcode project declares an iOS/iPadOS 17.0 minimum for iPhone and iPad; the oldest supported hardware has not been decided.)*
2. Should the allowance MVP remain parent-confirmed on or after the due date, or should a reliable server job automatically record it?
3. What additional allowance cadences, if any, belong in the first release?
4. Which service implementation and operations plan meet the cost and recovery requirements, and who owns service incidents and restores?
5. Is the one-parent MVP sufficient for the pilot, or is a second authenticated parent a launch requirement?

## 15. MVP acceptance criteria

The free one-device MVP is product-complete when all of the following are true:

1. A parent can sign in with Apple, create one free wallet and a parent-managed child profile, and set a parent PIN without creating a child login.
2. On a shared iPad, the app rests on the child's read-only wallet, and entering the Parent area requires the parent-set PIN. The kid home never exposes parent money controls or sign-out.
3. Parent and safety surfaces label the US-dollar ledger as virtual, pretend, and nonredeemable. The kid home primary balance label is **Your allowance balance** without that heavy disclaimer; kid detail glances stay plain and relational while parent detail/review surfaces keep the boundary.
4. A parent can create a simple allowance rule, record a deposit, record a withdrawal, create an interest-free loan, and record a partial or full repayment.
5. Each accepted money event changes the accepted balance exactly once and appears in the wallet activity list with an understandable explanation.
6. Withdrawals and repayments cannot overdraw the wallet or exceed the outstanding loan. A loan adds virtual balance and creates a separate amount to repay.
7. The open-loan card is visible on the wallet and opens a detail flow. There is no prominent top-level Loans area, and the wallet does not duplicate a Recent Activity entry point.
8. The child can read the accepted balance, activity, and loan details, but cannot create or change any wallet, profile, allowance, loan, repayment, or request.
9. The free one-device wallet remains fully usable offline and records valid parent actions through protected local authority. Service-authoritative offline views show the last update time and remain read-only; a request interrupted after submission stays visibly unresolved, and rejected actions never appear as accepted balance changes.
10. The app collects no unnecessary child identity data and ships without real-money rails, ads, tracking, chat, or public sharing.
11. Paid Cloud is not offered until the external service meets the daily backup and nightly encrypted export requirements and a restore check has been completed.
12. A pilot parent can explain that the displayed US-dollar amounts are practice values that cannot be redeemed or spent. A pilot child can explain their allowance balance and recent parent-recorded changes in plain words without needing the legal framing.

## 16. Success criteria

Early MVP success is demonstrated by a small family pilot, not by transaction volume:

- A parent completes setup and records the first allowance or deposit without needing banking knowledge.
- A parent can tell the difference between a wallet balance, an allowance rule, and a loan outstanding, plus a pending command when using service authority.
- The child can explain why a balance changed and how much of a loan remains without being able to change it.
- No pilot parent mistakes the balance for spendable or redeemable money; parent UI continues to state the boundary clearly. The child understands the balance as allowance tracked with their parent.
- Offline and rejected states do not produce a false accepted balance in testing.
- Privacy review confirms that the child profile contains only the intended minimal data.
- If paid Cloud is included in the pilot, the service owner can restore its minimal production data posture from the daily backup and nightly encrypted export.

Public launch readiness still requires named owners and decisions for the open questions about platform support, scheduling, service recovery, and parent scope.
