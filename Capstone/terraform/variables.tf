variable "participant_name" {
  description = "Your participant name (lowercase, no spaces) — used in resource names"
  type        = string
}

variable "location" {
  description = "Azure region to deploy all resources"
  type        = string
  default     = "eastus"
}

variable "admin_password" {
  description = "Admin password for both VMs — set via TF_VAR_admin_password environment variable, do not hardcode here"
  type        = string
  sensitive   = true
}
