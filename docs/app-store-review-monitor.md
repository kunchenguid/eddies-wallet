# App Store review-status monitor

This repository contains an inert, read-only monitor in `.github/workflows/app-store-review-status.yml`. It watches one explicitly configured Eddie's Wallet App Review cycle and opens or comments on one exact-cycle GitHub issue only when its normalized App Store state changes.

Merging the PR that adds this code does **not** create an App Store Connect key, install secrets, submit a version, choose a live cycle, release a build, or enable App Review. It does not change the captain-only release PR or release flow.

## Captain setup

Do these steps only when there is a submitted review cycle to monitor:

1. In App Store Connect, open **Users and Access**. Create or use a dedicated automation user with the **Developer** role and access restricted to **Eddie's Wallet** only. Developer is the lowest role proven to cover the exact app-version and bound-build reads together. Do not use App Manager or the existing broad upload/release key.
2. While acting as that restricted user, create an **individual App Store Connect API key** from that user's profile. Individual keys inherit that user's Developer role and Eddie-only app access. Download its `.p8` once.
3. In the GitHub repository's **Settings > Secrets and variables > Actions > Secrets**, add these encrypted secrets:
   - `ASC_REVIEW_MONITOR_KEY_ID`: the API key identifier, as plain text.
   - `ASC_REVIEW_MONITOR_PRIVATE_KEY`: the complete PEM text of that key's downloaded `.p8` file, including its BEGIN and END lines.

   Enter the `.p8` only in GitHub's encrypted secret UI. Never commit it, encode it into a fixture, upload it as an artifact, or paste it into a command or log.
4. Arming the schedule is normally not a manual step. The App Review submit
   handoff writes the single canonical nonsecret variable
   `EDDIES_REVIEW_MONITOR_CYCLE` after Apple accepts a submission, and only then
   (`docs/app-review.md`). Its value is the exact compact JSON
   `{"build":"<build>","v":1,"version":"<version>"}`, for example
   `{"build":"123.1","v":1,"version":"0.1"}`.

   The retiring `ASC_REVIEW_MONITOR_VERSION` and `ASC_REVIEW_MONITOR_BUILD` pair
   is still read, so a cycle can be watched before the first automated handoff is
   verified. Retire them together once it is; never set one alone.

`.github/scripts/review_monitor_cycle.sh` resolves the cycle before any credential is in scope, and it distinguishes "no cycle to watch" from "the wrong cycle":

- **Nothing configured** - the deliberate state between review cycles. The run reports `notification=not-armed`, contacts Apple not at all, and **succeeds**. A schedule that failed here instead would keep this workflow permanently red between cycles, which is how a real transition notification gets ignored.
- **A canonical cycle** - the run polls exactly that version and build. One value is one whole cycle identity, which is why the handoff cannot leave the monitor half armed.
- **A reshaped canonical value** - anything that is not exactly the JSON the handoff writes **fails visibly** rather than being guessed at.
- **Exactly one of the retiring pair set** - a half cycle identity can only point at the wrong version or the wrong build, so the run **fails visibly**.
- **The canonical value and the retiring pair naming different cycles** - the run **fails visibly** instead of silently preferring one.

An armed cycle still refuses visibly when either value is malformed. The monitor reads only the stable Eddie App Store app resource `6795664301`, which is bound to bundle ID `com.kunchenguid.eddieswallet`, then requires exactly one matching iOS marketing version and that version's included, bound, unexpired build. It never lists apps or falls back to the newest version or build. A new cycle replaces the whole canonical value at once, and clearing it disarms the schedule.

## Verify and operate

The schedule polls every four hours, off the top of the hour. App Review states move in hours, not minutes, so a quieter cadence keeps the one notification that matters worth reading. A manual dispatch is always available when a faster answer is wanted.

Before relying on the schedule, use **Actions > Monitor App Store review status > Run workflow**. Enter the exact submitted version and build. This is a read-only dry/manual poll: it cannot submit, release, reject, cancel, upload, alter TestFlight, or change any App Store Connect resource. An active poll prints only its exact version, build, allowlisted state, normalized category, and whether its notification was sent or deduplicated. A cycle disabled by a closed issue prints only its exact version, build, and `notification=disabled`.

The individual-key JWT omits `iss`, uses `sub: "user"` and `aud: "appstoreconnect-v1"`, and scopes each token to the single `GET /v1/apps/6795664301/appStoreVersions` operation with the configured version, iOS platform, sparse fields, and included bound build. It contains no non-GET or cross-app scope.

The monitor maps all current `AppVersionState` values into `not-submitted`, `ready-for-review`, `waiting-for-review`, `in-review`, `waiting-on-apple`, `approved`, `action-required`, `withdrawn`, or `superseded`. `WAITING_FOR_EXPORT_COMPLIANCE` is waiting on Apple's compliance review, not a request for captain action. The monitor preserves and deduplicates the exact known enum. A future unrecognized value produces one bounded `UNKNOWN` transition, and no unknown Apple text is copied into logs or GitHub.

Each cycle's sole notification surface is the repository issue titled `App Store review monitor state: version <version>, build <build>`. Its hidden machine state accepts at most 32 exact-cycle entries. A state transition adds one bounded comment, and repeated polls in the same state do not comment again. Closing that issue deliberately disables the exact cycle: scheduled runs detect it before creating an Apple JWT, leave it closed, and perform no Apple request, issue write, or comment. To resume and deliberately re-notify, manually dispatch the workflow for the same version and build with **rearm** selected. Only that trusted manual path polls Apple and reopens the same issue; it never creates a second issue for the cycle. Rearming cannot release or mutate Apple state.

To disable one cycle, close its exact-cycle state issue. To disarm the schedule entirely, clear `EDDIES_REVIEW_MONITOR_CYCLE` and, while they still exist, the retiring pair: scheduled runs then report `notification=not-armed` and make no Apple request. To stop the workflow from running at all, disable **Monitor App Store review status** in GitHub Actions (or remove its `schedule` trigger in a normal PR). Disable or delete the dedicated monitor key if the monitor is permanently retired.

## Trust and API boundaries

The workflow has only `contents: read` and `issues: write` permission. The latter is required solely for the one bounded deduplication issue and transition comments. It is triggered only by `schedule` and `workflow_dispatch`; it has no pull-request, workflow-run, repository-dispatch, or other untrusted-code trigger. GitHub schedules execute the committed default-branch workflow.

Apple documents that team API keys are team-wide, while an individual key inherits its creator's role and app access. Apple documents App Store version state as `AppVersionState`; the older app-store-version-submission relationship is deprecated, so this monitor reads the App Store version and its bound build instead. See Apple's [role permissions](https://developer.apple.com/help/app-store-connect/reference/account-management/role-permissions/), [API key guidance](https://developer.apple.com/help/app-store-connect/get-started/app-store-connect-api), and [AppVersionState API reference](https://developer.apple.com/documentation/appstoreconnectapi/appversionstate).
