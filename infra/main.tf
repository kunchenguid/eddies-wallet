module "development" {
  source = "./modules/development"

  name                 = var.server_name
  location             = var.location
  server_type          = var.server_type
  image                = var.image
  ssh_key_id           = var.ssh_key_id
  ssh_admin_cidr       = var.ssh_admin_cidr
  deploy_user          = var.deploy_user
  enable_daily_backups = var.enable_daily_backups
  bootstrap_file       = abspath("${path.root}/../deploy/bootstrap.sh")
}
