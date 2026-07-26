# OpenTofu infrastructure

OpenTofu is the source of truth for the one development host. The module
creates exactly one `eddies-wallet-dev` server in `hel1`, a dedicated firewall,
provider daily backups, and the tracked host bootstrap as Hetzner user data.
It attaches only the existing `Kun MacHome` key ID `111428521` and does not
create keys, volumes, DNS records, certificates, or third-party services.

The provider is pinned exactly in `versions.tf`; commit
`.terraform.lock.hcl` after `tofu init` so provider checksums are reviewable.
The local state, plans, plugin directory, tfvars, and crash logs are ignored
and must never be committed.

## Safe workflow

Set the current operator address in the invoking shell. The value below is an
example placeholder, not a tracked address:

```sh
export TF_VAR_ssh_admin_cidr='<current-operator-ip>/32'
```

Initialize without a Hetzner credential:

```sh
tofu -chdir=infra init
```

Plan and apply only through the attended Automic contract. The token is read
from `HCLOUD_TOKEN` by the provider and is not a command argument:

```sh
av inject +HCLOUD_TOKEN -- tofu -chdir=infra plan -out=eddies-wallet-dev.tfplan
av inject +HCLOUD_TOKEN -- tofu -chdir=infra apply eddies-wallet-dev.tfplan
```

The plan file and local state are ignored. Review the plan before apply and
confirm it contains only one new server and one new firewall. Do not use the
existing `umami` or `myfirstmate` resources as a target and do not run apply
with a different SSH key, location, server type, or backup setting.

After apply, retrieve sensitive addresses from local state/output as needed:

```sh
tofu -chdir=infra output -raw server_ipv4
tofu -chdir=infra output -raw server_ipv6
```

The separate `deploy/` directory contains the Compose boundary, migration,
deployment, rollback, health check, and encrypted export job shape. The host
bootstrap installs Docker and Compose from Ubuntu packages and holds those
runtime packages against unattended version changes. It also enables SSH
key-only access for the non-root `eddies` user and host-level automatic
security updates.
