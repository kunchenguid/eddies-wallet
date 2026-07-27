# Project agent memory

This public repository is the frontend and product home for Eddie's Wallet. Keep client behavior aligned with the product requirements in `docs/product-requirements.md`, especially the virtual-money language, parent/child permissions, and offline states. The root `README.md` is the public landing page; keep its status, setup, and limitation claims truthful for an unfinished, unreleased MVP.

The app's service implementation and operations are maintained separately. Keep this repository frontend-only: do not add backend source, migrations, credentials, deployment assets, or infrastructure configuration here.

Brand and interface guidance lives in the project skill at `.agents/skills/eddies-wallet-design/SKILL.md`; load it before changing visuals, copy, or assets. `.claude/skills` is a tracked relative symlink to `.agents/skills`, so keep skill directory names matching their `name:` frontmatter and keep file names exact-cased for case-sensitive checkouts.

## Maintaining this file

Keep this file for knowledge useful to almost every future agent session in this project.
Do not repeat what the codebase already shows; point to the authoritative file or command instead.
Prefer rewriting or pruning existing entries over appending new ones.
When updating this file, preserve this bar for all agents and keep entries concise.
