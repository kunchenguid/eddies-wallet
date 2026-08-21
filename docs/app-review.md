# App Review submission pipeline

This is the operating guide for submitting one Eddie's Wallet version to App
Review. `tools/app-review/README.md` owns the module boundaries;
`docs/release.md` owns the separate release-please and TestFlight pipeline;
`docs/app-store-review-monitor.md` owns the monitor that watches the result.

Merging the pull request that adds this pipeline submits nothing. It creates no
App Store Connect resource, no credential, and no review submission. Every
workflow here is manual. The content half of the submission gate is now in
place: `tools/app-review/manifests/0.1.17.json` is the first captain-approved
manifest, merged on `main`. App Review remains HELD; nothing has been submitted.

## The gate

Submission is gated by two independent things, and both are the captain's.

1. **A captain-approved manifest merged on `main`.** `tools/app-review/manifests/<version>.json`
   pins the exact version, build, source commit, baseline, release behavior, the
   reviewed listing copy, every screenshot's bytes, the Cloud in-app purchase
   review assets and notes, and the App Review notes - all bound by a content
   hash and a manifest self-hash. Every workflow detaches to the commit that
   last changed that file, so a later push to `main` cannot change what a
   submission uses.
2. **The captain's explicit double-confirm dispatch.** `app-review-submit.yml`
   is manual only, requires the version to be typed twice, defaults to the
   `verify` dry run, and reaches its mutating job only when the dispatcher
   explicitly chooses `mode=assemble`. That job is assemble-only: it stages the
   review submission and stops before Submit. It never PATCHes `submitted: true`.

There is deliberately **no protected GitHub Environment**. Adding one would give
the captain a second approval prompt for a run the captain just started by hand,
which is ceremony rather than a boundary. The manifest is the content gate and
the dispatch is the intent gate.

The App Review assemble mutation credential belongs to
`app-review-submit.yml`'s assemble job; the GET-only shared monitor reuses that
same submit key. A separate one-shot Guideline 3.1.2 workflow,
`app-review-eula-append.yml`, maps that key to PATCH only the 0.1.17 en-US
description. Preparation and readiness use the same shared credential only
through the structurally GET-only client, and the verify lanes refuse to start
if any App Store Connect credential is present at all.

## Order of operations

| Step | What runs | What it may change |
| --- | --- | --- |
| 1. Release the candidate | The existing captain-merged release PR uploads the build to TestFlight (`docs/release.md`). | TestFlight only. |
| 2. Finish listing and review assets | Attended App Store Connect work: listing copy, screenshots, App Privacy answers, contact details, Cloud in-app purchase review screenshots and notes. | App Store Connect metadata, by hand. |
| 3. Attended functional proof | One physical-device proof of Sign in with Apple, the Parent gate, the Cloud plan offer, an Apple review or sandbox purchase, and Cloud activation, using a synthetic test account. A runner cannot do this: both steps are user-mediated. | Nothing in this repository. |
| 4. Approve the manifest | Generate the manifest from the final candidate and merge it after captain review. | The repository only. |
| 5. `app-review-prepare.yml` | Verifies the manifest, the double-confirm, and that every approved image still has its approved bytes; opens the durable recovery record. Then reconciles the manifest against authoritative Apple state, GET-only. | The recovery issue only. |
| 6. `app-review-demo-preflight.yml` | Proves the public reviewer path: the exact candidate and bound build, both Cloud products reviewable with delivered review assets, and the production service publishing Cloud activation with exactly those two products. Emits base64 readiness evidence. | Nothing. |
| 7. `app-review-submit.yml` with `mode=verify` | Re-checks the manifest, the bytes, the evidence freshness, and the recovery record, with no Apple credential. | Nothing. |
| 8. `app-review-submit.yml` with `mode=assemble` | Checks out `kunchenguid/app-review-submit@84f0317` and runs assemble-only: create or reuse one review submission, attach the app version plus both Cloud subscriptions, then hard-return before Submit (`status: assembled`, `submitted: false`, `remaining: submit`). | App Store Connect assembly only, never `submitted: true`. |
| 9. Captain Submit tap in App Store Connect | The remaining human action after a successful assemble. | Apple's Submit for Review. |
| 10. `app-review-monitor.yml` | GET-only shared-tool poll of the armed marketing version, roughly every four hours; notifies on a terminal or sustained-unavailable observation. | One GitHub issue. |
| 11. `app-review-monitor-e2e.yml` | GET-only live classification of a candidate `app-review-submit` SHA via `observeReviewStatus`. Proves a pin against real ASC state. | Nothing. |

Steps 5 to 8 all take the same `version` twice. A mismatch refuses before
anything else happens.

App Store Connect will not attach an `appStoreVersion` to a review
submission until the App Privacy / data-collection declaration is complete.
When incomplete, this surfaces through the ASC API as a generic attach
failure / HTTP 409 (the submission engine reports `did not attach the
approved candidate`), not a clear "App Privacy incomplete" error. If an API
submit fails at the version-attach step with a 409 / attach-failure while
the reads and write-path reconcile are otherwise correct, verify App Privacy
and App Information completeness in the App Store Connect UI before assuming
a code bug. Confirmed on 0.1.17, 2026-08-14: the blocker was an incomplete
App Privacy declaration, not the age rating, which was already saved.

## Readiness evidence

The preflight prints a base64 document naming the candidate, the manifest hashes,
a UTC timestamp, and its allowlisted check names. Paste it into the submit
dispatch's `evidence` input. Submission refuses evidence for another candidate,
another manifest, or one older than six hours.

This is a freshness and binding gate, not a proof of authorship: there is no
shared signing secret, because the dispatcher is already the captain. It exists
so a submission cannot quietly rely on a readiness check from last week.

## Recovery

The prepare step opens one GitHub issue keyed by app, version, manifest binding
hash, and manifest-approved commit, with a single mutable comment holding phase,
reconciliation outcome, and timestamp. Nothing else is recorded there.

Rerunning `mode=assemble` after an interruption is safe. The shared engine
reconciles against authoritative Apple state first: it creates or reuses one
review submission, attaches the app version and every non-APPROVED Cloud
subscription, then hard-returns before Submit. A leftover rejected submission
in `UNRESOLVED_ISSUES` is a genuine conflict; deletion is captain App Store
Connect UI, and this pipeline will not force it. An uncertain create is never
replayed, so a rerun cannot create a second review submission.

After a successful assemble the review submission is staged and unsubmitted
(`status: assembled`, `submitted: false`, `remaining: submit`). The only
remaining action is the captain's single Submit tap in App Store Connect
(App Review > the staged submission > Submit for Review). This repository has
no auto-submit path and does not arm the monitor from assemble-only.

## Captain setup

Already in place and reused as-is: `APP_STORE_CONNECT_KEY_ID`,
`APP_STORE_CONNECT_ISSUER_ID`, `APP_STORE_CONNECT_API_KEY` (the shared release
and assemble credential). The GET-only status monitor authenticates with that
same key. Checkout of the private shared tool uses the already-configured
`APP_REVIEW_SUBMIT_READ_TOKEN` (`contents:read` on `kunchenguid/app-review-submit`);
that token is not an Apple credential and is not mapped into the assemble or
poll steps. Do not create a dedicated monitor user or any `ASC_REVIEW_MONITOR_*`
secret.

The live scheduled monitor reads `APP_REVIEW_MONITOR_VERSION` (the exact
marketing version). Assemble-only does not write that variable; arm it
separately as `docs/app-store-review-monitor.md` describes after the captain
Submits. Do not introduce a dedicated `ASC_REVIEW_MONITOR_*` credential.

## What this pipeline will never do

- Submit because a release PR merged. TestFlight and App Review stay separate
  captain gates.
- Release. The manifest may only choose `MANUAL` or `AFTER_APPROVAL`.
- Create or edit listing copy, screenshots, products, App Review contacts, or
  the App Store version. It refuses instead, naming what is missing. A
  captain-directed one-shot exception lives in `app-review-eula-append.yml`: it
  may PATCH only the 0.1.17 en-US description to append Apple's standard EULA
  link. That is not listing-sync and does not submit for review. The next
  submit reconcile will see live description differ from
  `tools/app-review/manifests/0.1.17.json` until a new manifest that includes
  the line is generated and approved.
- Put an Apple Account credential, parent PIN, session, purchase payload,
  receipt, raw Apple response, or reviewer contact detail into git, an issue, a
  log, an artifact, a workflow input, or a runner argument.
- Fall back to a browser submission except for the captain's single Submit tap
  after assemble-only has already staged the review submission.
