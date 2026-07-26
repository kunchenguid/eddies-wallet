# Eddie's Wallet backend

This directory contains the first authoritative backend vertical slice for Eddie's Wallet. It is a small Node.js/TypeScript API backed by PostgreSQL. The balance is virtual bookkeeping only: US-dollar vocabulary is used for display, but no real money, payment provider, bank, card, or redemption path exists.

## Local setup

Requirements: Node.js 20+, Docker, and Docker Compose.

```sh
cd backend
cp .env.example .env
npm install
npm run lint
npm run test:unit

docker compose up -d postgres
npm run migrate
DATABASE_URL=postgresql://postgres@localhost:5433/eddys_wallet npm run test:integration

# Run the API outside Docker in local-auth mode:
set -a; . ./.env; set +a
npm run dev
```

The Compose database uses PostgreSQL's `trust` mode and contains no useful credentials. It is for a disposable local database only. Do not use that setting for deployment. The Compose API can also be started with `docker compose up --build`.

The production image defaults to `PORT=8080` and exposes `8080`, matching `deploy/compose.yaml` and Caddy's `reverse_proxy backend:8080`. The local Compose service explicitly overrides `PORT=3000` and maps `3000:3000`, so local development remains on port 3000. The production migration command is `node dist/src/db/migrate.js`, matching the compiled image layout and `deploy/.env.example`.

`npm test` runs the unit tests and skips the PostgreSQL integration suite when `DATABASE_URL` is unset. The integration command above is the strongest local check: it runs migrations and exercises the HTTP API, PostgreSQL transactions, database triggers, authorization ownership, and idempotency. Tests create only local-auth identities and need no Apple or production credentials.

## Configuration and authentication

Configuration is environment-driven:

- `DATABASE_URL` - PostgreSQL connection string.
- `PORT` - HTTP port, default `3000`.
- `NODE_ENV` - `production` rejects local authentication.
- `AUTH_MODE` - `apple` (default) or `local` for development and tests only.
- `APPLE_AUDIENCES` - comma-separated Apple client IDs, required in Apple mode.
- `APPLE_NONCE_REQUIRED` - defaults to `true`; keep nonce checking enabled for the Sign in with Apple flow.
- `SESSION_TTL_DAYS` - opaque API session lifetime, default `30`.

In Apple mode, `POST /v1/auth/apple` verifies the supplied identity token with Apple's published JWKS at `https://appleid.apple.com/auth/keys`. Verification requires the Apple issuer, configured audience, signature, and token time claims. The request nonce is checked against the token nonce by `jose`; the API requires a nonce by default. The server stores only the Apple subject and optional email, never the identity token.

For local development only:

```sh
curl -s http://localhost:3000/v1/auth/local \
  -H 'content-type: application/json' \
  -d '{"subject":"local-parent"}'
```

The response contains an opaque bearer session. `/v1/auth/local` returns 404 in Apple mode, and startup fails if `AUTH_MODE=local` is combined with `NODE_ENV=production`. No Apple secret or private key is needed by this service.

## API contract

All protected endpoints require `Authorization: Bearer <session>`. The server derives the parent identity from the session and checks family ownership from the database. There is no client-controlled role flag. The child view is a deliberately read-only response shape, not a child credential or an authorization grant.

All mutating commands require a unique `Idempotency-Key` header. A retry with the same key and the same canonical request returns the original status and body. Reusing a key with a different request returns `409 IDEMPOTENCY_KEY_REUSED`. Failed commands roll back their idempotency record and may be retried.

Money fields are integer `amountCents` values. The service converts them to `bigint` before arithmetic and PostgreSQL stores them as `bigint`; fractional amounts, zero, negative amounts, and values above the safe API limit are rejected. JSON responses use numbers because the service caps values below JavaScript's safe JSON integer range.

### Health and sessions

| Method | Path | Auth | Purpose |
| --- | --- | --- | --- |
| GET | `/healthz` | No | Database-backed health check |
| POST | `/v1/auth/apple` | No | Verify Apple identity token and create parent session |
| POST | `/v1/auth/local` | No, local mode only | Development-only parent session |
| GET | `/v1/me` | Yes | Parent identity and setup summary |

Apple request: `{ "identityToken": "...", "nonce": "..." }`.

### Setup and reads

| Method | Path | Idempotency | Purpose |
| --- | --- | --- | --- |
| POST | `/v1/family/setup` | Required | Create the one family, Eddie profile, and wallet |
| PATCH | `/v1/family` | Required | Rename the family |
| PATCH | `/v1/child/profile` | Required | Update nickname, optional avatar URL, or lesson age-band label |
| GET | `/v1/family` | No | Parent setup and wallet snapshot |
| GET | `/v1/wallet` | No | Wallet snapshot with recent activity, rule, and latest loan |
| GET | `/v1/child-view` | No | Child-safe, read-only wallet snapshot |
| GET | `/v1/activity?limit=50` | No | Accepted activity, newest first; limit 1-100 |
| GET | `/v1/activity/:entryId` | No | Accepted activity details |
| GET | `/v1/loans/:loanId` | No | Loan and its accepted loan/repayment entries |

Every money detail includes the persistent notice: `Virtual practice only. These dollars are pretend, cannot be redeemed, and never move real money.`

### Parent commands

| Method | Path | Body | Purpose |
| --- | --- | --- | --- |
| PUT | `/v1/allowance-rule` | `{ amountCents, cadence: "weekly", weekday: 0-6, startDate, endDate? }` | Create or replace the one active weekly rule |
| GET | `/v1/allowance-rule` | - | Read the rule and next scheduled occurrence |
| POST | `/v1/allowance-rule/:ruleId/occurrences/:occurrenceId/record` | `{ reason? }` | Parent-confirm and record one due occurrence |
| POST | `/v1/wallet/deposits` | `{ amountCents, reason? }` | Record a positive deposit |
| POST | `/v1/wallet/withdrawals` | `{ amountCents, reason? }` | Record a withdrawal if the accepted balance is sufficient |
| POST | `/v1/loans` | `{ principalCents, purpose?, dueDate? }` | Create one interest-free open loan and credit the wallet |
| POST | `/v1/loans/:loanId/repayments` | `{ amountCents, reason? }` | Record a partial or full repayment |

Accepted ledger entries cannot be edited or deleted. The only correction shape is a new parent-recorded compensating event. Withdrawals and repayments are checked inside a transaction against a row-locked wallet. Repayment is also checked against a row-locked outstanding principal. Loan creation is limited to one open loan. Allowance replacement cancels only future scheduled occurrences; recorded history remains unchanged.

## Data model and migrations

Migrations are append-only SQL files in `migrations/` and are applied by `npm run migrate` under a PostgreSQL advisory lock. The core tables are:

- `parent_identities` and `sessions` for Apple/local subject identity and opaque sessions.
- `families`, `children`, and `wallets` for the one-owner, one-child MVP.
- `ledger_entries` for accepted immutable events with before/after balances and server actor/timestamp fields.
- `allowance_rules` and `allowance_occurrences` for one weekly parent-confirmed rule.
- `loans` and `repayments` for one interest-free open loan at a time and its immutable repayment records.
- `idempotency_records` for replay-safe command responses.

Database triggers reject ledger updates/deletes, verify that a new ledger entry starts at the current wallet balance, and reject direct wallet balance changes unless the service has created the corresponding accepted ledger entry in the same transaction. Application queries never accept client timestamps, actors, or balances.

## Deliberately narrow choices and remaining decisions

This slice does not silently implement unresolved product policy:

- Allowances are weekly only, parent-confirmed, and do not run a background scheduler or catch up missed dates. A scheduled occurrence is distinct from a recorded event.
- The `lessonAgeBand` is an opaque required label, so product can choose exact bands later without a backend migration.
- The API has one parent owner and one Eddie profile. There is no child login, Google auth, co-parent membership, PIN protocol, child request flow, interest, multiple wallet, payments, analytics, or administration surface.
- Offline queueing is an eventual client concern. The API accepts only authoritative commands and never labels an unaccepted command as recorded.
- Backup scheduling, encrypted export, retention/deletion policy, PIN recovery, iOS support versions, and the final Hetzner operations plan remain launch decisions. This repository does not claim those operational controls are configured.
