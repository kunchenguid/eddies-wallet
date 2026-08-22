# App Review pipeline

Eddie's Wallet submits one captain-approved App Store version through three
manual submission workflows. A fourth manual workflow,
`app-review-eula-append.yml`, is a one-shot Guideline 3.1.2 description PATCH
and is not part of that submission gate. The scheduled review-status monitor is
the shared `app-review-submit` GET-only tool, documented in
`docs/app-store-review-monitor.md`. Apple mutation is the same shared
Node engine, pinned in `app-review-submit.yml`; this Python tree no longer owns
a submit path. `docs/app-review.md` is the operating guide - the gate, the order
of dispatches, and what stays attended. This file owns the module boundaries.

Run the deterministic suites locally:

```sh
python3 test/app-review-core-test.py
python3 test/app-review-pipeline-test.py
python3 test/app-review-lanes-test.py
python3 test/app-review-eula-append-test.py
python3 test/observe-review-status-test.py
node test/app-review-assemble-test.js
node test/app-review-full-submit-test.js
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
| `evidence.py` | Bounded nonsecret reviewer-path readiness evidence: built by the preflight, re-bound and freshness-checked by verify, assemble, and submit. |
| `prepare.py`, `demo_preflight.py`, `verify.py` | The Python workflow entrypoints. Verify is credential-free. |
| `list_app_store_versions.py` | GET-only iOS App Store version listing. |
| `list_app_info_categories.py` | GET-only App Info primary and secondary category listing. |
| `assemble_only.js` | Eddie's assemble-only adapter onto `kunchenguid/app-review-submit`. It maps the captain-approved Eddie manifest, demo-preflight evidence, and Cloud product ids onto `runSubmission({ assembleOnly: true })`, then refuses any result other than `status: assembled` / `submitted: false`. It hard-refuses `--submit`. |
| `full_submit.js` | Eddie's gated full-submit adapter. It requires `--submit`, refuses assemble-only flags, maps onto `runSubmission({ assembleOnly: false })`, injects `MonitorVariableClient` from `APP_REVIEW_MONITOR_VARIABLE_TOKEN`, and refuses any result that is not `submitted` or `already_submitted`. |
| `append_standard_eula.py` | One-shot Guideline 3.1.2 remediation: GET the 0.1.17 en-US description, append Apple's standard EULA line if absent, PATCH only that field, GET to verify. It does not import a Python write boundary. |

## The mutation lane

The vendored Python submit engine (`submit.py`, `submission.py`, `asc_write.py`)
is retired. Apple mutation is the pinned shared Node engine. The
workflow checks out `kunchenguid/app-review-submit@62bfbc3b` into
`.app-review-submit`. Assemble runs
`node tools/app-review/assemble_only.js --assemble-only --first-release`.
That adapter always sets `assembleOnly: true` and `firstRelease: true` for
the 0.1.17 first App Store version, with `baselineVersion` null, and never
calls the pipeline `submit` command. Engine #12 writes App Info categories from
`config.protected` (EDUCATION, no secondary) during assemble even when
`listingPolicy` is `observe`. Gated `mode=submit` runs
`node tools/app-review/full_submit.js --submit --first-release`, which calls
`runSubmission({ assembleOnly: false })` and injects the monitor-variable
client so Apple-accept cannot split from `APP_REVIEW_MONITOR_VERSION` handoff.
`config.reviewDetails.demoAccountRequired` is JSON `false`: Eddie uses
reviewer-owned Sign in with Apple and a sandbox Cloud purchase, never a
password demo account. `test/app-review-lanes-test.py`,
`test/app-review-assemble-test.js`, and `test/app-review-full-submit-test.js`
prove the lanes.

A separate one-shot write, `append_standard_eula.py` via
`app-review-eula-append.yml`, sends its own description PATCH.
`listingPolicy` stays `observe`.

## What this pipeline deliberately does not do

- It never creates listing copy, screenshots, in-app purchase records, or the
  App Store version itself. Those are attended App Store Connect work. First-release
  assemble writes review contact, notes, and `demoAccountRequired: false` from
  `config.reviewDetails` because there is no live baseline to copy; it still
  never invents a password demo account.
- It never uses a protected GitHub Environment. The gate is the captain-approved
  manifest merged on `main` plus the captain's double-confirm dispatch.
- It never adds a password-based reviewer account or a demo credential. The
  reviewer signs in with their own Apple Account and buys a Cloud plan through
  Apple's review or sandbox flow, so those fields are outside the schema.
- It never releases. The manifest may only choose `MANUAL` or `AFTER_APPROVAL`.
- Assemble-only never asks the engine to submit. Full submit is a separate
  captain-gated `mode=submit` dispatch, default remains `verify`, and Eddie
  never invokes the shared pipeline submit subcommand.
