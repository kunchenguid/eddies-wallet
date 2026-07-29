# App Store review-status monitor

This repository contains an inert, read-only monitor in `.github/workflows/app-store-review-status.yml`. It watches one explicitly configured Eddie's Wallet App Review cycle and opens or comments on one GitHub issue only when its normalized App Store state changes.

Merging the PR that adds this code does **not** create an App Store Connect key, install secrets, submit a version, choose a live cycle, release a build, or enable App Review. It does not change the captain-only release PR or release flow.

## Captain setup

Do these steps only when there is a submitted review cycle to monitor:

1. In App Store Connect, open **Users and Access**. Create or use a dedicated automation user with the **App Manager** role and access restricted to **Eddie's Wallet** only. App Manager is the minimum role this monitor relies on for the app-version/review-status reads. Do not use the existing broad upload/release key.
2. While acting as that restricted user, create an **individual App Store Connect API key** in **Users and Access > Integrations**. Individual keys inherit that user's role and app access. Download its `.p8` once.
3. In the GitHub repository's **Settings > Secrets and variables > Actions > Secrets**, add these encrypted secrets:
   - `ASC_REVIEW_MONITOR_KEY_ID`: the API key identifier, as plain text.
   - `ASC_REVIEW_MONITOR_ISSUER_ID`: the App Store Connect issuer identifier, as plain text.
   - `ASC_REVIEW_MONITOR_PRIVATE_KEY`: the complete PEM text of that key's downloaded `.p8` file, including its BEGIN and END lines.

   Enter the `.p8` only in GitHub's encrypted secret UI. Never commit it, encode it into a fixture, upload it as an artifact, or paste it into a command or log.
4. In **Settings > Secrets and variables > Actions > Variables**, set the nonsecret exact-cycle variables:
   - `ASC_REVIEW_MONITOR_VERSION`: the submitted marketing version, for example `0.1`.
   - `ASC_REVIEW_MONITOR_BUILD`: the build number bound to that submitted App Store version, for example `123.1`.

The scheduled monitor refuses visibly when either variable is absent or malformed. It resolves the bundle ID `com.kunchenguid.eddieswallet`, exactly one matching marketing version, and that version's bound unexpired build. It never falls back to the newest version or build. Change both variables together for a new cycle.

## Verify and operate

Before relying on the schedule, use **Actions > Monitor App Store review status > Run workflow**. Enter the exact submitted version and build. This is a read-only dry/manual poll: it cannot submit, release, reject, cancel, upload, alter TestFlight, or change any App Store Connect resource. A successful run prints only its exact version, build, allowlisted state, normalized category, and whether a notification was sent or deduplicated.

The monitor uses only App Store Connect `GET` requests. It maps known App Store version states into `not-submitted`, `ready-for-review`, `waiting-for-review`, `in-review`, `approved`, `action-required`, `withdrawn`, or `not-for-sale`; an unrecognized state is reported as `UNKNOWN` and no Apple text is copied into logs or GitHub.

The sole notification surface is the repository issue titled `App Store review monitor state`. Its hidden machine state keeps at most 32 exact cycles. A state transition adds one bounded comment. Repeated scheduled polls in the same state do not comment again. To deliberately re-notify the current state, run the workflow manually for that same exact version/build with **rearm** selected. Rearming only resets GitHub notification deduplication - it cannot release or mutate Apple state.

To disable polling, disable the **Monitor App Store review status** workflow in GitHub Actions (or remove its `schedule` trigger in a normal PR). Removing the two nonsecret cycle variables also makes scheduled runs fail closed. Disable or delete the dedicated monitor key if the monitor is permanently retired.

## Trust and API boundaries

The workflow has only `contents: read` and `issues: write` permission. The latter is required solely for the one bounded deduplication issue and transition comments. It is triggered only by `schedule` and `workflow_dispatch`; it has no pull-request, workflow-run, repository-dispatch, or other untrusted-code trigger. GitHub schedules execute the committed default-branch workflow.

Apple documents that team API keys are team-wide, while an individual key inherits its creator's role and app access. Apple documents App Store version state as `AppVersionState`; the older app-store-version-submission relationship is deprecated, so this monitor reads the App Store version and its bound build instead. See Apple's [role permissions](https://developer.apple.com/help/app-store-connect/reference/account-management/role-permissions/), [API key guidance](https://developer.apple.com/help/app-store-connect/get-started/app-store-connect-api), and [AppVersionState API reference](https://developer.apple.com/documentation/appstoreconnectapi/appversionstate).
