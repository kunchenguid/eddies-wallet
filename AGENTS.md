# Project agent memory

This public repository is the frontend and product home for Eddie's Wallet. Keep client behavior aligned with the product requirements in `docs/product-requirements.md`, especially the virtual-money language, parent/child permissions, and offline states. The root `README.md` is the public landing page; keep its status, setup, and limitation claims truthful for an unfinished, unreleased MVP.

The app's service implementation and operations are maintained separately. Keep this repository frontend-only: do not add backend source, migrations, credentials, deployment assets, or infrastructure configuration here.

Brand and interface guidance lives in the project skill at `.agents/skills/eddies-wallet-design/SKILL.md`; load it before changing visuals, copy, or assets. `.claude/skills` is a tracked relative symlink to `.agents/skills`, so keep skill directory names matching their `name:` frontmatter and keep file names exact-cased for case-sensitive checkouts.

Releases ship through release-please and a captain-merged release PR that uploads to TestFlight; `docs/release.md` is authoritative for the pipeline, its version lineage, trust boundaries, and Apple-side setup. Merging a release PR is the release trigger and belongs to the captain alone. `test/release-checks.sh` guards the workflow invariants, state-aware release-please lineage (pre-first `0.0.0` seed + `initial-version: 0.1.0`, and post-first advanced seed matching available CHANGELOG/tag lineage), and version derivation; run it (plus the normal test suite) after touching anything under `.github/`, `ExportOptions.plist`, `release-please-config.json`, `test/fixtures/release-lineage/`, or the version files release-please owns (`version.txt`, `.release-please-manifest.json`, `CHANGELOG.md` - never hand-edit those three).

The app is kid-first: the child's read-only wallet is the root, and parent access is a transient in-memory elevation (`WalletStore.elevation`) that must never be persisted or survive backgrounding. Kid-facing and gate chrome use consistent Parent terminology (`ParentDoorLabel`, "Parent only" gate, "Your parent" attribution) - not Grown-ups wording. There is no lessons product surface; `POST /v1/family/setup` still sends a residual `lessonAgeBand` wire value in `WalletAPI` until the private backend drops that field. Parent action buttons use `ActionButton`/`ActionButtonMetrics` with one continuous rounded geometry for fill and hit target - do not reintroduce `.buttonStyle(.bordered)` behind a mismatched card background. Signed-in states in simulators and UI tests are driven through the Debug-only launch seam in `EddysWallet/DebugScenarios.swift` (`EW_UITEST_SCENARIO`), never through real accounts. `EddysWallet.xcodeproj/project.pbxproj` is hand-maintained with deterministic hex IDs; follow the existing ID conventions when adding files or targets.

## Maintaining this file

Keep this file for knowledge useful to almost every future agent session in this project.
Do not repeat what the codebase already shows; point to the authoritative file or command instead.
Prefer rewriting or pruning existing entries over appending new ones.
When updating this file, preserve this bar for all agents and keep entries concise.
