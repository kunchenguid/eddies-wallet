# App Review deterministic core

This directory contains Phase 1 of the Eddie's Wallet App Review design: pure, credential-free modules and fake-boundary tests. It does not contain a workflow, credential lookup, network transport, App Store Connect mutation, or submission path.

Run the deterministic suite locally:

```sh
python3 test/app-review-core-test.py
```

`core.py` owns these contracts:

- A self-binding, content-bound manifest for the exact iOS candidate, reviewed listing text, screenshot bytes and order, Cloud IAP review assets, and nonsecret App Review notes.
- The captain-approved reviewer path: `demoAccountRequired=false`, reviewer-owned Sign in with Apple, a reviewer-created device-local parent PIN, and Apple's review/sandbox purchase flow. Password demo-account fields are intentionally outside the schema.
- Trusted repository, default-branch, manual-dispatch, and optional captain-actor assertions for future workflows. The later mutation job must also use the captain-only `app-store-submission` protected Environment.
- An injected GET-only App Store Connect read client. The type exposes no generic request or mutation method and refuses when its read capability is missing or unauthorized.
- Exact manifest versus authoritative live read-state reconciliation, with no latest-version fallback.
- A deduplicated GitHub issue journal abstraction. It keys records by app, version, manifest binding hash, and manifest-approved commit, then restores one mutable nonsecret state comment on rerun.

Phase 2 owns real GitHub Actions workflows, concrete authenticated GET and issue boundaries, protected-Environment wiring, and any later mutation lane. Do not add a password-based reviewer account or a submission fallback here.
