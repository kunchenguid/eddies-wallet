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
   is manual only, requires the version to be typed twice, and defaults to the
   `verify` dry run. `mode=assemble` stages the review submission and stops
   before Submit. `mode=submit` is a separate captain-gated dispatch that asks
   the engine to submit for review. Default remains `verify`.

There is deliberately **no protected GitHub Environment**. Adding one would give
the captain a second approval prompt for a run the captain just started by hand,
which is ceremony rather than a boundary. The manifest is the content gate and
the dispatch is the intent gate.

The App Review assemble and submit mutation credential belongs to
`app-review-submit.yml`'s assemble and submit jobs; the GET-only shared monitor
reuses that same submit key. A separate one-shot Guideline 3.1.2 workflow,
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
| 8. `app-review-submit.yml` with `mode=assemble` | Checks out `kunchenguid/app-review-submit@62bfbc3b` and runs assemble-only first-release (`--assemble-only --first-release`): 0.1.17 has no live baseline. The engine accepts a `REJECTED` target, writes App Info categories from config (`EDUCATION` + `FINANCE`), reuses the unresolved review submission by readback, attaches the app version plus both Cloud subscriptions, then hard-returns before Submit (`status: assembled`, `submitted: false`, `remaining: submit`). | App Store Connect assembly only. |
| 9. `app-review-submit.yml` with `mode=submit` | Same pin. Runs `full_submit.js --submit --first-release`, which calls `runSubmission({ assembleOnly: false })`. After Apple accepts, the engine writes `APP_REVIEW_MONITOR_VERSION`. | Apple's Submit for Review, plus monitor arming. |
| 10. `app-review-monitor.yml` | GET-only shared-tool poll of the armed marketing version, roughly every four hours; notifies on a terminal or sustained-unavailable observation. | One GitHub issue. |
| 11. `app-review-monitor-e2e.yml` | GET-only live classification of a candidate `app-review-submit` SHA via `observeReviewStatus`. Proves a pin against real ASC state. | Nothing. |

Steps 5 to 9 all take the same `version` twice. A mismatch refuses before
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
reconciles against authoritative Apple state first. 0.1.17 is Eddie's first
App Store version: the captain-approved manifest is first-release (no
`baselineVersion`), and assemble-only passes `--first-release`. That engine
accepts a `REJECTED` target and reuses the leftover `UNRESOLVED_ISSUES`
submission by readback, attaches the app version and every non-APPROVED Cloud
subscription, then hard-returns before Submit. Python prepare's GET reconcile
still refuses `REJECTED` as an unsupported draft state; that does not block
assemble-only. An uncertain create is never replayed, so a rerun cannot create
a second review submission.

After a successful assemble the review submission is staged and unsubmitted
(`status: assembled`, `submitted: false`, `remaining: submit`). The remaining
action is a second captain-gated dispatch: `mode=submit`. That path asks the
engine to submit for review and arms `APP_REVIEW_MONITOR_VERSION` after Apple
accepts. Assemble-only never maps the monitor variable token and never asks
the engine to submit. Eddie never invokes the shared pipeline submit
subcommand; the adapter maps onto `runSubmission`.

## Captain setup

Already in place and reused as-is: `APP_STORE_CONNECT_KEY_ID`,
`APP_STORE_CONNECT_ISSUER_ID`, `APP_STORE_CONNECT_API_KEY` (the shared release
and assemble/submit credential). The GET-only status monitor authenticates with
that same key. Checkout of the private shared tool uses the already-configured
`APP_REVIEW_SUBMIT_READ_TOKEN` (`contents:read` on `kunchenguid/app-review-submit`);
that token is not an Apple credential and is not mapped into the assemble,
submit, or poll steps. The gated submit job also maps
`APP_REVIEW_MONITOR_VARIABLE_TOKEN` so the engine can write
`APP_REVIEW_MONITOR_VERSION` after Apple accepts. Do not create a dedicated
monitor user or any `ASC_REVIEW_MONITOR_*` secret.

The live scheduled monitor reads `APP_REVIEW_MONITOR_VERSION` (the exact
marketing version). Assemble-only does not write that variable; the gated
`mode=submit` job does, after Apple accepts. Do not introduce a dedicated
`ASC_REVIEW_MONITOR_*` credential.

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
- Fall back to a browser submission. After assemble-only has staged the review
  submission, `mode=submit` is the remaining captain-gated action.
