data "hcloud_ssh_key" "kun_machome" {
  id = var.ssh_key_id
}

resource "hcloud_firewall" "development" {
  name = "eddies-wallet-dev-firewall"

  # SSH is restricted to the current operator CIDR. HTTP and HTTPS remain
  # open for the future reverse-proxy boundary. No database ingress rule exists.
  rule {
    direction   = "in"
    protocol    = "tcp"
    port        = "22"
    source_ips  = [var.ssh_admin_cidr]
    description = "SSH from current operator only"
  }

  rule {
    direction   = "in"
    protocol    = "tcp"
    port        = "80"
    source_ips  = ["0.0.0.0/0", "::/0"]
    description = "Future HTTP reverse proxy"
  }

  rule {
    direction   = "in"
    protocol    = "tcp"
    port        = "443"
    source_ips  = ["0.0.0.0/0", "::/0"]
    description = "Future HTTPS reverse proxy"
  }

  # Keep package updates, image pulls, DNS, and time synchronization working.
  rule {
    direction       = "out"
    protocol        = "tcp"
    port            = "1-65535"
    destination_ips = ["0.0.0.0/0", "::/0"]
    description     = "Outbound TCP"
  }

  rule {
    direction       = "out"
    protocol        = "udp"
    port            = "1-65535"
    destination_ips = ["0.0.0.0/0", "::/0"]
    description     = "Outbound UDP"
  }

  rule {
    direction       = "out"
    protocol        = "icmp"
    destination_ips = ["0.0.0.0/0", "::/0"]
    description     = "Outbound ICMP"
  }
}

resource "hcloud_server" "development" {
  name         = var.name
  server_type  = var.server_type
  image        = var.image
  location     = var.location
  ssh_keys     = [data.hcloud_ssh_key.kun_machome.id]
  backups      = var.enable_daily_backups
  firewall_ids = [hcloud_firewall.development.id]
  user_data    = <<-USERDATA
    #!/usr/bin/env bash
    export SSH_ADMIN_CIDR='${var.ssh_admin_cidr}'
    export DEPLOY_USER='${var.deploy_user}'
    ${file(var.bootstrap_file)}
  USERDATA

  labels = {
    application = "eddies-wallet"
    environment = "development"
    managed_by  = "opentofu"
  }
}
