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
`0.1.19.json` is the generated update candidate for marketing version 0.1.19
(baseline 0.1.17), `0.1.21.json` the one for 0.1.21 (baseline 0.1.19), and
`0.1.22.json` the one for 0.1.22 (baseline 0.1.21), and `0.1.23.json` the one
for 0.1.23 (baseline 0.1.22), the first to declare `copyWrites`.
Later versions get their own generated `<version>.json` the same way: generate
the file, never hand-write it, and merge it after captain review. See `docs/app-review.md` and `tools/app-review/README.md`.

`content.listing.description` is the text of
`tools/app-review/listing/description.txt` without its final newline; the other
listing copy is the baseline manifest's. A listing field that differs from the
baseline manifest, other than What's New, must be named in `listing.copyWrites`
(`build_manifest(..., listing={"screenshotWrites": True, "copyWrites": [...]})`),
or every mutation lane refuses the manifest. The 0.1.23 manifest
declares `["description"]`; see `docs/app-review.md` "Listing copy changes".
