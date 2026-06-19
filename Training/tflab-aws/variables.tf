variable "participant_name" {
  description = "Your participant name (lowercase, no spaces) — used in resource names and S3 bucket"
  type        = string
}

variable "region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "availability_zone" {
  description = "AWS Availability Zone for all subnets (must be within the selected region)"
  type        = string
  default     = "us-east-1a"
}

variable "ssh_public_key" {
  description = "SSH public key material for the EC2 key pair (contents of ~/.ssh/id_rsa.pub or similar). Replaces admin_password from the Azure config."
  type        = string
}
