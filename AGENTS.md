# Project agent memory

This file is the project's committed home for project-intrinsic agent knowledge: build, test, release, architecture, and sharp-edge notes that should travel with the code.

- Add durable project-specific notes here as they are discovered through real work.
- OpenTofu infrastructure is the source of truth under `infra/`; host and Compose deployment assets are under `deploy/`. Use the attended commands in those directories and keep state, plans, and host-only environment files untracked.

## Maintaining this file

Keep this file for knowledge useful to almost every future agent session in this project.
Do not repeat what the codebase already shows; point to the authoritative file or command instead.
Prefer rewriting or pruning existing entries over appending new ones.
When updating this file, preserve this bar for all agents and keep entries concise.

- The backend vertical slice lives under `backend/`; use `backend/README.md` for local PostgreSQL, migration, API, and test commands.
