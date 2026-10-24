# Eddie's Wallet

Eddie's Wallet is a native SwiftUI app for iPhone and iPad. Marketing versions 0.1.17, 0.1.19, 0.1.21, and 0.1.22 have been submitted to App Review and approved; their manifests use release type AFTER_APPROVAL, so approval releases the version. 0.1.23 was submitted to App Review on 2026-10-23 with the same release type. The App Store listing, TestFlight pipeline, and App Review pipeline are documented in `docs/app-store-configuration.md`, `docs/release.md`, and `docs/app-review.md`.

Every dollar the app displays is virtual, pretend, and nonredeemable. No real money ever moves through Eddie's Wallet. Optional Cloud is backup and sync for one parent household, billed as the auto-renewable subscriptions in `docs/app-store-configuration.md`. It is not a bank, a card, or a cash-out path.

What is still limited: renewal, grace, expiry, refund, and revocation have not all been exercised as a full live proof, and the README must not outrun `docs/app-store-configuration.md` on those boundaries. Parent-controlled export remains a product-requirements item.

One signed-in parent creates allowance and loan schedules and records deposits, withdrawals, loans, and manual repayments; a free local wallet settles a small due set from those schedules when it is read. The managed child profile has no independent account or login, and the child's only way to change the wallet is **Pay back**: paying part or all of an open loan from the wallet's own virtual dollars, labelled as the child's payment.

**Who this is for:** developers and reviewers who want to explore a small, dependency-free SwiftUI client, and anyone following the product concept in the [product requirements document](docs/product-requirements.md).

## What exists today

- A native SwiftUI iOS/iPadOS app (`EddysWallet.xcodeproj`) targeting iOS 17.0+, iPhone and iPad, with no third-party dependencies.
- A kid-first navigation model: a configured device rests on the child's wallet, whose only action is the child's own loan payment, and all parent money flows, child nickname editing, the allowance rule, PIN change, in-app account deletion, and sign-out live in a temporary full-screen Parent area behind a quiet Parent door and the parent-set PIN. Parent access is never persisted; backgrounding or relaunching always returns to the kid home. A forgotten PIN is recovered with a fresh Sign in with Apple by the owning parent.
- Money-event flows with review steps and honest offline/pending/rejected states, implemented against the [product requirements](docs/product-requirements.md). On successful reads, free local wallets settle a bounded due set from parent-created weekly allowance rules and weekly or monthly loan plans; allowance credits run before loan debits, and an underfunded installment waits without overdrawing. Parents can still deliberately settle a larger missed set as separate entries. When Cloud is on, the service settles scheduled allowance and loan occurrences while the client reads accepted results from the existing changes feed and never auto-writes them itself. Cloud-authoritative manual writes retain one exact revision-guarded, idempotent request through response loss and relaunch, and report service acceptance separately from local replica observation.
- Unit, contract-style transport, and native UI tests in the shared scheme that default to injected fakes and never call production, including deterministic Cloud write settlement and parent-visible evidence states. One opt-in test can exercise the production client against a separately started synthetic loopback service and disposable database.
- A copied web design system and click-through prototype, packaged as the `eddies-wallet-design` agent skill under `.agents/skills/eddies-wallet-design/`, kept as visual reference material; the native app is the maintained implementation.
- A `0.1.0` source release and `eddies-wallet-v0.1.0` tag, with release notes in `CHANGELOG.md`.

## Getting started

Prerequisites: a Mac with Xcode 26.4 or later (this repository was last verified with Xcode 26.4 and the iOS 26.4 simulator runtime). There are no package-manager dependencies to resolve, and no Apple developer account is needed for simulator builds and tests.

Clone anonymously over HTTPS:

```sh
git clone https://github.com/kunchenguid/eddies-wallet.git
cd eddies-wallet
```

Open `EddysWallet.xcodeproj` in Xcode and use the shared `EddysWallet` scheme, or work from the command line. Run the command-line test suite in the iOS Simulator through `test/sim.sh`, which creates a throwaway simulator, runs the command headlessly on it, and deletes that simulator on every trappable exit. If the wrapper itself is forcibly killed, the next invocation reaps its orphaned run-scoped device:

```sh
./test/sim.sh -- xcodebuild test \
  -project EddysWallet.xcodeproj -scheme EddysWallet \
  -destination 'platform=iOS Simulator,id={{UDID}}'
```

`{{UDID}}` is replaced with the booted device. Never point `xcodebuild` at a simulator you created by hand: those devices stay booted long after the run that made them. CI routes every command that boots or runs a simulator device through this wrapper, and `./test/sim.sh --help` documents its device and runtime options.

Build a signing-independent Release binary for the simulator without the wrapper. This compile-only exception uses a generic destination that resolves to the SDK, so it neither boots nor creates a simulator device:

```sh
xcodebuild -project EddysWallet.xcodeproj -scheme EddysWallet \
  -configuration Release -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build
```

`test/sim.sh` prefers an iPhone 17 Pro on the iOS 26.4 runtime and falls back to an iPhone 17 and to the newest installed iOS runtime; `./test/sim.sh --device "iPad (A16)" -- ...` picks another family (`xcrun simctl list devicetypes` lists them). The declared deployment target is iOS 17.0, but recent verification used iOS 26 simulators.

**Signing expectations:** building and testing in the simulator requires no signing setup. Actually exercising Sign in with Apple requires membership in the Apple Developer team that owns the app ID, as described in [`EddysWallet/README.md`](EddysWallet/README.md); that is an external prerequisite this repository cannot provide, and nothing in this repository requires it for local builds or tests.

## Architecture boundary

This repository contains only the client. A complete free wallet is stored locally on one device in protected Core Data, where it is the accepted authority. The optional Cloud design uses a separately maintained, privately operated service through a small versioned HTTP API; its source, operations, and credentials are not part of this repository. `LocalWalletRepository` owns free-local data, while the Cloud client keeps server authority for Cloud households. The authoritative live StoreKit and backend evidence boundary is in [`docs/app-store-configuration.md`](docs/app-store-configuration.md); client behavior is detailed in [`EddysWallet/README.md`](EddysWallet/README.md).

## Project layout

| Path | Contents |
| --- | --- |
| `EddysWallet/` | App source: views, models, API client, design tokens, and a [client README](EddysWallet/README.md) covering configuration, keychain use, and signing |
| `EddysWalletTests/` | Unit and transport-contract tests |
| `EddysWalletUITests/` | Native UI tests and the synthetic screenshot tour |
| `EddysWallet.xcodeproj` | Xcode project with the shared `EddysWallet` scheme |
| `test/` | The simulator lifecycle wrapper (`sim.sh`) and library, their boot-free boundary and lifecycle checks, and release pipeline regressions |
| `docs/` | Product requirements, release guidance, the live App Store Connect configuration record, presentation claims, and screenshots |
| `.agents/skills/eddies-wallet-design/` | Copied web design system and prototype, packaged as an agent skill and kept as visual reference; `.claude/skills` is a symlink to `.agents/skills` so Claude Code discovers the same directory |

## Known limitations

- Marketing versions 0.1.17 and 0.1.19 are App Store releases. Every displayed dollar stays virtual, pretend, and nonredeemable. Renewal, grace, expiry, refund, and revocation have not all been exercised as a full live proof; that boundary stays in the [App Store Connect configuration record](docs/app-store-configuration.md).
- A simulator build is not the App Store release on a device. The `0.1.0` source release and `eddies-wallet-v0.1.0` tag remain in this repository for the source. Account deletion's server side (`DELETE /v1/account`) is a coordinated separate backend ship not present in this repository.
- Pull requests run credential-free release-pipeline checks on Linux GitHub Actions; Xcode build, simulator-wrapper, and UI tests run on macOS for release tags. Everything else about verification remains local evidence.
- The declared iOS 17.0 minimum has not been exercised on an iOS 17 simulator runtime recently.
- The `.agents/skills/eddies-wallet-design/` prototype is unmaintained reference material and may not run as-is.
- The finalized [privacy policy](docs/privacy-policy.md) records the app's privacy, retention, and deletion behavior and is published at https://eddies-wallet.kunchenguid.com/ through GitHub Pages (`site/`, deployed by `.github/workflows/pages.yml`); the optional Cloud plans card links to it. Parent-controlled data export required for a public launch is still open in the [product requirements](docs/product-requirements.md).

## Support and security

- Questions about building, the source, or the documentation: open a public [GitHub issue](https://github.com/kunchenguid/eddies-wallet/issues). See [SUPPORT.md](SUPPORT.md).
- Security or privacy findings, especially anything touching children or family data: use the private reporting route in [SECURITY.md](SECURITY.md). Please never post sensitive findings publicly.

## Documentation

- [Product requirements document](docs/product-requirements.md): the full MVP PRD this app implements.
- [Video claims checklist](docs/video-claims-checklist.md): the limitations any public presentation of this repository must state.
- [Client README](EddysWallet/README.md): API configuration, keychain behavior, signing prerequisites, and the manual test sequence.
- [Release pipeline](docs/release.md): the release-please and TestFlight automation, its approval boundary, and its one-time setup.
- [App Store Connect configuration](docs/app-store-configuration.md): the optional Cloud products and policies configured in the live store, plus the work that remains unproven.
- [App Review submission](docs/app-review.md): create-version, upload, assemble, and submit, run once the captain merges the version's manifest. Merging a release PR does not submit.
- [App Store review monitor](docs/app-store-review-monitor.md): the four-hour poll and how it notifies the captain, then closes its own outcome issue.

## License

Eddie's Wallet is licensed under the [MIT License](LICENSE), Copyright (c) 2026 Kun Chen.
