# Eddie's Wallet deployment foundation

This directory is the vendor-neutral deployment contract for the first
low-cost development host. The host is intentionally empty of product code
until a backend image is selected and reviewed.

## Files

- `bootstrap.sh` hardens a fresh Ubuntu LTS host, creates the non-root
  `eddies` deployment user, enables unattended security updates, installs a
  held Ubuntu Docker engine and Compose v2, and restricts host ingress.
- `compose.yaml` is the single project boundary: Caddy is the only service
  with HTTP/HTTPS ports, the backend is internal to the Compose networks, and
  Postgres has no host port.
- `Caddyfile` is a domain placeholder. Set `SITE_ADDRESS` only after a domain,
  DNS, and explicit TLS/email decisions exist. This repository does not create
  DNS records or certificates.
- `.env.example` documents required names. Copy it to the host as `.env`,
  replace every placeholder there, and never commit `.env`.
- `deploy.sh`, `migrate.sh`, `rollback.sh`, and `healthcheck.sh` are the
  operator commands. All server addresses and commands are invocation-time
  values, not tracked configuration.
- `nightly-encrypted-export.sh` is installed behind a systemd timer. It pipes a
  database dump through gzip and age to an independent HTTPS PUT destination.

## First host setup

1. Provision a fresh Ubuntu LTS host with only the intended SSH public key and
   the dedicated provider firewall. Pass the current operator CIDR to
   `bootstrap.sh`; do not use a broad SSH rule as a convenience.
2. The bootstrap creates the `eddies` user and disables root/password SSH. The
   deployment key is copied from the initial root `authorized_keys` file, so no
   new private key is generated.
3. Copy this directory with `REMOTE_HOST` set in the invoking shell. Create the
   host-only `deploy/.env` from `.env.example`, using an immutable backend image
   reference and real database credentials only on the host.
4. Set `MIGRATION_COMMAND=node dist/src/db/migrate.js` to the backend
   image's reviewed migration command and run `migrate.sh` before `deploy.sh`
   starts the Compose project.
5. Set `HEALTHCHECK_URL` to the later domain's health endpoint and run
   `healthcheck.sh` after deployment.

Example command shapes, with placeholders intentionally left unresolved:

```sh
REMOTE_HOST='<server-address>' REMOTE_USER=eddies ./deploy/deploy.sh
REMOTE_HOST='<server-address>' MIGRATION_COMMAND='node dist/src/db/migrate.js' ./deploy/migrate.sh
HEALTHCHECK_URL='https://<domain>/healthz' ./deploy/healthcheck.sh
REMOTE_HOST='<server-address>' ROLLBACK_BACKEND_IMAGE='<old-immutable-image>' ./deploy/rollback.sh
```

## Recovery boundary

The nightly timer must not be considered configured until
`/etc/eddies-wallet/backup.env` exists with mode `0600`,
`BACKUP_DESTINATION` points to an independent HTTPS destination, and
`BACKUP_AGE_RECIPIENT` is a real age recipient. If any of those prerequisites
are absent, the job exits with a visible `STOPPED` message and does not create
a same-disk dump. No object storage, backup account, DNS, TLS certificate, or
third-party service is provisioned by this repository.
