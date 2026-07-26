output "server_id" {
  description = "Hetzner ID of the single development server."
  value       = module.development.server_id
}

output "server_name" {
  description = "Development server name."
  value       = module.development.server_name
}

output "server_ipv4" {
  description = "Development server public IPv4."
  value       = module.development.server_ipv4
  sensitive   = true
}

output "server_ipv6" {
  description = "Development server public IPv6 prefix."
  value       = module.development.server_ipv6
  sensitive   = true
}

output "firewall_id" {
  description = "Dedicated provider firewall ID."
  value       = module.development.firewall_id
}

output "attached_ssh_key" {
  description = "The existing SSH key attached to the server."
  value       = module.development.attached_ssh_key
}

output "backups_enabled" {
  description = "Whether Hetzner daily server backups are enabled."
  value       = module.development.backups_enabled
}

output "host_bootstrap_sha256" {
  description = "Hash of the bootstrap asset rendered into server user_data."
  value       = module.development.host_bootstrap_sha256
}
