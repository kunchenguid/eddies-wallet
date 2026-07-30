# Cloud sign-out crash and hand-off validation

This change was exercised against the end-user lifecycle represented by the
Cloud wallet tests: signing out of Cloud preserves the local wallet, and a
late Cloud read does not replace the wallet with an error or an empty snapshot.

## Focused simulator run

Command:

```text
xcodebuild test -project EddysWallet.xcodeproj -scheme EddysWallet \
  -destination 'platform=iOS Simulator,id=F73EB8AB-B180-47C5-BEFA-D52597401FFD' \
  -only-testing:EddysWalletTests/CloudVerticalSliceTests/testCloudSignOutStopsSyncingWithoutDeletingTheWallet \
  -only-testing:EddysWalletTests/CloudVerticalSliceTests/testACloudReadSupersededByTheSignOutNeverShowsTheParentAnError \
  -only-testing:EddysWalletTests/APIRepositoryTests/testInflightChildRefreshCannotRestoreClearedKidShell \
  -only-testing:EddysWalletTests/APIRepositoryTests/testInflightCommandSuccessCannotRestoreStateAfterSessionClear \
  -only-testing:EddysWalletTests/APIRepositoryTests/testInflightCommandNetworkFailureCannotRequeueAfterSessionClear \
  -only-testing:EddysWalletTests/APIRepositoryTests/testInflightCommandRejectionCannotRestoreStateAfterSessionClear \
  -only-testing:EddysWalletTests/APIRepositoryTests/testPendingFlushCrossingSessionClearCannotReplayUnderNewSession
```

Result: the two Cloud lifecycle tests and five API session-clear tests passed
on the EW-CI-Repro iPhone 17 Pro simulator running iOS 26.4. The new
regression test checks that the parent sees no error or expired session, that
the accepted balance remains 750 cents, and that local authority is retained.

## Thread Sanitizer run

The original flaky Cloud sign-out test, the five proven API race tests, and the
new superseded-read regression were rerun with `-enableThreadSanitizer YES`.
The final xcresult summary reports:

```text
result: Passed
passedTests: 7
failedTests: 0
skippedTests: 0
testFailures: []
topInsights: []
```

The final non-TSan xcresult reports the same seven focused selectors with no
failures. No sanitizer diagnostics were reported.

No UI screenshot is included because this change affects transient wallet
repository lifecycle state and test transport synchronization, not a visual
layout or copy surface. UI tests were not run locally under the operator's
explicit constraint and remain CI coverage.
