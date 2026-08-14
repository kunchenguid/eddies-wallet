# Captain-approved App Review manifests

One file per App Store marketing version, named exactly `<version>.json`, for
example `0.2.0.json`. Merging that file on `main` after captain review **is** the
content half of the submission gate: `app-review-prepare.yml`,
`app-review-demo-preflight.yml`, and `app-review-submit.yml` all detach to the
commit that last changed it, and refuse any candidate it does not pin.

A manifest is generated, never hand-written. `tools/app-review/core.py` owns its
schema and its two self-checks - a content hash over every reviewed string and
image descriptor, and a binding hash over the whole document - so an edited field
invalidates the file rather than quietly changing what gets submitted.

`0.1.17.json` is the first captain-approved manifest, now present on `main`.
Later versions get their own generated `<version>.json` the same way: generate
the file, never hand-write it, and merge it after captain review. See
`docs/app-review.md` and `tools/app-review/README.md`.
