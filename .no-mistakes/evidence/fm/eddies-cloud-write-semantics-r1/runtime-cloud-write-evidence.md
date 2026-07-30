# Runtime Cloud write evidence

Date: 2026-07-29

All identities, household names, child nicknames, amounts, StoreKit facts, and database rows used here were synthetic. No production host, Apple account, App Store resource, real family, or real financial data was touched.

## Architectural baseline

The app baseline was `d2f3aa5` (`feat: add guarded read-only Cloud wallet flow`). Its production composition already separated one-time activation from runtime authority:

- `CloudCoordinator` owned capability, StoreKit delivery, one-time import, and second-device bootstrap.
- `LocalWalletRepository` persisted Cloud ownership and accepted replica provenance.
- `WalletRepositoryFactory` reconstructed `CloudWalletRepository` after relaunch when Cloud owned the lineage.
- Kid and Parent surfaces hid a missing Cloud replica instead of presenting a fabricated zero wallet.
- Cloud-to-local continuation and Cloud-device sign-out required a successful changes refresh.
- `CloudWalletRepository` deliberately rejected every runtime mutation with `cloudRuntimeWritesUnavailable`.

The merged backend inspected for this work was `eddies-wallet-backend` `e6fc799`, which contains the runtime contract from `7f48fc5`:

- Every mutation requires a stable `Idempotency-Key`.
- A Cloud household mutation also requires `If-Match: "rev-N"`.
- Idempotent replay occurs before entitlement and revision checks.
- A successful mutation increments the household revision once.
- Money responses provide a stable entry id, accepted revision, or both across their body and ETag shapes.
- `/v1/cloud/changes?afterRevision=N` returns stable entry ids and `acceptedRevision` values.
- A stale revision returns `409 REVISION_CONFLICT` and does not mutate PostgreSQL.

The existing real-PostgreSQL backend suite passed 26 focused tests against a disposable `postgres:16-alpine` instance, including one accepted and one rejected concurrent writer, exact replay, stale revision, immutable ledger, allowance, loan, and repayment behavior.

## Small runtime design

The shipped client uses one durable unresolved-mutation slot inside the protected Cloud replica aggregate. Before transport starts it saves:

- one operation id
- the exact HTTP method, path, and JSON body
- one idempotency key
- the exact expected revision
- parent display metadata

No second mutation can start while that slot exists. A persisted replica also cannot start a mutation after launch or a failed refresh until a successful server read confirms its revision. An ambiguous network loss, timeout, malformed 2xx response, process death, or offline transition therefore cannot create a new key. Reconciliation either:

1. replays the exact request and key when its outcome is unknown, or
2. rereads changes when the server has already returned a stable entry id or accepted revision.

A money event becomes **Recorded** only after its server entry id is present in the accepted replica. When an accepted money response has no entry id, the accepted revision identifies the exact changes entry through `acceptedRevision`; amount and content are never used as identity. Profile and allowance writes use the accepted revision as their observation proof. A server-accepted write whose reread fails remains **Waiting to sync** with explicit accepted copy. A 409 or another mutation rejection that proves no idempotent commit clears the unresolved request, leaves the replica unchanged, and shows review or retry guidance. A missing or rejected authentication during reconciliation does not prove the earlier attempt failed, so the original request remains protected.

Known-offline Cloud replicas are read-only. A valid accepted replica remains visible; a device with no valid replica shows reconnect copy and no balance. Free local authority does not use this slot or the backend and remains fully usable offline.

## App client to backend to PostgreSQL proof

`CloudVerticalSliceTests.testSyntheticAppClientToBackendToPostgreSQLWrite` is an opt-in external-boundary test. The normal frontend suite skips it unless four synthetic loopback variables are supplied, because this repository does not own or start the separate service.

For this run:

1. A disposable `postgres:16-alpine` container listened only on `127.0.0.1:55435`.
2. Backend migrations ran from `eddies-wallet-backend` `e6fc799`.
3. The backend ran on `127.0.0.1:31337` with test-only local auth.
4. A synthetic parent and `Synthetic Maya` household were created.
5. Test-only SQL established Cloud authority at revision 2 and a synthetic active entitlement.
6. The iOS test used production `URLSessionTransport`, `CloudAPIClient`, `CloudWalletRepository`, and `LocalWalletRepository` against the real loopback HTTP service.
7. The app client bootstrapped, submitted a 321-cent deposit with `If-Match: "rev-2"` and idempotency key `synthetic-app-postgres-write`, then reread changes and observed the stable entry before returning Recorded.

The XCTest passed. The final PostgreSQL projection was:

```text
authority | revision | ledger entries | matching idempotency rows | balance cents
cloud     | 3        | 1              | 1                         | 321
```

The container and backend process were removed immediately after the test.

## Deterministic regression coverage

`CloudVerticalSliceTests` covers:

- successful revision-guarded writes
- response loss after the service handled the request
- timeout with the original key retained
- exact duplicate retry and server `COMMAND_IN_PROGRESS`
- concurrent identical actions with distinct intent
- 409 stale revision and unchanged replica
- accepted response with entry id
- accepted response without entry id using body revision
- accepted response using only the revision ETag
- failed post-acceptance reread
- failed local replica persistence after server acceptance
- malformed accepted response without content guessing
- accepted profile write with failed reread
- accepted allowance-rule write observed by revision
- relaunch with the durable unresolved request and no-session preservation
- persisted replica write refusal before refresh and after failed refresh
- known-offline valid replica behavior
- missing-replica reconnect behavior
- Cloud-to-local handoff refusal while unresolved
- free local setup, PIN recovery, and money writes during a Cloud outage

The shared field-level fixture remains the backend contract authority. Activation/import and runtime mutation settlement remain separate code paths.

## Parent-visible evidence

The Debug-only launch seam and `EvidenceCaptureUITests.testCloudWriteStateTour` use synthetic fixtures and assert the copy, status, controls, and absence of fabricated wallet data before capturing:

- `cloud-write-recorded-iphone.png`
- `cloud-write-recorded-kid-iphone.png`
- `cloud-write-waiting-iphone.png`
- `cloud-write-waiting-kid-iphone.png`
- `cloud-write-accepted-waiting-iphone.png`
- `cloud-write-accepted-waiting-kid-iphone.png`
- `cloud-write-rejected-iphone.png`
- `cloud-write-rejected-kid-iphone.png`
- `cloud-profile-accepted-waiting-iphone.png`
- `cloud-write-reconnect-kid-iphone.png`
- `cloud-write-reconnect-iphone.png`

The captured medium-sheet results were visually checked for complete icons, titles, status pills, wrapped copy, and reachable Done controls. The accepted profile waiting surface disables Save. Kid evidence shows only the fully observed Recorded deposit; unresolved, accepted-but-unobserved, and rejected actions never appear in kid activity or balance. The reconnect Kid and Parent surfaces show no fabricated zero wallet. The Parent surface disables profile editing, omits money controls, and does not claim that an unavailable replica is currently syncing or already usable offline.

## Final validation

- Shared Xcode scheme: 146 unit/contract tests with 1 opt-in external-boundary skip, plus 31 native UI tests, 0 failures.
- Release simulator build: succeeded with Debug scenario code excluded.
- `test/release-checks.sh`: all checks passed.
- Diff whitespace and repository text policy checks: passed.
