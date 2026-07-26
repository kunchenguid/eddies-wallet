# Eddie's Wallet

## Product requirements document

**Status:** Initial MVP PRD
**Product:** iPad/iOS virtual allowance app for a configurable child profile
**Audience:** Product, design, engineering, and review collaborators

Eddie's Wallet is the product brand: a calm, parent-managed family ledger that helps a child practice everyday money concepts. Parents record changes. The configured child profile can understand and review them. The balance uses familiar local currency vocabulary, initially US dollars, but it is always **virtual, pretend, and nonredeemable**. No real money moves through the product.

**Naming note:** The child nickname is configured during parent setup and returned by the service in each wallet snapshot. The app uses that nickname in parent and child-facing copy when available; otherwise it uses neutral language such as “your child” or “your wallet.” “Eddie's Wallet” is the application brand and does not set or imply a child nickname.

This document is the product starting point for the first MVP. The public repository is frontend-only; the service implementation and operations are maintained separately. This README defines client-facing behavior and does not include service or deployment implementation.

## 1. Settled decisions

These decisions are the current product direction and should not be reopened during MVP implementation without an explicit product decision:

- Use familiar local currency vocabulary, initially **US dollars**. Every balance and money event must be labeled as virtual, pretend, and nonredeemable.
- Do not connect to banks, cards, payment processors, cash, or any other real-money rail.
- Parent mode on a shared iPad is protected by a **parent-set PIN**. The PIN is a local gate against casual switching; service authorization remains authoritative.
- The first child experience is a **parent-managed child profile**, not an independent child login or Apple identity.
- **Apple Sign In is required** for the parent MVP. Google Sign In is future scope only.
- Do not include child-initiated money requests in the smallest MVP.
- Show loans as a secondary card on the wallet with a detail flow. Do not make Loans a prominent top-level navigation area.
- Use a short, linear starter lesson path rather than exposing a large lesson library.
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
4. Short lessons explain what each concept means.
5. The app stays honest about sync state and repeatedly explains that the balance cannot be spent or redeemed.

## 3. Target user and roles

### Primary user: parent

A parent or guardian uses a shared iPad or iOS device to set up the family, manage the child profile, record virtual money events, and decide which lesson age band the child sees. The parent needs confidence that the ledger is understandable, recoverable, and protected from accidental child changes.

### Child profile

The configured child profile uses a simple child view to check a virtual balance, understand activity, inspect an open loan, and follow the starter lessons. The child does not need an email address, Apple identity, password, or independent account in the MVP.

### MVP authority model

- The MVP has one signed-in parent owner and one parent-managed child profile.
- The parent is the only role that can create or change wallet data, the allowance rule, the child profile, or the parent PIN.
- Child mode is a view of the configured child profile, not a second account with independent authority.
- Future co-parent members and independent child-device identities must not be implied by MVP UI.

## 4. Product boundary

### In scope

- One family, one parent owner, and one child profile for the smallest launch slice.
- Parent authentication with Apple Sign In.
- Parent-set local PIN for entering parent mode on a shared iPad.
- A single virtual wallet for the child profile.
- A familiar US-dollar display vocabulary with persistent virtual/nonredeemable labeling.
- Parent-created allowance, deposits, withdrawals, loans, and repayments.
- A visible wallet activity list and activity details.
- A secondary open-loan card and loan detail flow.
- A short, linear starter lesson path.
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
5. Connect each money concept to a short, age-appropriate lesson.
6. Preserve trust when a device is offline or a command is rejected.
7. Minimize child data and keep the initial operational model simple.

### Non-goals

- Replacing a bank, allowance card, financial account, or payment app.
- Teaching every financial topic in the first release.
- Automating a full household allowance and chore system.
- Supporting arbitrary family roles, permissions, or account recovery policies.
- Optimizing for engagement through streaks, competition, rewards, or notifications.
- Choosing a particular service implementation or hosting vendor before cost, backup, monitoring, and on-call responsibilities are confirmed.

## 6. Money model and vocabulary

### Virtual balance

The wallet displays US-dollar vocabulary such as **US$24.00 virtual balance**. The amount is a simulated accounting value only. It is not a dollar claim, stored cash, credit, or promise from the parent or Eddie's Wallet.

The following copy must be persistent and easy to find, not hidden only in onboarding or settings:

> Virtual practice only. These dollars are pretend, cannot be redeemed, and never move real money.

The same meaning should appear in the wallet header, activity details, loan details, and lessons about cards or payments. Use plain language with the child and precise language with the parent. Do not use a bank-card design or wording that implies spendable funds.

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
| Allowance | A plan for when virtual dollars are added. |
| Deposit | Your parent added virtual dollars to your wallet. |
| Withdrawal | Virtual dollars were recorded as used or taken out of the wallet. |
| Loan | Virtual dollars you can use now and give back later. |
| Repayment | Virtual dollars returned to the family wallet. |
| Virtual balance | Pretend dollars for practice, not real money. |

The UI may use the familiar words deposit, withdrawal, loan, and repayment, but must not use them to suggest a financial service.

## 7. Core user journeys

### Journey A: parent setup

1. The parent opens the app and sees the virtual/nonredeemable explanation.
2. The parent signs in with Apple.
3. The parent creates the family and the child profile with a nickname, optional avatar, and lesson age band. No child email or exact birth date is required.
4. The parent sets a PIN. The app confirms that it protects parent mode on this iPad and is not a device-wide parental control.
5. The parent lands on the wallet with a clear next action: set an allowance or add a first deposit.

If setup loses connectivity before the family is created, the app must retain form input locally but must not imply that a family or child profile was saved.

### Journey B: switching on a shared iPad

1. The app shows the current role and a visible **Switch person** action.
2. Choosing the child profile opens child mode without exposing parent controls.
3. Choosing Parent requires the parent-set PIN.
4. A wrong PIN leaves the user in the current mode and does not reveal parent data. PIN changes require the existing PIN and parent authorization.
5. Signing out or revoking access returns to a neutral state with no usable family data.

The PIN is a local gate. It does not grant a role, change service permissions, or make a child session into a parent session.

### Journey C: parent records a money event

1. The parent opens the child's wallet and chooses a parent action.
2. The parent enters the amount and, where relevant, a reason, date, or loan due date.
3. A review step shows the event type, resulting wallet balance, and loan impact before confirmation.
4. The app shows the event as **Recorded**, **Waiting to sync**, or **Not recorded**. It never presents a pending event as accepted.
5. Once accepted, the event appears in the wallet activity list and becomes available to the child after the next successful sync.
6. The child can open the event explanation but cannot edit, reverse, hide, or create a related event.

### Journey D: child reviews the wallet

1. The child sees a persistent virtual balance label, the current accepted balance, the wallet activity list, any open-loan card, and the next lesson.
2. The child taps an activity row or the loan card for details.
3. The child sees what changed, why it changed, and whether the data is current.
4. The child follows the next lesson in order.
5. The child cannot add, withdraw, loan, repay, request, edit, delete, or approve virtual dollars.

### Journey E: offline recovery

1. A child offline sees the last accepted snapshot with a **Last updated** time and can read cached lessons.
2. A parent offline may queue an eligible money command only if the app has a recent accepted balance. The command is clearly marked **Waiting to sync**.
3. On reconnect, the server or API revalidates the command and either accepts it once or rejects it with a plain-language reason.
4. A rejected command never changes the accepted balance. Any provisional local display is reversed and the parent can retry after reviewing the reason.
5. Offline allowance setup is a local draft until it is accepted. The app must not claim that a rule or allowance occurrence exists while offline.

## 8. MVP screens and behavior

### 8.1 Welcome and sign-in

- Explain virtual, pretend, and nonredeemable dollars before asking for family data.
- Provide the parent Apple Sign In path.
- Do not show Google Sign In in the MVP.
- A signed-out or failed first-run state contains no family balance or child data.

### 8.2 Parent setup and child profile

- Parent creates one family and the configurable child profile.
- Required child data is limited to a nickname and a lesson age band. Avatar is optional. Exact birth date, child email, contacts, and location are out of scope.
- Parent can update the nickname, avatar, and age band behind the PIN.
- The child profile is not an independent login and cannot be claimed by a child.

### 8.3 Role picker and parent PIN gate

- Show the current role as either Parent or the child's view, labeled with the configured nickname when available and a neutral child-view fallback otherwise.
- Parent mode always requires the parent-set PIN after a role switch or when the app requires re-entry.
- Never leave hidden or disabled parent money controls in child mode. Omit them and show the read-only role clearly.
- PIN entry failures must not expose parent content. The exact retry lockout and recovery behavior are an open implementation question.

### 8.4 Wallet screen

The wallet is the primary screen for both roles, with role-specific behavior.

**Parent view** includes:

1. The configured child profile's virtual balance and last sync state.
2. Next allowance information.
3. A secondary open-loan card, if a loan exists. Tapping it opens loan details.
4. Recent Activity visible directly on the wallet, with rows opening activity details.
5. Parent actions for allowance, deposit, withdrawal, loan, and repayment.

**Child view** includes:

1. The child's accepted virtual balance and a clear practice-only label.
2. Recent Activity directly on the wallet. There is no separate Recent Activity navigation item in the MVP.
3. The open-loan card and read-only loan details when applicable.
4. The next lesson and linear progress.
5. Last-updated or stale status when offline.

The child wallet must not include a child request button, money action button, edit control, delete control, or approval control.

### 8.5 Activity list and details

- The wallet contains the visible recent activity list. A parent can scroll it to review prior events; a separate Recent Activity entry point is not needed.
- Each accepted row opens details with type, amount, date, reason, and a plain-language explanation.
- Parent details may show before and after balances. Child details use simple wording such as “Your parent added US$10.00 virtual dollars.”
- Pending parent events show **Waiting to sync**, not a success state.
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

Editing or pausing a rule affects future occurrences only. It must not rewrite past activity. Exact automatic background scheduling, missed-occurrence catch-up, and additional cadences are open or future decisions.

### 8.7 Deposit flow

1. Parent chooses **Add deposit** from the wallet.
2. Parent enters a positive virtual dollar amount and an optional reason.
3. Review shows the resulting accepted balance and the persistent virtual-money notice.
4. Confirmation creates one parent-recorded deposit, or a clearly pending command while offline.
5. The child sees it only after it is accepted and synced.

A deposit is bookkeeping inside Eddie's Wallet. It never charges, moves, or reserves real money.

### 8.8 Withdrawal flow

1. Parent chooses **Record withdrawal** or **Record dollars used**.
2. Parent enters an amount no greater than the accepted wallet balance and an optional reason.
3. Review shows the resulting balance. The app prevents accidental overdraft.
4. Confirmation creates a parent-recorded withdrawal, or a pending command subject to server revalidation.
5. If another accepted event changes the balance before sync, the withdrawal is rejected rather than silently reduced.

The child has no spending or withdrawal control. A withdrawal means the parent recorded a virtual use of dollars; it is not a cash withdrawal.

### 8.9 Loan and repayment flow

The MVP loan model is parent-to-child, virtual, interest-free, and simple. It supports one open loan at a time for the child profile. The parent can optionally set a due date. Interest, fees, installments, and automatic repayment are out of scope.

**Create loan:**

1. Parent opens the wallet and chooses **Create loan**.
2. Parent enters principal, optional purpose, and optional due date.
3. Review explains that the loan adds virtual dollars to the child's wallet and creates an amount to repay.
4. Confirmation records the loan only once accepted.
5. The wallet shows a secondary loan card such as “US$10.00 virtual dollars left to repay.”

**Repay:**

1. Parent opens the loan card and chooses **Record repayment**.
2. Parent enters a partial or full repayment amount.
3. The app shows the remaining principal after repayment and refuses an amount above the outstanding principal or available accepted wallet balance.
4. Confirmation records the repayment, or marks it pending while offline.
5. A paid loan remains in history as **Paid** rather than disappearing.

**Child loan view:** The child can see the original virtual loan, accepted repayments, amount left to repay, and a link to the borrowing lesson. The child cannot create a loan, repay, change terms, forgive a loan, or request money. The loan card remains on the wallet; there is no Loans tab in the MVP.

### 8.10 Starter lesson path

The child sees one short, linear next step instead of a full lesson library:

1. **Your virtual balance:** added, used, and remaining.
2. **Making a plan:** allowance, saving, and spending choices.
3. **Borrow and repay:** what a loan means and how repayment reduces what is owed.
4. **Cards and payments:** adults may use payment methods, but Eddie's Wallet does not connect to one and never moves real money.

Lessons should be short, readable aloud, and age-band appropriate. No countdowns, leaderboards, debt scores, shame language, or wallet-dollar rewards. Lesson completion may change local lesson presentation, but it cannot create or alter a money event. Synced child lesson progress is not required for the smallest read-only MVP.

## 9. Roles and permissions

| Capability | Parent | Child mode |
| --- | --- | --- |
| Sign in with Apple | Required | Not required |
| Enter parent mode | PIN required | Never |
| View accepted wallet and activity | Yes | Yes, read-only |
| Create/edit/pause allowance rule | Yes | No |
| Record deposit or withdrawal | Yes | No |
| Create loan or record repayment | Yes | No |
| View loan details | Yes | Yes, read-only |
| Edit/delete accepted money events | No; use a compensating event if needed | No |
| Create or edit child profile | Yes | No |
| Change parent PIN | Yes, with current PIN | No |
| Start and read lessons | May preview | Yes |
| Mark a money event complete or approved | No separate concept | No |
| Initiate a money request | No MVP workflow | No |
| Export or delete family data | Parent-only, behind the gate | No |

The external service must enforce the same boundary as the UI. A local child profile selection or PIN must never be treated as proof that a client may write parent data.

## 10. State, sync, and error behavior

Use the same status words everywhere:

| State | Required meaning |
| --- | --- |
| **Recorded** | Accepted by the authoritative service and included in the accepted balance. |
| **Waiting to sync** | A parent action is queued locally and has not been accepted. It is not spendable, owed, or final. |
| **Not recorded** | The action was rejected or failed. It does not change the accepted balance. |
| **Last updated** | Child or parent is viewing a cached snapshot whose freshness is shown. |
| **Draft on this iPad** | A setup or allowance form is local only and has not created a family rule. |

Acceptance and rejection must use text and icons, not color alone. A stale child screen may remain readable, but it must not call its balance current. A service outage must preserve the last good view and offer retry rather than showing an empty wallet.

## 11. Privacy and safety

- Keep the product clearly virtual. Do not use bank, cash-out, card, investment, or payment language except when a lesson explains that those real-world concepts are outside the app.
- Collect only what is needed for the parent identity and the child profile: parent Apple identity, child nickname, optional avatar, and lesson age band.
- Do not require a child email, phone number, exact birth date, contacts, location, public profile, or free-text upload.
- Put family management, exports, account deletion, and external links behind the parent gate.
- Do not include child names, balances, loan details, or invite-like secrets in analytics, URLs, notifications, screenshots, or crash reports.
- Ship without ads, behavioral analytics, tracking, chat, public sharing, or payment integrations.
- Explain that the PIN protects this shared iPad from casual switching. It is not device-wide parental control and is not a substitute for server-side authorization.
- Keep child language calm and nonjudgmental. Do not call the child “in debt,” “bad with money,” or “behind.” Show repayment as a practice concept, not a punishment.
- Provide parent-controlled data export and deletion behavior before public launch, subject to the final retention policy.
- Require the external service to meet the minimal recovery posture: daily backups and a nightly encrypted export, with a tested restore procedure. Do not add an enterprise audit console to the MVP.

## 12. External service boundary

This is a product constraint and client integration boundary, not an implementation plan. The service is maintained outside this public frontend repository.

- The service must be authoritative for family membership, parent permissions, accepted ledger events, balances, allowance rules, and loans.
- The service must support idempotent parent commands so retries cannot duplicate deposits, withdrawals, loans, or repayments.
- Child reads must not have a path to mutate wallet, profile, allowance, loan, membership, or parent-PIN data.
- The service must meet the recovery expectations in this document, including daily backups, a nightly encrypted export, and restore testing before launch.
- Keep the app's product boundary independent of the service implementation and hosting. Do not expose provider-specific behavior in parent or child copy.

Apple Sign In is the only parent authentication method in the MVP. Google Sign In, identity linking, independent child authentication, and other providers are future scope.

## 13. Future ideas, not MVP requirements

These ideas may be valuable later but must not appear as required MVP work:

- Additional parents, multiple children, co-parent permissions, and independent child-device identities.
- Google Sign In and provider linking.
- Automatic background allowance scheduling, catch-up rules, push notifications, and richer cadence options.
- Child-initiated requests represented as a separate approval object.
- Interest-bearing loans, installments, due-date reminders, or configurable loan terms.
- Savings goals, jars, chores, rewards, multiple wallets, multiple currencies, and investing lessons.
- A larger branching lesson library, quizzes, audio narration, and parent progress reporting.
- Restore tools, point-in-time recovery, advanced monitoring, and a larger operational control plane.
- Localized currency vocabulary beyond the initial US-dollar experience.

## 14. Open questions

These questions do not block the product boundary above, but must be answered before implementation or public launch:

1. Which exact iOS/iPadOS versions and oldest iPad models are supported?
2. Should the allowance MVP remain parent-confirmed on or after the due date, or should a reliable server job automatically record it?
3. What additional allowance cadences, if any, belong in the first release?
4. What is the parent PIN recovery path if the parent forgets it or changes devices?
5. What is the exact offline queue policy and how recent must the cached balance be before queuing a parent command?
6. What age band and launch countries determine lesson content, privacy review, and distribution decisions?
7. Is a local-only lesson completion state sufficient, or should child progress sync in a later release?
8. Which service implementation and operations plan meet the cost and recovery requirements, and who owns service incidents and restores?
9. What retention period and parent deletion behavior apply to family data and accepted ledger history?
10. Is the one-parent MVP sufficient for the pilot, or is a second authenticated parent a launch requirement?

## 15. MVP acceptance criteria

The MVP is product-complete when all of the following are true:

1. A parent can sign in with Apple, create one family and a parent-managed child profile, and set a parent PIN without creating a child login.
2. On a shared iPad, entering parent mode requires the parent-set PIN. Child mode never exposes parent money controls.
3. The wallet labels its US-dollar balance as virtual, pretend, and nonredeemable in the primary view and money detail views.
4. A parent can create a simple allowance rule, record a deposit, record a withdrawal, create an interest-free loan, and record a partial or full repayment.
5. Each accepted money event changes the accepted balance exactly once and appears in the wallet activity list with an understandable explanation.
6. Withdrawals and repayments cannot overdraw the wallet or exceed the outstanding loan. A loan adds virtual balance and creates a separate amount to repay.
7. The open-loan card is visible on the wallet and opens a detail flow. There is no prominent top-level Loans area, and the wallet does not duplicate a Recent Activity entry point.
8. The child can read the accepted balance, activity, loan details, and linear starter lessons, but cannot create or change any wallet, profile, allowance, loan, repayment, or request.
9. Offline views show the last update time. Queued parent actions are visibly pending, and rejected actions never appear as accepted balance changes.
10. The app collects no unnecessary child identity data and ships without real-money rails, ads, tracking, chat, or public sharing.
11. The external service meets the daily backup and nightly encrypted export requirements, and a restore check has been completed before launch.
12. A pilot parent and child can explain that the displayed US-dollar amounts are practice values that cannot be redeemed or spent.

## 16. Success criteria

Early MVP success is demonstrated by a small family pilot, not by transaction volume:

- A parent completes setup and records the first allowance or deposit without needing banking knowledge.
- A parent can tell the difference between a wallet balance, an allowance rule, a loan outstanding, and a pending command.
- The child can explain why a balance changed and how much of a loan remains without being able to change it.
- No pilot participant mistakes the balance for spendable or redeemable money.
- Offline and rejected states do not produce a false accepted balance in testing.
- Privacy review confirms that the child profile contains only the intended minimal data.
- The service owner can restore the minimal production data posture from the daily backup and nightly encrypted export.

The MVP should be considered ready for implementation only after the open questions that affect data, scheduling, recovery, and launch compliance have named owners and decisions.
