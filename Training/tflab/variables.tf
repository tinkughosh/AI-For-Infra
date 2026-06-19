variable "participant_name" {
  description = "Your participant name (lowercase, no spaces)"
  type        = string
}

variable "location" {
  description = "Azure region"
  type        = string
  default     = "eastus"
}

variable "admin_password" {
  description = "Admin password for all VMs"
  type        = string
  sensitive   = true
}

variable "deploy_bastion" {
  description = "Set to true during lab sessions to deploy Bastion; false to destroy it and stop billing ($0.19/hr + $0.005/hr public IP)"
  type        = bool
  default     = false
}
