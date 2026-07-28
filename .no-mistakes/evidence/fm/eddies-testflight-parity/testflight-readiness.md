# TestFlight readiness evidence

Validated locally on Xcode 26.4 against target commit
`dba9c8385c9d3b38879de259f0fd8dd56d3b766f`. No Apple credentials, signing,
upload, release PR, tag, or GitHub Release were used.

## Release archive

A generic iOS device archive completed successfully with code signing disabled,
using the same version overrides the TestFlight workflow supplies for a rerun
of `eddies-wallet-v0.1.0`:

```text
MARKETING_VERSION=0.1
CURRENT_PROJECT_VERSION=12.2
** ARCHIVE SUCCEEDED **
```

Direct inspection of the archived app produced:

```text
archive_status=created
bundle_id=com.kunchenguid.eddieswallet
marketing_version=0.1
build_number=12.2
uses_non_exempt_encryption=false
EddysWallet: Mach-O 64-bit executable arm64
```

This demonstrates that the Release device product carries the bundle identity,
numeric marketing/build versions, encryption declaration, and device
architecture expected by App Store Connect before signing and upload.

## Parent elevation backgrounding

The focused UI test exercised the changed lifecycle path on iPhone 17 Pro with
iOS 26.4:

```text
Entered "Parent area"
Pressed Home
Observed application state != runningForeground
Reactivated Eddie's Wallet
Found "Hi, Eddie"
Confirmed "Parent area" absent
Confirmed "Add deposit" absent
testBackgroundingDropsParentElevation passed
```

This is a lifecycle behavior rather than a visual-layout change, so the
interaction trace is the useful evidence. A still screenshot would not show
that parent elevation was dropped specifically because the app backgrounded.

## Credential-free release contract

`bash test/release-checks.sh` passed its targeted, network-free contract checks:

- all four workflows parse as YAML and pin actions to full commit SHAs;
- pull-request CI has read-only contents permission and references no secrets;
- the credential-bearing release workflow has no branch or pull-request entry
  point and checks out the exact release tag;
- upload construction ends at `altool --upload-app` and includes no review or
  publication path;
- the Apple team ID is absent from committed export/project configuration and
  is injected from `vars.APPLE_TEAM_ID`;
- release-please version lineage, zero-patch trimming, deterministic retry
  identity, and invalid-tag rejection all match the committed contract.

The actual signed export, App Store Connect upload, and processing-status query
remain intentionally blocked on the documented Apple-side prerequisites.
