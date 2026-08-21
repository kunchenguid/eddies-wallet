# App Review pipeline

Eddie's Wallet submits one captain-approved App Store version through three
manual workflows. The scheduled review-status monitor is the shared
`app-review-submit` GET-only tool, documented in
`docs/app-store-review-monitor.md`; this Python engine does not own that poll.
`docs/app-review.md` is the operating guide - the gate, the order of dispatches,
and what stays attended. This file owns the module boundaries.

Run the deterministic suites locally:

```sh
python3 test/app-review-core-test.py
python3 test/app-review-pipeline-test.py
python3 test/app-review-lanes-test.py
python3 test/observe-review-status-test.py
```

None of them reads a credential, contacts a network endpoint, or touches App
Store Connect. `test/release-checks.sh` runs all three.

## Modules

| Module | Owns |
| --- | --- |
| `core.py` | The credential-free deterministic core: manifest schema and self-binding hashes, reviewed-content hashing, trusted-context assertions, the GET-only App Store Connect client type, exact manifest-versus-live reconciliation, and the durable GitHub issue journal. It has no environment, credential, network, or mutation path. |
| `runtime.py` | The dispatch gate every entrypoint applies first: trusted repository, default branch, manual dispatch, the double-confirm version, the manifest-approved commit the workflow pinned, and loading the approved manifest. |
| `content.py` | The two byte-level bindings: recomputing every approved image's bytes from the pinned commit, and normalizing live App Store Connect state into the exact document shape `core` reconciles. |
| `asc_read.py` | The GET-only App Store Connect boundary - credential loading, JWT signing, URL safety, pagination. It can construct no other method. |
| `asc_write.py` | The single mutation-capable boundary. POST and PATCH only, one method per exact resource change, no DELETE and no upload. |
| `github_api.py` | The durable issue-record boundary on `GITHUB_TOKEN`, and the `EDDIES_REVIEW_MONITOR_CYCLE` handoff on its own least-privilege token. |
| `evidence.py` | Bounded nonsecret reviewer-path readiness evidence: built by the preflight, re-bound and freshness-checked by submission. |
| `submission.py` | The idempotent submission engine: align to the manifest, reconcile authoritatively, resume or create one review submission, submit, read Apple back. |
| `prepare.py`, `demo_preflight.py`, `submit.py` | The workflow entrypoints. |

## The mutation lane

`asc_write.py` is imported only by `submission.py`, and `submission.py` is
imported only inside `submit.py`'s `submit` mode. `prepare.py` and
`demo_preflight.py` therefore cannot load a mutation capability at all, and
`test/app-review-lanes-test.py` proves it by importing them in a fresh
interpreter and inspecting the loaded modules. The workflow half of the same
boundary - which job's step may map which secret - is proven against a parsed
model of the workflows in the same suite.

## What this pipeline deliberately does not do

- It never creates listing copy, screenshots, in-app purchase records, App
  Review contact details, or the App Store version itself. Those are attended
  App Store Connect work; the engine can only observe them and refuse.
- It never uses a protected GitHub Environment. The gate is the captain-approved
  manifest merged on `main` plus the captain's double-confirm dispatch.
- It never adds a password-based reviewer account or a demo credential. The
  reviewer signs in with their own Apple Account and buys a Cloud plan through
  Apple's review or sandbox flow, so those fields are outside the schema.
- It never releases. The manifest may only choose `MANUAL` or `AFTER_APPROVAL`.
