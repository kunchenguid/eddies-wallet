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
   explicitly chooses `mode=submit`.

There is deliberately **no protected GitHub Environment**. Adding one would give
the captain a second approval prompt for a run the captain just started by hand,
which is ceremony rather than a boundary. The manifest is the content gate and
the dispatch is the intent gate.

The mutation-capable App Store Connect credential exists in exactly one step:
`app-review-submit.yml`'s submit job. Preparation and readiness use the same
shared credential only through the structurally GET-only client, and the verify
lanes refuse to start if any App Store Connect credential is present at all.

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
| 8. `app-review-submit.yml` with `mode=submit` | Aligns release behavior, bound build, and App Review notes to the manifest; reconciles; resumes or creates one review submission; submits; reads Apple back; then arms the monitor. | App Store Connect, within the manifest only. |
| 9. `app-store-review-status.yml` | Watches the armed cycle roughly every four hours and notifies on state transitions. | One GitHub issue. |

Steps 5 to 8 all take the same `version` twice. A mismatch refuses before
anything else happens.

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

Rerunning `mode=submit` after an interruption is safe. The engine reconciles
against authoritative Apple state first: if Apple already holds the candidate as
submitted it performs no write and completes only the monitor handoff. Otherwise
it reuses the single open review submission only when that submission is still
reusable and contains no item or only the exact candidate; an unrelated item,
state, or additional open submission is a conflict. After creating a submission
or attaching the candidate, the engine reads Apple back before proceeding. A
failed attach whose readback contains the exact candidate is complete; an absent
candidate is a bounded failure. An uncertain create is never replayed, so a
rerun cannot create a second review submission.

If Apple accepted the submission but the monitor handoff failed, rerun the same
dispatch. Only the handoff is outstanding, and it is a `GET`, then write, then
`GET` that is complete only when the variable reads back as the exact cycle.

## Captain setup

Already in place and reused as-is: `APP_STORE_CONNECT_KEY_ID`,
`APP_STORE_CONNECT_ISSUER_ID`, `APP_STORE_CONNECT_API_KEY` (the shared release
credential), and the monitor's own `ASC_REVIEW_MONITOR_KEY_ID` and
`ASC_REVIEW_MONITOR_PRIVATE_KEY`. Do not create a new Apple key for this
pipeline.

Still to create, before the first `mode=submit`:

- **`EDDIES_REVIEW_MONITOR_VARIABLE_TOKEN`** - a GitHub secret holding a
  fine-grained token for this repository with **Variables: read and write** and
  no other permission. The run's `GITHUB_TOKEN` cannot write Actions variables,
  so the submit job needs this one to arm the monitor. Until it exists, a
  submission that Apple accepts will refuse at the handoff and say so; rerunning
  the same dispatch once the secret is set completes only the handoff.

`EDDIES_REVIEW_MONITOR_CYCLE` is written by the submit handoff, not by hand. The
retiring `ASC_REVIEW_MONITOR_VERSION` and `ASC_REVIEW_MONITOR_BUILD` pair stays
readable until the first handoff is verified, then clear both together. Setting
the canonical variable and the pair to different cycles fails visibly rather
than silently preferring one.

## What this pipeline will never do

- Submit because a release PR merged. TestFlight and App Review stay separate
  captain gates.
- Release. The manifest may only choose `MANUAL` or `AFTER_APPROVAL`.
- Create or edit listing copy, screenshots, products, App Review contacts, or
  the App Store version. It refuses instead, naming what is missing.
- Put an Apple Account credential, parent PIN, session, purchase payload,
  receipt, raw Apple response, or reviewer contact detail into git, an issue, a
  log, an artifact, a workflow input, or a runner argument.
- Fall back to a browser submission.
