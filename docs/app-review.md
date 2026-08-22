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
   before Submit. `mode=upload` writes listing screenshots while the version is
   editable, before assemble attaches it, and does not submit
   (`upload_screenshots.js --upload-screenshots` onto
   `runSubmission({ uploadScreenshots: true })`, with
   `SCREENSHOT_UPLOAD_ENGINE_ARGV` pinned to
   `["node","app_review_pipeline.js","upload-screenshots"]`). If the version is
   already on an unsubmitted review submission, upload deletes only that version
   `reviewSubmissionItem` (Cloud items survive), then reserve/upload/commit and
   verify-before-live. Assemble, upload, and submit all check out `7053c9b6`,
   the merge of
   [`kunchenguid/app-review-submit#17`](https://github.com/kunchenguid/app-review-submit/pull/17).
   `mode=submit` is a separate captain-gated dispatch that asks
   the engine to submit for review. Default remains `verify`.

There is deliberately **no protected GitHub Environment**. Adding one would give
the captain a second approval prompt for a run the captain just started by hand,
which is ceremony rather than a boundary. The manifest is the content gate and
the dispatch is the intent gate.

The App Review assemble, upload, and submit mutation credential belongs to
`app-review-submit.yml`'s assemble, upload, and submit jobs; the GET-only shared monitor
reuses that same submit key. A separate one-shot Guideline 3.1.2 workflow,
`app-review-eula-append.yml`, maps that key to PATCH only the 0.1.17 en-US
description. Preparation and readiness use the same shared credential only
through the structurally GET-only client, and the verify lanes refuse to start
if any App Store Connect credential is present at all.

## Hands-off bar

The captain approves **what** ships and performs only true irreducibles. The
captain never performs an API-able App Store Connect step by hand. If an
API-able step is still missing from the shared engine, that is a tooling gap
for `kunchenguid/app-review-submit`, not a console chore.

### True irreducibles (captain only)

- Approving what ships: a captain-approved manifest on `main` plus the
  double-confirm dispatch.
- Credentials, the Paid Apps agreement, and tax/banking: already in place on
  the shared team. Never re-request them.
- App Privacy / nutrition-label answers: Apple exposes no public App Store
  Connect API. Incomplete declarations surface as HTTP 409 on version-attach
  (`E_APP_PRIVACY`). Confirmed blocker on 2026-08-14. Later assemble runs have
  failed earlier at listing screenshots, so completeness after that date is
  unproven until attach runs. This is the only remaining App Store Connect UI
  step in the 0.1.17 flow.
- Physical-device proof of Sign in with Apple, the Parent gate, and a sandbox
  Cloud purchase. Both steps are user-mediated; a runner cannot do them.
- Pasting demo-preflight evidence into the GitHub dispatch `evidence` input.
  That is a GitHub gate, not App Store Connect.

### Automated shared-engine behavior (assemble / upload / submit)

- App Info categories `EDUCATION` + `FINANCE`, even under `listingPolicy:
  observe`.
- Bound-build attach and `releaseType` (`alignmentWrites`).
- First-release review contact, notes, and `demoAccountRequired: false` from
  `config.reviewDetails`.
- Copyright on version create from `config.reviewDetails.copyright`. 0.1.17
  already carries it.
- Create or reuse the review submission; attach the app version, both Cloud
  subscription versions, and their subscription group version. Every item is
  proven through authoritative relationship readback before assembly succeeds.
- Reuse a leftover `UNRESOLVED_ISSUES` submission by readback. A subscription
  attach conflict is accepted as idempotent only when readback positively finds
  the intended item; otherwise the pending mutation stays unresolved and no
  duplicate create is attempted. Do not delete the submission in the console.
- Submit for review and arm `APP_REVIEW_MONITOR_VERSION` (`mode=submit`).
- Export compliance: uploaded builds already declare
  `usesNonExemptEncryption = false`.

### Screenshot upload

Listing screenshot reserve, upload, and commit is `mode=upload` before assemble
attaches the version (screenshots are locked once the version is
`READY_FOR_REVIEW`). Eddie maps onto `runSubmission({ uploadScreenshots: true })`
via `upload_screenshots.js --upload-screenshots`. The shared engine CLI, pinned
as `SCREENSHOT_UPLOAD_ENGINE_ARGV`, is `node app_review_pipeline.js
upload-screenshots`. Opt-in is `listing.screenshotWrites=true` on the
captain-approved manifest and config. `listingPolicy` stays `observe` so listing
copy is never written. Do not add `screenshots` to `alignmentWrites`. Asset path
is `{sourceRoot}/{listing.screenshotDirectory joined}/{fileName}`. Manifest
`content.screenshots[]` is `{displayType,width,height,files[{fileName,fileSize,sha256}]}`.
The engine computes MD5 of those bytes as Apple's `sourceFileChecksum`. This
lane uses the same shared-engine pin as assemble and submit. Replacement
reserves under a unique staging `fileName` (a set cannot hold two screenshots
with the same name), proves the reservation from the POST 201 body, commits
and polls `assetDeliveryState.state` to `COMPLETE`, then deletes the old
same-slot occupant and restores declared order.

### API-able, live already matches, no captain console this cycle

These have App Store Connect API. Live 0.1.17 already matches the approved
record. The captain does not open App Store Connect to re-enter them. If they
ever drift, the fix is an engine write, not a console paste.

| Surface | Current engine | 0.1.17 |
| --- | --- | --- |
| Listing copy (description, keywords, what's new, URLs, name, subtitle) | Writes only if `listingWritesAllowed("listing")`. This cycle stays `observe`. | Live matches, including the standard EULA line. |
| Cloud IAP review screenshots | Asserts products reviewable and attaches them. Does not upload review screenshots. Demo-preflight requires delivered bytes. | Both products `COMPLETE` (historical API upload). |
| Age rating | GET-validates present. Does not PATCH `ageRatingDeclarations`. | Already saved. |
| Content rights / Made for Kids | GET-validates `config.protected`. Does not PATCH. | Live matches. |
| Products, prices, grace period, notification URLs, app price | Observe / already configured. | Applied via API; see `docs/app-store-configuration.md`. |
| Copyright on an existing version | First-release writes copyright only on create. | 0.1.17 already has it. |

### Engine tooling gaps (API-able; never a captain console fallback)

Flag these to the shared-engine crew if they ever block a cycle. Do not invent
Eddie-side flags for them, and do not ask the captain to do them in the UI.

1. PATCH `ageRatingDeclarations` if the rating is missing or drifted.
2. PATCH `contentRightsDeclaration` / `isOrEverWasMadeForKids` if they drifted.
3. Reserve / upload / commit replacement Cloud IAP review screenshots
   (`subscriptionAppStoreReviewScreenshots`) if delivery ever leaves `COMPLETE`.
4. PATCH copyright on an existing App Store version if it drifted.
5. Create a missing App Store version while `listingPolicy` is `observe`. The
   engine can create when `listingWritesAllowed("version")`; 0.1.17 already
   exists.

## Order of operations

| Step | What runs | What it may change |
| --- | --- | --- |
| 1. Release the candidate | The existing captain-merged release PR uploads the build to TestFlight (`docs/release.md`). | TestFlight only. |
| 2. Bind listing screenshots | Distinct listing screenshots for every live display type live under `tools/app-review/assets/screenshots/<version>/` as `{fileName}` (engine path `{screenshotDirectory}/{fileName}`). The captain-approved manifest binds `displayType`, `width`, `height`, and `{fileName,fileSize,sha256}` per slot. App Privacy is the only remaining App Store Connect UI irreducible. See Hands-off bar. | Repository screenshot bytes. |
| 3. Attended functional proof | One physical-device proof of Sign in with Apple, the Parent gate, the Cloud plan offer, an Apple review or sandbox purchase, and Cloud activation, using a synthetic test account. A runner cannot do this: both steps are user-mediated. | Nothing in this repository. |
| 4. Approve the manifest | Generate the manifest from the final candidate and merge it after captain review. | The repository only. |
| 5. `app-review-prepare.yml` | Verifies the manifest, the double-confirm, and that every approved image still has its approved bytes; opens the durable recovery record. Then reconciles the manifest against authoritative Apple state, GET-only, including the default exact live listing-screenshot match. | The recovery issue only. |
| 6. `app-review-demo-preflight.yml` | Proves the public reviewer path: the exact candidate and bound build, both Cloud products reviewable with delivered matching review assets, and the production service publishing Cloud activation with exactly those two products. When `listing.screenshotWrites` is true, it defers only the live listing-screenshot match because the later `mode=upload` owns that live write. Emits base64 readiness evidence. | Nothing. |
| 7. `app-review-submit.yml` with `mode=verify` | Re-checks the manifest, the bytes, the listing-screenshot preflight, the evidence freshness, and the recovery record, with no Apple credential. | Nothing. |
| 8. `app-review-submit.yml` with `mode=upload` | Before assemble, while the version is editable. Runs the Eddie-side screenshot preflight, then `upload_screenshots.js --upload-screenshots --first-release` onto `runSubmission({ uploadScreenshots: true })` with `SCREENSHOT_UPLOAD_ENGINE_ARGV` set to `["node","app_review_pipeline.js","upload-screenshots"]`. If the version is already on an unsubmitted review submission, the engine deletes only that version item (Cloud items survive), then reserve/upload/commit and verify-before-live. It never submits. `listingPolicy` stays `observe`. `listing.screenshotWrites` is true. | Listing screenshots only. Version-item detach when recovering an already-assembled draft. |
| 9. `app-review-submit.yml` with `mode=assemble` | Checks out the pinned shared engine and runs assemble-only first-release (`--assemble-only --first-release`): 0.1.17 has no live baseline. The engine accepts a `REJECTED` target, writes App Info categories from config (`EDUCATION` + `FINANCE`), reuses the unresolved review submission by readback, attaches the app version, both Cloud subscription versions, and their subscription group version, proves every item by authoritative readback, then hard-returns before Submit (`status: assembled`, `submitted: false`). After upload, this re-attaches the version; Cloud items already on the draft stay. | App Store Connect assembly only. |
| 10. `app-review-submit.yml` with `mode=submit` | Same pin. Runs `full_submit.js --submit --first-release`, which calls `runSubmission({ assembleOnly: false })`. After Apple accepts, the engine writes `APP_REVIEW_MONITOR_VERSION`. | Apple's Submit for Review, plus monitor arming. |
| 11. `app-review-monitor.yml` | GET-only shared-tool poll of the armed marketing version, roughly every four hours; notifies on a terminal or sustained-unavailable observation. | One GitHub issue. |
| 12. `app-review-monitor-e2e.yml` | GET-only live classification of a candidate `app-review-submit` SHA via `observeReviewStatus`. Proves a pin against real ASC state. | Nothing. |

Steps 5 to 10 all take the same `version` twice. A mismatch refuses before
anything else happens.

App Store Connect will not attach an `appStoreVersion` to a review
submission until the App Privacy / data-collection declaration is complete.
Apple exposes no public readiness signal, so this surfaces as HTTP 409 on
attach (`E_APP_PRIVACY`: the declaration is *likely* incomplete). Confirmed
on 0.1.17, 2026-08-14: the blocker was App Privacy, not the age rating, which
was already saved. That questionnaire is a true irreducible. Do not treat
listing copy, review contact, categories, IAP review screenshots, or age
rating as console follow-ups when attach fails.

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
submission by readback, attaches the app version, every non-APPROVED Cloud
subscription version, and their subscription group version, proving every item
through authoritative relationship readback, then hard-returns before Submit.
Python prepare's GET reconcile still refuses `REJECTED` as an unsupported
draft state; that does not block assemble-only. A subscription create conflict
clears only when readback finds the intended item; an unproven create remains
pending and is not replayed. A rerun therefore cannot create a duplicate review
item or a second review submission.

When `listing.screenshotWrites` is true, upload runs before assemble so listing
images write while the version is editable. Upload writes listing screenshots
only (`status: screenshots_uploaded`, `submitted: false`). After a successful
assemble the review submission is staged and unsubmitted (`status: assembled`,
`submitted: false`). Submit asks the engine to submit for review and arms
`APP_REVIEW_MONITOR_VERSION` after Apple accepts. Assemble and
upload never map the monitor variable token and never ask the engine to submit.
Eddie never invokes the shared pipeline submit subcommand; the adapters map onto
`runSubmission`.

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
- Send the captain to App Store Connect for an API-able step. Listing copy
  stays `observe` this cycle because live 0.1.17 already matches. First-release
  assemble writes review contact, notes, and `demoAccountRequired: false`.
  Listing screenshot upload is a separate `mode=upload` job that does not
  submit (`--upload-screenshots`). `listing.screenshotWrites` is true;
  `listingPolicy` stays `observe`. All three mutation lanes use the shared-engine
  pin named in [The gate](#the-gate). A captain-directed one-shot exception
  lives in `app-review-eula-append.yml`: it
  may PATCH only the 0.1.17 en-US description to append Apple's standard EULA
  link. That is not listing-sync and does not submit for review. The 0.1.17
  captain-approved manifest listing description matches that already-live copy.
- Put an Apple Account credential, parent PIN, session, purchase payload,
  receipt, raw Apple response, or reviewer contact detail into git, an issue, a
  log, an artifact, a workflow input, or a runner argument.
- Fall back to a browser submission. After assemble-only has staged the review
  submission, `mode=submit` is the remaining captain-gated action.
