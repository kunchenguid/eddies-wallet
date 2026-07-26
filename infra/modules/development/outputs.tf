output "server_id" {
  value = hcloud_server.development.id
}

output "server_name" {
  value = hcloud_server.development.name
}

output "server_ipv4" {
  value = hcloud_server.development.ipv4_address
}

output "server_ipv6" {
  value = hcloud_server.development.ipv6_address
}

output "firewall_id" {
  value = hcloud_firewall.development.id
}

output "attached_ssh_key" {
  value = {
    id          = data.hcloud_ssh_key.kun_machome.id
    name        = data.hcloud_ssh_key.kun_machome.name
    fingerprint = data.hcloud_ssh_key.kun_machome.fingerprint
  }
}

output "backups_enabled" {
  value = hcloud_server.development.backups
}

output "host_bootstrap_sha256" {
  value = filesha256(var.bootstrap_file)
}
