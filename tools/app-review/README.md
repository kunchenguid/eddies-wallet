# App Review pipeline

Eddie's Wallet submits one captain-approved App Store version through three
manual submission workflows. A fourth manual workflow,
`app-review-eula-append.yml`, is a one-shot Guideline 3.1.2 description PATCH
and is not part of that submission gate. The scheduled review-status monitor is
the shared `app-review-submit` GET-only tool, documented in
`docs/app-store-review-monitor.md`. Apple mutation is the same shared
Node engine, pinned in `app-review-submit.yml`; this Python tree no longer owns
a submit path. `docs/app-review.md` is the operating guide - the gate, the order
of dispatches, and the hands-off bar. This file owns the module boundaries.

Run the deterministic suites locally:

```sh
python3 test/app-review-core-test.py
python3 test/app-review-pipeline-test.py
python3 test/app-review-lanes-test.py
python3 test/app-review-eula-append-test.py
python3 test/app-review-screenshot-preflight-test.py
python3 test/observe-review-status-test.py
node test/app-review-assemble-test.js
node test/app-review-full-submit-test.js
node test/app-review-upload-test.js
```

None of them reads a credential, contacts a network endpoint, or touches App
Store Connect. `test/release-checks.sh` runs these suites.

## Modules

| Module | Owns |
| --- | --- |
| `core.py` | The credential-free deterministic core: manifest schema and self-binding hashes, reviewed-content hashing, trusted-context assertions, the GET-only App Store Connect client type, exact manifest-versus-live reconciliation, and the durable GitHub issue journal. It has no environment, credential, network, or mutation path. |
| `runtime.py` | The dispatch gate every Python entrypoint applies first: trusted repository, default branch, manual dispatch, the double-confirm version, the manifest-approved commit the workflow pinned, and loading the approved manifest. |
| `content.py` | The two byte-level bindings: recomputing every approved image's bytes from the pinned commit, and normalizing live App Store Connect state into the exact document shape `core` reconciles. |
| `asc_read.py` | The GET-only App Store Connect boundary - credential loading, JWT signing, URL safety, pagination. It can construct no other method. |
| `github_api.py` | The durable issue-record boundary on `GITHUB_TOKEN`. The post-acceptance monitor-variable handoff is in the Node engine, injected only on the gated submit job. |
| `evidence.py` | Bounded nonsecret reviewer-path readiness evidence: built by the preflight, re-bound and freshness-checked by verify, assemble, upload, and submit. |
| `prepare.py`, `demo_preflight.py`, `verify.py` | The Python workflow entrypoints. Verify is credential-free. |
| `screenshot_preflight.py` | Eddie-side listing-screenshot validation before any live write: required display types, RGB8 dimensions, unique bytes per size, and checksums matching the captain-approved manifest. |
| `list_app_store_versions.py` | GET-only iOS App Store version listing. |
| `list_app_info_categories.py` | GET-only App Info primary and secondary category listing. |
| `probe_review_item_shape.py` | GET-only include/filter matrix against live reviewSubmissionItems, printing relationship names and linkage types. Dispatched through `app-review-diagnose.yml`. |
| `assemble_only.js` | Eddie's assemble-only adapter onto `kunchenguid/app-review-submit`. It maps the captain-approved Eddie manifest, demo-preflight evidence, and Cloud product ids onto `runSubmission({ assembleOnly: true })`, then refuses any result other than `status: assembled` / `submitted: false` (`remaining: upload-screenshots` when `listing.screenshotWrites` is on). It hard-refuses `--submit`. |
| `full_submit.js` | Eddie's gated full-submit adapter. It requires `--submit`, refuses assemble-only flags, maps onto `runSubmission({ assembleOnly: false })`, injects `MonitorVariableClient` from `APP_REVIEW_MONITOR_VARIABLE_TOKEN`, and refuses any result that is not `submitted` or `already_submitted`. |
| `upload_screenshots.js` | Eddie's screenshot-upload adapter. It requires `--upload-screenshots`, refuses `--submit` and assemble-only flags, requires `SCREENSHOT_UPLOAD_ENGINE_ARGV` to be `["node","app_review_pipeline.js","upload-screenshots"]`, and maps onto `runSubmission({ uploadScreenshots: true })`. |
| `append_standard_eula.py` | One-shot Guideline 3.1.2 remediation: GET the 0.1.17 en-US description, append Apple's standard EULA line if absent, PATCH only that field, GET to verify. It does not import a Python write boundary. |

## Mutation boundary

The vendored Python submit engine (`submit.py`, `submission.py`, `asc_write.py`)
is retired. Apple mutation uses the pinned shared Node engine through the three
adapters documented above. `append_standard_eula.py` remains a separate,
one-shot description PATCH.

`docs/app-review.md` is authoritative for the engine pin, dispatch order,
credential lanes, hands-off classification, listing policy, and operations that
must never occur. `test/app-review-lanes-test.py` pins those workflow boundaries.
