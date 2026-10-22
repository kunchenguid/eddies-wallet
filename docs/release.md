# Release pipeline

Eddie's Wallet uses release-please for version PRs, changelog generation, tags, and GitHub Releases.
The native iOS app is then archived with Xcode on GitHub Actions and uploaded to TestFlight.
This file is the release-please and TestFlight pipeline only. Merging a release PR cuts the tag and uploads a build to TestFlight. It does not submit for App Review, release a reviewed version, or change price or availability. App Review is a separate captain gate in `docs/app-review.md`. The review-status monitor in `docs/app-store-review-monitor.md` is GET-only.

Repository variable `MAC_RUNNER` is `mini-mac`. The TestFlight archive job uses that label. Unset the variable to fall back to hosted `macos-26`. Do not change it as part of an ordinary release.
Repository variable `REAL_MAC_RUNNER` is unset today. When set, it takes precedence over `MAC_RUNNER` for the TestFlight archive job. That job signs with the captain's login keychain, so it must run on the real Mac rather than a throwaway virtual Mac. The Mac mini placement switch sets it to the label the placement service gives the real Mac's place; until then the job runs exactly as above.
That self-hosted runner has no passwordless `sudo`, so the job selects Xcode 26 by exporting `DEVELOPER_DIR` rather than with `sudo xcode-select`; `test/release-checks.sh` runs that step with a `sudo` that always refuses.
It also has no `node` on its `PATH`, so a pinned `actions/setup-node` step installs Node.js just before the development-certificate cleanup, under the same successful-Mac-mini-only condition and `continue-on-error` as the list step.

## The captain approval boundary

Merging a release-please release PR is the release trigger: it cuts the tag and starts the TestFlight upload.
An agent may merge or approve a release PR only if the captain explicitly asked. No automation may merge, auto-merge, or approve one.
Ordinary infrastructure and feature PRs carry no release side effects and follow the normal contribution flow.

## What happens on each release

1. Conventional commits on `main` cause release-please to open or update a release PR.
2. The release PR updates `version.txt`, `.release-please-manifest.json`, and `CHANGELOG.md`.
3. Merging the release PR creates a GitHub Release and a tag like `eddies-wallet-v0.1.0`.
4. The Release Please workflow dispatches `.github/workflows/release.yml` first for that tag, then best-effort dispatches `.github/workflows/ci.yml` for the same tag.
   A CI dispatch failure logs `gate-dispatch-failed-nonfatal` and does not prevent the TestFlight dispatch.
5. The TestFlight workflow checks out exactly the release tag, archives the Release build with automatic App Store Connect cloud signing, exports an IPA with `ExportOptions.plist`, uploads it with `xcrun altool --upload-app`, and runs a best-effort, list-only development-certificate check after a successful upload on the Mac mini (`.github/scripts/prune_asc_development_certs.js`; no certificate is revoked, and failures are warnings). The archive job selects its runner with repository variable `REAL_MAC_RUNNER`, then `MAC_RUNNER`, falling back to hosted `macos-26` when both are unset.
6. Release-time CI independently builds and tests the same tag.

Set `MAC_RUNNER=mini-mac` only after a runner with that label is registered for this repository. Deleting the variable immediately restores hosted `macos-26` selection for subsequent TestFlight jobs; it does not move the other release-time macOS CI jobs off hosted runners.

## Versions, build numbers, and traceability

Until the first release PR merges, `version.txt` and `.release-please-manifest.json` stay at the pre-release seed `0.0.0`.
release-please treats a `0.0.0` seed with no matching `eddies-wallet-v0.0.0` tag as "never released" and does not bump from that seed; the first proposal therefore comes from `initial-version` in `release-please-config.json`, which is set to `0.1.0` so the first tag is `eddies-wallet-v0.1.0` (not the library default `1.0.0`).
After that first cut merges, release-please advances the manifest/version seed to the released version (for example `0.1.0`); subsequent proposals bump from that lineage rather than from `initial-version`.
`test/release-checks.sh` is state-aware: it still enforces the pre-first-release `0.0.0` + `initial-version: 0.1.0` contract (including the missing-`initial-version` => `1.0.0` counterfactual), and once releases exist it requires the advanced seed to match the latest available lineage evidence (committed `CHANGELOG.md` headings plus any local `eddies-wallet-v*` tags present) instead of demanding a perpetual `0.0.0` seed.
The release PR header in that same config file warns that an agent may merge or approve it only if the captain explicitly asked.

`.github/scripts/resolve_release_version.sh` owns the derivation and is regression-tested by `test/release-checks.sh`:

- The App Store marketing version comes from the release tag, with a zero patch trimmed: `eddies-wallet-v0.1.0` archives with `MARKETING_VERSION=0.1`; a nonzero patch is kept.
- `CURRENT_PROJECT_VERSION` is `GITHUB_RUN_NUMBER.GITHUB_RUN_ATTEMPT`, so every uploaded build number is unique and monotonically valid for App Store Connect.
- Every build is traceable: the tag names the exact released commit, and the workflow run that produced a build number records both.

Retry semantics: rerunning a failed run (or dispatching `release.yml` again with the same `tag_name`) rebuilds the identical tagged source with the same marketing version and a fresh attempt-suffixed build number.
If App Store Connect already accepted a build for that version, the rerun uploads the next build number rather than colliding with or silently replacing the accepted build.
The workflow uses a per-tag concurrency group with `cancel-in-progress: true`, so overlapping same-tag runs are deduplicated to the newest; different tags never cancel each other.

## Check build status

Dispatch the App Store Connect status check with the marketing version:

```sh
gh workflow run asc-build-status.yml --ref main -f version=0.1
```

Add `--field build=<build-number>` to narrow the query to one build.
The run's final `ASC_BUILD_STATUS` line and its `asc-build-status` artifact (`build-status.json`) report the processing state.
The workflow resolves the app record from the committed bundle id `com.kunchenguid.eddieswallet`; if no App Store Connect app record exists yet it fails with an explicit prerequisite message.
Manual `workflow_dispatch` workflows become dispatchable only after they exist on the default branch.

Do not claim TestFlight success from a green upload step alone: success means App Store Connect accepted the exact build and shows it processing or available in TestFlight.

## Security and trust boundaries

- Ordinary pull requests (including forks) validate through `.github/workflows/ci.yml`, which references no secrets and runs with `contents: read`. Pull requests run only the Linux `checks` job for release-pipeline regressions; they do not use macOS runners. The tag-scoped `xcode` job runs the simulator-wrapper boundary and lifecycle tests, builds and unit-tests the Debug configuration, then compiles the Release configuration for generic iOS with signing disabled so Debug-only source cannot wait until a TestFlight archive to fail. The two `xcode-ui` matrix shards run the complete behavioral and evidence UI-test classes in parallel, each through its own run-scoped simulator teardown. Those macOS jobs fire only for `eddies-wallet-v*` tags, published releases, and explicit tag dispatches. No `pull_request_target` trigger exists in this repository.
- The release/upload App Store Connect credentials are reachable only from `eddies-wallet-v*` tag pushes, published releases, and explicit tag dispatches of `release.yml`/`asc-build-status.yml`. Tags and dispatches require repository write access. The review-status monitor's credential reuse and triggers are owned by [App Store review-status monitor](app-store-review-monitor.md).
- The release/upload App Store Connect private key is restored with mode `600` only in job-scoped runner temporary storage. The upload step makes the home-directory discovery copy required by `altool` only for the duration of that step, and an `always()` cleanup removes both copies after success, failure, or cancellation so a persistent self-hosted runner does not retain the key.
- All actions are pinned to full commit SHAs.
- The Apple team ID intentionally stays out of Git (see `EddysWallet/README.md`); `release.yml` reads it from the nonsecret `APPLE_TEAM_ID` repository variable and injects it into a runner-temp copy of `ExportOptions.plist`.
- `test/release-checks.sh` enforces all of the above and the version-derivation contract; CI runs it on every pull request, and it runs locally with no credentials or network.

## One-time setup (captain) - already complete for this repository

Every item below is already in place for `com.kunchenguid.eddieswallet` and is retained as reference only. No captain action is required, and the upload API key must not be recreated or rotated as part of ordinary work. See "Account-level prerequisites that are already satisfied" below.

1. **App Store Connect app record.** Create the iOS app for bundle id `com.kunchenguid.eddieswallet` on the owning Apple Developer team. The upload workflow does not need the numeric App Store Connect app ID; the status workflow resolves it from the bundle id.
2. **App Store Connect API key.** Reuse or create a key (Users and Access, Integrations) with App Manager or Admin role so the workflow can upload builds and Xcode can manage signing with `-allowProvisioningUpdates`. Record the Key ID and Issuer ID and keep the downloaded `.p8` private key file; Apple offers the download once.
3. **GitHub repository secrets**, set from a trusted machine (values never appear in argv, logs, or files):

   ```sh
   REPO=kunchenguid/eddies-wallet
   KEY_ID=REPLACE_WITH_KEY_ID
   ISSUER_ID=REPLACE_WITH_ISSUER_ID
   P8_PATH=/path/to/AuthKey_${KEY_ID}.p8

   printf '%s' "$KEY_ID" | gh secret set APP_STORE_CONNECT_KEY_ID --repo "$REPO"
   printf '%s' "$ISSUER_ID" | gh secret set APP_STORE_CONNECT_ISSUER_ID --repo "$REPO"
   base64 -i "$P8_PATH" | gh secret set APP_STORE_CONNECT_API_KEY --repo "$REPO"
   ```

   `APP_STORE_CONNECT_API_KEY` must hold the base64 of the `.p8` file. On GNU/Linux use `base64 -w0`. Never commit the `.p8` or its decoded contents.
4. **GitHub repository variable** `APPLE_TEAM_ID`: the Apple Developer team ID that owns the bundle id (nonsecret, but kept out of Git by repository convention):

   ```sh
   gh variable set APPLE_TEAM_ID --repo kunchenguid/eddies-wallet --body REPLACE_WITH_TEAM_ID
   ```

5. **Repository setting**: allow GitHub Actions to create pull requests (Settings, Actions, General, "Allow GitHub Actions to create and approve pull requests"), which release-please needs to open release PRs with the ephemeral `GITHUB_TOKEN`.

Optional:

- A TestFlight internal tester group, so accepted builds are installable immediately after processing.

## Account-level prerequisites that are already satisfied

Eddie's Wallet ships from a single Apple Developer team shared with other apps, so account-level setup is **not** per-app work and must not be requested again for this app:

- **Paid Applications agreement, tax, and banking** are already in place. Another app on the same team sells an approved paid in-app purchase with a live territory price schedule, which Apple does not permit without them.
- **App Store Connect API key**, iOS **distribution certificate**, and automatic signing are already in place and proven by accepted TestFlight uploads for this app.
- **Sandbox capability** exists at the account level through the active paid membership. A Sandbox Apple *Account* to test with is separate and is created in the App Store Connect console; the API cannot create one.

The remaining Cloud prerequisites are app-specific, and the App Store Connect side is already configured: see `docs/app-store-configuration.md` for the exact products, prices, policies, grace period, and notification URLs that exist today.

Backend receipt verification uses a distinct **In-App Purchase** key, which is a different key class from the App Store Connect API key above; the App Store Server API rejects the upload key. That In-App Purchase key already exists and is held in the captain's secret manager. No captain action, new key, or key conversion is required - installing it on the service host is ordinary backend work tracked outside this repository, and the issuer, key, app, and subscription group identifiers it needs are non-secret host configuration rather than secrets.

## Capabilities need Apple portal setup before release

Whenever a change adds or modifies an Apple capability or entitlement, complete its Apple Developer portal setup on the app's App ID before the next release.
Sign in with Apple is already enabled for this App ID; any future capability (and any identifier or container it requires) must be enabled and assigned the same way.
Automatic cloud signing cannot create a matching provisioning profile until that setup exists, so `Release to TestFlight` can fail with `No profiles for 'com.kunchenguid.eddieswallet' were found` or an authentication-looking error even when the API key and secrets are correct.
Treat that failure as a capability or portal gap, not an API-key problem.
Local validation never archives against App Store Connect, so a capability-touching change must verify portal readiness before release even when PR validation is green.

In-App Purchase is already enabled on this App ID, so the optional Cloud subscription needs no further capability or entitlement work.

## Development-certificate cleanup revokes team-wide, so local device signing can break

`.github/scripts/prune_asc_development_certs.js` replaces the old keep-newest-two cleanup with the INF-259 safe rule, **list-only**. There is no DELETE implementation or environment switch to enable revocation. The captain must read the first live list before a separately approved change can add revocation. Do not trigger a release just to obtain that list; inspect the next captain-approved release's cleanup step output.

The list runs only after a successful upload on a runner whose name starts `mini-mac`; hosted runners skip it. Both the workflow and script check the runner. A failed/missing archive, missing log, or unrecognised signing identity skips selection before contacting Apple. The archive log must contain `** ARCHIVE SUCCEEDED **` and a 40-hex signing fingerprint in every signing command. Every fingerprint is protected, including nested targets, rather than just the last signing command.

The script follows Apple's certificate-list pagination and lists a certificate as **Would revoke** only when all these checks pass:

1. Its API type is `DEVELOPMENT` and its decoded X.509 subject common name is `Apple Development: Created via API` (optionally followed by the parenthesized identifier).
2. Its SHA-1 certificate fingerprint differs from every identity used to sign this archive.
3. Its X.509 validity start (`notBefore`) is strictly more than 24 hours ago. Apple's certificate record has no `createdDate`; expiration is not creation time.
4. This job ran on the Mac mini, where release jobs share the runner's serialized heavy slot.

Personal, distribution, recent, future-dated, malformed, and unidentifiable certificates are kept. Output gives fingerprints and decision reasons, not names, key IDs, certificate content, or credentials. `ASC_CERTIFICATE_CLEANUP_ARCHIVE_LOG` points to this run's archive log. Legacy `ASC_CERTIFICATE_CLEANUP_KEEP`, `ASC_CERTIFICATE_CLEANUP_DRY_RUN`, and fixture environment variables no longer control the script.

The subject prefix is INF-259's observed marker for API-created certificates, **not cryptographic proof of which API key created them**; Apple supplies no creator-key field. `notBefore` is a conservative age proxy, not an API creation timestamp. Review the first live list with those limits in mind. No assumption that each job creates a new certificate is needed.

Apple scopes certificates to the **team**, not to an app, and this Apple team is shared with other apps. This repository now only lists candidates, but older tagged workflows and other apps may still revoke certificates using the old rule. A later revocation implementation would still affect device builds signed with a selected certificate; keeping this job's signer cannot prove an old certificate is unused on every other machine.

After a cleanup runs, `security find-identity -v -p codesigning` can report `CSSMERR_TP_CERT_REVOKED` for `Apple Development`, this app's development provisioning profile can show as `INVALID`, and `xcrun devicectl` can fail with "No provider was found" - so running on a physical device fails.

This never affects TestFlight or App Store distribution, which use the separate iOS distribution certificate. Treat a green release pipeline as still trustworthy.
The safe recovery is to let Xcode automatic signing regenerate a development certificate. Do not hand-edit signing settings, and do not rotate the App Store Connect API key in response.

## Failure handling and reruns

- Every failing step fails the workflow visibly; the archive and export logs (and any IPA) are uploaded as run artifacts even on failure.
- Rerun a failed upload from the workflow run page, or dispatch `release.yml` with the release tag. Source identity is preserved by the tag; build identity advances per attempt (see above).
- A rerun from the run page reuses the workflow as it was at the tag. When the failure was in the workflow itself and its fix is now on `main`, dispatch from `main` instead: `gh workflow run release.yml --ref main -f tag_name=<tag>` runs main's workflow and still checks out and builds exactly the tagged source.
- If an upload succeeded but processing stalls, query `asc-build-status.yml` rather than rerunning the upload.
- Nothing in a rerun can publish to the App Store; the pipeline ends at TestFlight.
