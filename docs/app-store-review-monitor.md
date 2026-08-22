# App Store review-status monitor

This repository's scheduled monitor is `.github/workflows/app-review-monitor.yml`. It checks out the shared [`app-review-submit`](https://github.com/kunchenguid/app-review-submit) CLI at a committed pin and runs that tool's GET-only `monitor` command. The poll watches one armed Eddie's Wallet App Store marketing version and signals a state change through one exact-cycle GitHub issue.

Merging the PR that adds this code does **not** create an App Store Connect key, install secrets, submit a version, choose a live cycle, release a build, or enable App Review. It does not change the captain-only release PR or release flow. It does not touch a live App Review submission.

The Python tree in `tools/app-review/` is GET-only plus the one-shot EULA append.
Assemble-only mutation is the pinned shared Node engine, not a vendored submit
path.

## Live classification proof

`.github/workflows/app-review-monitor-e2e.yml` is the reusable GET-only gate that proves a candidate `app-review-submit` SHA against Eddie's real App Store Connect state. It checks out that SHA, reconstructs the read-only client, and runs `tools/app-review/observe_review_status.js`, which calls the engine's exported `observeReviewStatus`. It does **not** run `app_review_pipeline.js monitor` or `status`, does not create a GitHub issue, and does not mutate any App Store Connect resource.

Dispatch it from `main` after the workflow itself is merged:

```sh
gh workflow run app-review-monitor-e2e.yml -R kunchenguid/eddies-wallet --ref main \
  -f engine_sha=216a65513dbde70d04d0efd021792743f094ed77 \
  -f version=0.1.17 \
  -f expected_outcome=rejected
```

Those are also the workflow defaults. Bump the scheduled monitor pin in `app-review-monitor.yml` only after this live run classifies the armed version as the expected terminal class. A unit test, mock, or argument is not that proof.

## Pin and consumption

The workflow follows the shared tool's pinned-checkout consumption model:

1. Check out this repository (for `tools/app-review/app-review.config.json`).
2. Check out `kunchenguid/app-review-submit` at the exact 40-hex commit in the workflow `ref:` (`216a65513dbde70d04d0efd021792743f094ed77`, the merge of that repo's multi-submission classification fix, [PR #7](https://github.com/kunchenguid/app-review-submit/pull/7)) into `.app-review-submit`, using the already-configured `APP_REVIEW_SUBMIT_READ_TOKEN` and `persist-credentials: false`. That secret is a fine-grained PAT with `contents:read` on the private tool repo. The default `github.token` is scoped to this public repository and cannot clone it.
3. Run `node .app-review-submit/app_review_pipeline.js monitor` with `APP_REVIEW_CONFIG` pointing at the committed Eddie config.

Bump the pin only after a live `app-review-monitor-e2e.yml` run against Eddie's real App Store state classifies the expected terminal outcome, and after that repo's tests are green on the new commit. Reverting the pin restores the previous engine. Do not vendor the tool into this repository.

## Captain setup

The monitor reuses Eddie's **existing submit** App Store Connect key. Those secrets are already configured:

- `APP_STORE_CONNECT_KEY_ID`
- `APP_STORE_CONNECT_ISSUER_ID`
- `APP_STORE_CONNECT_API_KEY`

The private-tool checkout uses the already-configured GitHub secret `APP_REVIEW_SUBMIT_READ_TOKEN`. That is a fine-grained PAT with `contents:read` on `kunchenguid/app-review-submit` only. It is not an Apple credential. Do not invent a new token or any `ASC_REVIEW_MONITOR_*` secret. Do not map this token into the monitor step's environment or any other job. Do not change the tool repo's visibility.

Do not create a dedicated Developer-role monitor user. Do not add `ASC_REVIEW_MONITOR_KEY_ID`, `ASC_REVIEW_MONITOR_PRIVATE_KEY`, or any other `ASC_REVIEW_MONITOR_*` secret. The shared tool authenticates with those three submit fields and signs a team JWT (`credentials.jwtStyle: team` in the committed config, matching the submit key that already uses an issuer id).

Arming is the per-app Actions variable `APP_REVIEW_MONITOR_VERSION`. Its value is the exact submitted marketing version, for example `0.1.17`. An empty or unset variable is the deliberate state between cycles: the run reports `not_armed`, contacts Apple not at all, and **succeeds**, so the schedule does not stay permanently red between cycles. A reshaped value (anything that is not a one-to-three-component numeric version) **fails visibly** rather than being guessed at.

The shared config names `APP_REVIEW_MONITOR_VARIABLE_TOKEN` as the secret a
full submit path uses to write that arming variable. This monitor workflow
is GET-only and does not receive that token. Eddie's assemble-only job also
does not write `APP_REVIEW_MONITOR_VERSION` or `EDDIES_REVIEW_MONITOR_CYCLE`.
The gated `app-review-submit.yml` `mode=submit` job maps that token and the
engine writes `APP_REVIEW_MONITOR_VERSION` after Apple accepts.

## Verify and operate

The schedule polls every four hours, off the top of the hour. App Review states move in hours, not minutes, so a quieter cadence keeps the one notification that matters worth reading. A manual dispatch is always available when a faster answer is wanted: **Actions > Monitor App Store review status > Run workflow**. Dispatch polls the same armed `APP_REVIEW_MONITOR_VERSION`. It cannot submit, release, reject, cancel, upload, alter TestFlight, or change any App Store Connect resource.

The monitor reads only the stable Eddie App Store app resource `6795664301`, bound to bundle ID `com.kunchenguid.eddieswallet`, and requires exactly one matching iOS marketing version. It never lists apps or falls back to the newest version. It uses the shared tool's frozen GET-only `reviewSubmissions` queries. Pending polls stay silent. On a terminal or sustained-unavailable observation it creates one unassigned bookkeeping issue, closes it, and later deduplicates against that exact-cycle marker. The visible body names the app and whether the target resolved as approved or reached a non-approved terminal state. It never copies Apple resource ids, the marketing version, or credentials.

An empty `APP_REVIEW_MONITOR_VERSION` disarms the schedule. To stop the workflow from running at all, disable **Monitor App Store review status** in GitHub Actions (or remove its `schedule` trigger in a normal PR).

## Trust and API boundaries

The workflow has only `contents: read` and `issues: write` permission. The latter is required solely for the one bounded exact-cycle issue. It is triggered only by `schedule` and `workflow_dispatch`; it has no pull-request, workflow-run, repository-dispatch, or other untrusted-code trigger. GitHub schedules execute the committed default-branch workflow. The job is gated to `github.repository == 'kunchenguid/eddies-wallet'` and `github.ref == 'refs/heads/main'`; the shared tool also fail-closes on any other repository, ref, or event.

Do not run this workflow from a pull request, and do not invoke the shared tool's `submit` command from this workflow.

The live proof workflow has only `contents: read`. It is `workflow_dispatch` only, gated to this repository and `main`, and must not be given `issues: write` or a `GITHUB_TOKEN`. Do not run it from a pull request.
