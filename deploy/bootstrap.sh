#!/usr/bin/env bash
# Bootstrap a fresh Ubuntu LTS host for Eddie's Wallet.
# Run as root from Hetzner user-data or an attended root shell.
set -Eeuo pipefail

SSH_ADMIN_CIDR="${SSH_ADMIN_CIDR:?Set SSH_ADMIN_CIDR to the operator address before bootstrapping}"
DEPLOY_USER="${DEPLOY_USER:-eddies}"
export DEBIAN_FRONTEND=noninteractive

if [[ "$(id -u)" -ne 0 ]]; then
  echo "bootstrap must run as root" >&2
  exit 1
fi

apt-get update
apt-get -y upgrade
apt-get install -y --no-install-recommends \
  age \
  ca-certificates \
  curl \
  docker-compose-v2 \
  docker.io \
  fail2ban \
  sudo \
  unattended-upgrades \
  ufw

# Hold the distribution-provided Docker engine and Compose plugin so a routine
# security update cannot silently change the container runtime contract.
apt-mark hold docker.io docker-compose-v2
systemctl enable --now docker

if ! id -u "$DEPLOY_USER" >/dev/null 2>&1; then
  useradd --create-home --shell /bin/bash "$DEPLOY_USER"
fi
usermod -aG docker "$DEPLOY_USER"
cat >/etc/sudoers.d/eddies-wallet <<EOF
$DEPLOY_USER ALL=(root) NOPASSWD: /usr/bin/install, /usr/bin/systemctl start eddies-wallet-backup.timer
EOF
chmod 0440 /etc/sudoers.d/eddies-wallet
visudo -cf /etc/sudoers.d/eddies-wallet
install -d -m 0700 -o "$DEPLOY_USER" -g "$DEPLOY_USER" "/home/$DEPLOY_USER/.ssh"
if [[ -s /root/.ssh/authorized_keys ]]; then
  install -m 0600 -o "$DEPLOY_USER" -g "$DEPLOY_USER" /root/.ssh/authorized_keys "/home/$DEPLOY_USER/.ssh/authorized_keys"
else
  echo "No root authorized_keys were found; refusing to disable root SSH" >&2
  exit 1
fi

install -d -m 0750 -o root -g "$DEPLOY_USER" /etc/eddies-wallet
cat >/etc/eddies-wallet/backup.env.example <<'EOF'
# Copy to /etc/eddies-wallet/backup.env with mode 0600 on the host.
# The destination must be an independent HTTPS endpoint that accepts PUT.
# Do not use a local path or a same-host URL as an off-site backup.
# BACKUP_DESTINATION=https://backup.example.invalid/eddies-wallet
# BACKUP_AGE_RECIPIENT=age1replace-this-with-a-real-recipient
# COMPOSE_DIR=/opt/eddies-wallet/deploy
EOF
chmod 0640 /etc/eddies-wallet/backup.env.example

cat >/etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF

cat >/etc/fail2ban/jail.d/eddies-wallet-sshd.local <<'EOF'
[sshd]
enabled = true
backend = systemd
bantime = 1h
findtime = 10m
maxretry = 5
EOF
systemctl enable --now fail2ban

# The provider firewall is the primary boundary. UFW provides a second,
# host-local boundary in case the provider rule is ever changed accidentally.
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow from "$SSH_ADMIN_CIDR" to any port 22 proto tcp comment 'operator SSH only'
ufw allow 80/tcp comment 'future HTTP reverse proxy'
ufw allow 443/tcp comment 'future HTTPS reverse proxy'
ufw --force enable

install -d -m 0755 /etc/ssh/sshd_config.d
cat >/etc/ssh/sshd_config.d/eddies-wallet-hardening.conf <<EOF
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
PubkeyAuthentication yes
AuthenticationMethods publickey
PermitRootLogin no
AllowUsers $DEPLOY_USER
X11Forwarding no
AllowAgentForwarding no
EOF
sshd -t
systemctl reload ssh

# Leave the deployment project stopped. The repository deployment assets are
# copied here separately after this bootstrap has completed.
install -d -m 0755 -o "$DEPLOY_USER" -g "$DEPLOY_USER" /opt/eddies-wallet/deploy
cat >/etc/systemd/system/eddies-wallet-backup.service <<'EOF'
[Unit]
Description=Nightly encrypted Eddie's Wallet database export
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
User=root
ExecStart=/opt/eddies-wallet/deploy/nightly-encrypted-export.sh
EOF
cat >/etc/systemd/system/eddies-wallet-backup.timer <<'EOF'
[Unit]
Description=Run the Eddie's Wallet encrypted export nightly

[Timer]
OnCalendar=*-*-* 02:30:00 UTC
Persistent=true
RandomizedDelaySec=15m

[Install]
WantedBy=timers.target
EOF
systemctl daemon-reload
systemctl enable eddies-wallet-backup.timer

printf 'Bootstrap complete. Deploy assets to /opt/eddies-wallet/deploy and configure /etc/eddies-wallet/backup.env before starting the backup timer.\n'
