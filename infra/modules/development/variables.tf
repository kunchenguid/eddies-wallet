variable "name" {
  type = string
}

variable "location" {
  type = string
}

variable "server_type" {
  type = string
}

variable "image" {
  type = string
}

variable "ssh_key_id" {
  type = number
}

variable "ssh_admin_cidr" {
  type = string
}

variable "deploy_user" {
  type = string
}

variable "enable_daily_backups" {
  type = bool
}

variable "bootstrap_file" {
  description = "Absolute path to the tracked host bootstrap script."
  type        = string

  validation {
    condition     = fileexists(var.bootstrap_file)
    error_message = "The tracked host bootstrap file must exist before apply."
  }
}
