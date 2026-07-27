# Video claims checklist

Use this checklist while scripting and reviewing any video or public presentation of Eddie's Wallet. The video is a code walkthrough of an unfinished frontend MVP, not a launch announcement. Every claim made on camera must match what this repository can actually prove.

## Six statements the video must make near the beginning

1. This is an unfinished frontend MVP and PRD, not a released financial product.
2. Every displayed dollar is virtual, pretend, nonredeemable, and never moves real money.
3. Only a parent, inside the PIN-gated Parent area, records changes; the managed child profile is read-only and has no independent account.
4. The app depends on a separately operated service and an Apple signing setup that are not part of this repository.
5. Verification so far covers local tests and builds, including synthetic signed-in UI scenarios, but not live Apple sign-in or production wallet activity.
6. Privacy, release, and community work remains, and there is currently no downloadable release.

## Claims that are supported by local evidence

These may be stated, with the qualifier that they were verified locally on a development machine:

- The repository can be cloned anonymously over HTTPS and opened with the shared `EddysWallet` scheme.
- The documented simulator test command passes (unit, transport-contract, and native UI tests, run against injected fakes and synthetic fixture data).
- Signing-independent Debug and Release simulator builds succeed.
- The signed-out welcome screen runs on iPhone and iPad simulators and states the virtual-money terms.
- The source is MIT licensed.

## Claims that must NOT be made or implied

- That the product is downloadable, released, or available to families.
- That the app is App Store-ready or production-ready (no privacy manifest, no marketing version, no signed-archive or App Store validation evidence).
- That Apple sign-in or the complete live family flow was verified end to end.
- That privacy manifest, retention, export, deletion, backups, or restore work is complete.
- That CI validates the default branch (there is no CI).
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
- [ ] A final watch-through was done specifically to catch overstated status wording (for example "released", "shipped", "production", "open for sign-ups").
