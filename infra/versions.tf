terraform {
  required_version = ">= 1.8.0, < 2.0.0"

  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = "= 1.66.1"
    }
  }

  # Local state is intentionally ignored by Git. Set TF_DATA_DIR or use the
  # default infra/.terraform directory for provider/plugin working data.
  backend "local" {
    path = "terraform.tfstate"
  }
}

# The provider reads HCLOUD_TOKEN from the environment. Never put the token in
# variables, tfvars, state, plans, or tracked files.
provider "hcloud" {}
