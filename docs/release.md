# Release pipeline

Eddie's Wallet uses release-please for version PRs, changelog generation, tags, and GitHub Releases.
The native iOS app is then archived with Xcode on GitHub Actions and uploaded to TestFlight.
The pipeline mirrors a proven sibling-project release lifecycle: deliberate human control over the release trigger, unattended automation for everything after it.

Scope is TestFlight only. Nothing in this repository submits for App Store review, publishes publicly, or changes pricing, availability, or production state.

## The captain approval boundary

Merging a release-please release PR is the release trigger: it cuts the tag and starts the TestFlight upload.
Only the captain merges release PRs. No agent or automation may merge, auto-merge, or approve one.
Ordinary infrastructure and feature PRs carry no release side effects and follow the normal contribution flow.

## What happens on each release

1. Conventional commits on `main` cause release-please to open or update a release PR.
2. The release PR updates `version.txt`, `.release-please-manifest.json`, and `CHANGELOG.md`.
3. Merging the release PR creates a GitHub Release and a tag like `eddies-wallet-v0.1.0`.
4. The Release Please workflow dispatches `.github/workflows/release.yml` first for that tag, then best-effort dispatches `.github/workflows/ci.yml` for the same tag.
   A CI dispatch failure logs `gate-dispatch-failed-nonfatal` and does not prevent the TestFlight dispatch.
5. The TestFlight workflow checks out exactly the release tag, archives the Release build with automatic App Store Connect cloud signing, exports an IPA with `ExportOptions.plist`, uploads it with `xcrun altool --upload-app`, and runs best-effort App Store Connect development-certificate cleanup (`.github/scripts/prune_asc_development_certs.js` keeps the newest two `DEVELOPMENT` certificates and never touches distribution certificates; its failures are warnings).
6. Release-time CI independently builds and tests the same tag.

## Versions, build numbers, and traceability

Until the first release PR merges, `version.txt` and `.release-please-manifest.json` stay at the pre-release seed `0.0.0`.
release-please treats a `0.0.0` seed with no matching `eddies-wallet-v0.0.0` tag as "never released" and does not bump from that seed; the first proposal therefore comes from `initial-version` in `release-please-config.json`, which is set to `0.1.0` so the first tag is `eddies-wallet-v0.1.0` (not the library default `1.0.0`).
After that first cut merges, release-please advances the manifest/version seed to the released version (for example `0.1.0`); subsequent proposals bump from that lineage rather than from `initial-version`.
`test/release-checks.sh` is state-aware: it still enforces the pre-first-release `0.0.0` + `initial-version: 0.1.0` contract (including the missing-`initial-version` => `1.0.0` counterfactual), and once releases exist it requires the advanced seed to match the latest available lineage evidence (committed `CHANGELOG.md` headings plus any local `eddies-wallet-v*` tags present) instead of demanding a perpetual `0.0.0` seed.
The release PR header in that same config file is the captain-only warning; only the captain merges it.

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

- Ordinary pull requests (including forks) validate through `.github/workflows/ci.yml`, which references no secrets and runs with `contents: read`. No `pull_request_target` trigger exists in this repository.
- Apple credentials are reachable only from `eddies-wallet-v*` tag pushes, published releases, and explicit tag dispatches of `release.yml`/`asc-build-status.yml`. Tags and dispatches require repository write access.
- The App Store Connect API key exists on the runner only as a short-lived file under the runner's home (`chmod 600`), written from the secret for `xcodebuild`/`altool` authentication, and the runner is destroyed after the job. Never persist that key material anywhere else.
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

The remaining Cloud prerequisites are app-specific, and the App Store Connect side is already configured: see `docs/app-store-configuration.md` for the exact products, prices, policies, grace period, and notification URLs that exist today. The one credential still outstanding is a distinct **In-App Purchase** key for the backend's App Store Server API verification. That is a different key class from the App Store Connect API key above, and the App Store Server API rejects the upload key.

## Capabilities need Apple portal setup before release

Whenever a change adds or modifies an Apple capability or entitlement, complete its Apple Developer portal setup on the app's App ID before the next release.
Sign in with Apple is already enabled for this App ID; any future capability (and any identifier or container it requires) must be enabled and assigned the same way.
Automatic cloud signing cannot create a matching provisioning profile until that setup exists, so `Release to TestFlight` can fail with `No profiles for 'com.kunchenguid.eddieswallet' were found` or an authentication-looking error even when the API key and secrets are correct.
Treat that failure as a capability or portal gap, not an API-key problem.
Local validation never archives against App Store Connect, so a capability-touching change must verify portal readiness before release even when PR validation is green.

In-App Purchase is already enabled on this App ID, so the optional Cloud subscription needs no further capability or entitlement work.

## Development-certificate cleanup revokes team-wide, so local device signing can break

`.github/scripts/prune_asc_development_certs.js` keeps only the newest few `DEVELOPMENT` certificates and revokes the rest.
Apple scopes certificates to the **team**, not to an app, and this Apple team is shared with other apps that run the same cleanup.
So a release of this app can revoke a development certificate another machine or project was using, and a release of another app on the team can revoke this Mac's.

After a cleanup runs, `security find-identity -v -p codesigning` can report `CSSMERR_TP_CERT_REVOKED` for `Apple Development`, this app's development provisioning profile can show as `INVALID`, and `xcrun devicectl` can fail with "No provider was found" - so running on a physical device fails.

This never affects TestFlight or App Store distribution, which use the separate iOS distribution certificate. Treat a green release pipeline as still trustworthy.
The safe recovery is to let Xcode automatic signing regenerate a development certificate. Do not hand-edit signing settings, and do not rotate the App Store Connect API key in response.

## Failure handling and reruns

- Every failing step fails the workflow visibly; the archive and export logs (and any IPA) are uploaded as run artifacts even on failure.
- Rerun a failed upload from the workflow run page, or dispatch `release.yml` with the release tag. Source identity is preserved by the tag; build identity advances per attempt (see above).
- If an upload succeeded but processing stalls, query `asc-build-status.yml` rather than rerunning the upload.
- Nothing in a rerun can publish to the App Store; the pipeline ends at TestFlight.
