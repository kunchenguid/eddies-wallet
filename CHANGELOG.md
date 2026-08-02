# Changelog

## [0.1.8](https://github.com/kunchenguid/eddies-wallet/compare/eddies-wallet-v0.1.7...eddies-wallet-v0.1.8) (2026-08-02)


### Bug Fixes

* **EddysWallet:** discover and recover existing wallets on fresh devices ([#41](https://github.com/kunchenguid/eddies-wallet/issues/41)) ([d787df8](https://github.com/kunchenguid/eddies-wallet/commit/d787df87b9ade8685379339bf374ec714b0e9938))

## [0.1.7](https://github.com/kunchenguid/eddies-wallet/compare/eddies-wallet-v0.1.6...eddies-wallet-v0.1.7) (2026-08-01)


### Bug Fixes

* **EddysWallet:** make Cloud restore recovery truthful ([#39](https://github.com/kunchenguid/eddies-wallet/issues/39)) ([ea8ed33](https://github.com/kunchenguid/eddies-wallet/commit/ea8ed3337afda666867c48c9aaed0ec57f4bdd04))

## [0.1.6](https://github.com/kunchenguid/eddies-wallet/compare/eddies-wallet-v0.1.5...eddies-wallet-v0.1.6) (2026-07-31)


### Bug Fixes

* **EddysWallet:** recover StoreKit false-negative purchases ([#37](https://github.com/kunchenguid/eddies-wallet/issues/37)) ([287d1bc](https://github.com/kunchenguid/eddies-wallet/commit/287d1bccdcc74641c763e7f502d0def360d1128f))

## [0.1.5](https://github.com/kunchenguid/eddies-wallet/compare/eddies-wallet-v0.1.4...eddies-wallet-v0.1.5) (2026-07-31)


### Features

* **EddysWallet:** add session-aware Cloud capability reads ([#33](https://github.com/kunchenguid/eddies-wallet/issues/33)) ([3ac50e6](https://github.com/kunchenguid/eddies-wallet/commit/3ac50e67789af0b50fda5c72e4aefcba0909b960))


### Bug Fixes

* **EddysWallet:** preserve wallet after superseded Cloud reads ([#35](https://github.com/kunchenguid/eddies-wallet/issues/35)) ([84672a1](https://github.com/kunchenguid/eddies-wallet/commit/84672a1a4e174608323310d67e0cd96815afcab1))

## [0.1.4](https://github.com/kunchenguid/eddies-wallet/compare/eddies-wallet-v0.1.3...eddies-wallet-v0.1.4) (2026-07-30)


### Features

* add guarded read-only Cloud wallet flow ([#29](https://github.com/kunchenguid/eddies-wallet/issues/29)) ([d2f3aa5](https://github.com/kunchenguid/eddies-wallet/commit/d2f3aa58232d453e68e47551d57a668e9b683c9c))
* add protected local wallets and guarded Cloud foundation ([#25](https://github.com/kunchenguid/eddies-wallet/issues/25)) ([ad6382b](https://github.com/kunchenguid/eddies-wallet/commit/ad6382b81d9ca7ad7873b6bfcc8868f12350be14))
* add safe Cloud runtime writes ([#30](https://github.com/kunchenguid/eddies-wallet/issues/30)) ([2b71191](https://github.com/kunchenguid/eddies-wallet/commit/2b71191fbc9775db98bb86cb887d47ecb57f9733))

## [0.1.3](https://github.com/kunchenguid/eddies-wallet/compare/eddies-wallet-v0.1.2...eddies-wallet-v0.1.3) (2026-07-29)


### Bug Fixes

* polish Parent PIN gate and Parent area ([#23](https://github.com/kunchenguid/eddies-wallet/issues/23)) ([e2ec2b6](https://github.com/kunchenguid/eddies-wallet/commit/e2ec2b68b548d1a63fdce3099cec300ba7da43bd))

## [0.1.2](https://github.com/kunchenguid/eddies-wallet/compare/eddies-wallet-v0.1.1...eddies-wallet-v0.1.2) (2026-07-29)


### Bug Fixes

* omit lessons-era fields from family setup ([#19](https://github.com/kunchenguid/eddies-wallet/issues/19)) ([7cd3e72](https://github.com/kunchenguid/eddies-wallet/commit/7cd3e723a51a3851b33e22a211fb275ebede3f3b))
* personalize daily wallet chrome ([#22](https://github.com/kunchenguid/eddies-wallet/issues/22)) ([7969143](https://github.com/kunchenguid/eddies-wallet/commit/7969143e5fc772b734bd428dd1662b9cfcd813aa))
* tailor wallet copy to kid and parent audiences ([#20](https://github.com/kunchenguid/eddies-wallet/issues/20)) ([7c24fa1](https://github.com/kunchenguid/eddies-wallet/commit/7c24fa152224a641ffdc76068f887c6c69ce89d9))

## [0.1.1](https://github.com/kunchenguid/eddies-wallet/compare/eddies-wallet-v0.1.0...eddies-wallet-v0.1.1) (2026-07-28)


### Features

* add parent nickname editing and remove lessons ([#18](https://github.com/kunchenguid/eddies-wallet/issues/18)) ([4aa3cb7](https://github.com/kunchenguid/eddies-wallet/commit/4aa3cb7a8cee664735a60f5fce88a157dd241b28))


### Bug Fixes

* make release checks lineage-aware ([#16](https://github.com/kunchenguid/eddies-wallet/issues/16)) ([1d76bbe](https://github.com/kunchenguid/eddies-wallet/commit/1d76bbed48c9f9b8c6e285d5ceeb2b212c8de537))

## 0.1.0 (2026-07-28)


### Features

* add captain-gated TestFlight release pipeline ([#13](https://github.com/kunchenguid/eddies-wallet/issues/13)) ([1784b97](https://github.com/kunchenguid/eddies-wallet/commit/1784b97545aa1b5115dc79346628fe0b41a54673))
* add native Eddie's Wallet iOS app ([#4](https://github.com/kunchenguid/eddies-wallet/issues/4)) ([f4ee8f6](https://github.com/kunchenguid/eddies-wallet/commit/f4ee8f6ad0c8cb54f0ca763edc1482e3bbe1fd28))
* make the wallet kid-first with gated parent access ([#12](https://github.com/kunchenguid/eddies-wallet/issues/12)) ([128cd6d](https://github.com/kunchenguid/eddies-wallet/commit/128cd6df7326aef7967b3ae291a88ec695423d10))
* package design system as a project skill ([#11](https://github.com/kunchenguid/eddies-wallet/issues/11)) ([25d4ef1](https://github.com/kunchenguid/eddies-wallet/commit/25d4ef1b771095f0adf4a30f895334f5619b638f))


### Bug Fixes

* set initial TestFlight release to 0.1.0 ([#15](https://github.com/kunchenguid/eddies-wallet/issues/15)) ([f831c91](https://github.com/kunchenguid/eddies-wallet/commit/f831c91b985f3e090ab85b96588f1a11e017cc3e))
