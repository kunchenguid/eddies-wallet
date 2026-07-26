variable "server_name" {
  description = "The single dedicated development server name."
  type        = string
  default     = "eddies-wallet-dev"

  validation {
    condition     = var.server_name == "eddies-wallet-dev"
    error_message = "This foundation intentionally manages only eddies-wallet-dev."
  }
}

variable "location" {
  description = "Hetzner location for the development server."
  type        = string
  default     = "hel1"

  validation {
    condition     = var.location == "hel1"
    error_message = "The development foundation is intentionally limited to hel1."
  }
}

variable "server_type" {
  description = "Smallest suitable 4 GB / 2 shared CPU development server type."
  type        = string
  default     = "cx23"

  validation {
    condition     = var.server_type == "cx23"
    error_message = "Use cx23 for this low-cost development foundation."
  }
}

variable "image" {
  description = "Supported Ubuntu LTS image name."
  type        = string
  default     = "ubuntu-24.04"

  validation {
    condition     = var.image == "ubuntu-24.04"
    error_message = "Use Ubuntu 24.04 LTS for this foundation."
  }
}

variable "ssh_key_id" {
  description = "Existing Kun MacHome Hetzner SSH key ID. No key is created by this configuration."
  type        = number
  default     = 111428521

  validation {
    condition     = var.ssh_key_id == 111428521
    error_message = "Only the existing Kun MacHome key (ID 111428521) may be attached."
  }
}

variable "ssh_admin_cidr" {
  description = "Current operator IPv4 CIDR allowed to reach SSH, for example 203.0.113.10/32."
  type        = string

  validation {
    condition     = can(cidrhost(var.ssh_admin_cidr, 0)) && strcontains(var.ssh_admin_cidr, "/")
    error_message = "Provide the current operator address as an explicit CIDR."
  }
}

variable "deploy_user" {
  description = "Non-root host user used for Compose deployments."
  type        = string
  default     = "eddies"

  validation {
    condition     = var.deploy_user == "eddies"
    error_message = "The bootstrap contract expects the eddies deployment user."
  }
}

variable "enable_daily_backups" {
  description = "Enable the provider's daily server backup option."
  type        = bool
  default     = true

  validation {
    condition     = var.enable_daily_backups
    error_message = "Daily backups are required by the MVP recovery posture."
  }
}
