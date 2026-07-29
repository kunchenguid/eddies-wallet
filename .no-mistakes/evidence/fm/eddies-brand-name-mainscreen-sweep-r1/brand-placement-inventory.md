# Brand placement inventory (eddies-brand-name-mainscreen-sweep-r1)

Contract owner: [`docs/product-requirements.md`](../../../../docs/product-requirements.md). This inventory records the sweep against that naming contract.

## Keep (external / install / legal identity)

| Surface | Occurrence | Why keep |
| --- | --- | --- |
| Welcome wordmark | `ProductBrand.displayName` in `WelcomeView` | One intentional onboarding brand mention |
| Install display name | `INFOPLIST_KEY_CFBundleDisplayName = "Eddie's Wallet"` | App Store / home-screen identity |
| Bundle / package IDs | `com.kunchenguid.eddieswallet`, target/folder `EddysWallet` | Identifiers, not UI chrome |
| Production host | `eddieswallet.kunchenguid.com` | External URL |
| Public docs / legal | README, SUPPORT, SECURITY, LICENSE, release-please header | Marketing and legal brand |
| Design skill provenance | `.agents/skills/eddies-wallet-design/**` | Unmaintained visual reference, not runtime UI |

## Change (this sweep)

| Surface | Before | After |
| --- | --- | --- |
| Kid home header | `ChildProfileCopy.walletTitle` -> `"{name}'s wallet"` | `"{name}'s Wallet"` title-case personal header; neutral `Your wallet` |
| Welcome brand string | Hardcoded `"Eddie's Wallet"` | `ProductBrand.displayName` only |
| Copy ownership docs | Thin naming note | PRD + AGENTS distinguish external brand vs everyday chrome |
| Debug scenarios | Fixture nickname only | Optional `EW_UITEST_NICKNAME` override (blank => nil/neutral) |
| Tests | Maya path partial | Unit + UI proofs for Maya, neutral, Eddie personal, welcome brand |

## Classify, do not blindly replace

| Occurrence | Classification |
| --- | --- |
| Fixture / preview nickname `"Eddie"` in `WalletSnapshot.fixture`, Debug empty snapshot, unit stubs | Synthetic personal data, not brand chrome |
| UI strings derived via `ChildProfileCopy.*(nickname:)` when nickname is Eddie (`Hi, Eddie`, `Eddie's Wallet`, `Done. Back to Eddie's wallet`) | Personal data for a child named Eddie - required to keep working |
| Parent area title `Parent area`, settings rows, activity empty states | Already family-centric; no brand string |
| Kid empty state `Your wallet is ready!` | Already neutral |

## Proof cases

1. Nickname **Maya** -> kid `Maya's Wallet` / `Hi, Maya`; parent `Maya's virtual balance` / `Show Maya's wallet`; no static `Eddie's Wallet` on those mains.
2. Nickname nil/blank -> `Your wallet`, `Your child's virtual balance`, `your child's wallet`.
3. Nickname **Eddie** -> personal headers still render (overlap with brand string is personal data).
4. Welcome (signed out) -> `Eddie's Wallet` wordmark remains.
