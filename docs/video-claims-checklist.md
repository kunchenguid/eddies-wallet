# Video claims checklist

Use this checklist while scripting and reviewing any video or public presentation of Eddie's Wallet. The video is a code walkthrough, not a launch announcement; the [README](../README.md) owns the product introduction. Every claim made on camera must match what this repository can actually prove.

## Six statements the video must make near the beginning

1. Displayed dollars are virtual, pretend, and nonredeemable. This is not a bank and it does not move real money.
2. Every displayed dollar is virtual, pretend, nonredeemable, and never moves real money.
3. Only a parent, inside the PIN-gated Parent area, records changes, except that the child can pay back an open loan from the wallet; the managed child profile has no independent account.
4. The free one-device wallet does not depend on the separately operated service; optional Cloud and legacy service-wallet compatibility do. Live Apple sign-in still requires Apple signing setup that is not part of this repository.
5. Local tests and builds include synthetic UI scenarios; they are not live-device proof. The live StoreKit, TestFlight, and backend evidence boundary is owned by [the App Store Connect configuration record](app-store-configuration.md#live-sandbox-evidence-and-remaining-boundaries).
6. Marketing versions 0.1.17 and 0.1.19 are App Store releases. Say that only together with the virtual-money limit. Do not claim every Cloud lifecycle event (renewal, refund, revocation) has been proven live unless `docs/app-store-configuration.md` says so.

## Claims that are supported by local evidence

These may be stated, with the qualifier that they were verified locally on a development machine:

- The repository can be cloned anonymously over HTTPS and opened with the shared `EddysWallet` scheme.
- The documented simulator test command passes (unit, transport-contract, and native UI tests, run against injected fakes and synthetic fixture data).
- Signing-independent Debug and Release simulator builds succeed.
- The signed-out welcome screen runs on iPhone and iPad simulators and states the virtual-money terms.
- The source is MIT licensed.

## Claims that must NOT be made or implied

- That a displayed balance is real money, a bank balance, or withdrawable.
- That optional Cloud was proven for every renewal, grace, refund, and revocation path.
- That local or synthetic tests prove live Apple sign-in, real-parent free-wallet setup, or the production service-wallet flow end to end.
- That retention, export, deletion, backups, or restore work is complete.
- That CI validates every push to the default branch. Pull requests run credential-free CI; the macOS test jobs run on release tags.
- That all supported iOS 17 devices were tested (recent verification used iOS 26 simulators only).
- That the public repository has always been frontend-only.

## Pre-publication verification checklist

Complete every item before publishing:

- [ ] The script contains all six mandatory statements, near the beginning.
- [ ] Every on-camera claim is either in the supported list above or backed by new, recorded evidence.
- [ ] No claim from the must-not list appears or is implied by visuals, captions, thumbnail, or description.
- [ ] All money values shown on screen are synthetic; no real child, family, account, or financial data appears.
- [ ] Screen recordings show only this public repository and the simulator; no private service code, operations detail, or credentials are visible.
- [ ] The video description links to this repository and describes it with the same status language as the README.
- [ ] The README, LICENSE, SECURITY.md, and SUPPORT.md on `main` still match what the video says at publication time.
- [ ] A final watch-through was done specifically to catch overstated status wording (for example claiming a balance is real money, or that every Cloud lifecycle event is proven).
