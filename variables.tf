variable "aws_region" {
  description = "AWS region for the demo"
  type        = string
  default     = "eu-central-1"
}

variable "project_name" {
  description = "Short project name, used as a prefix for all resources"
  type        = string
  default     = "secrets-demo"
}

variable "environment" {
  description = "Environment name (dev/staging/prod) - used to namespace secrets"
  type        = string
  default     = "dev"
}

variable "instance_type" {
  description = "EC2 instance type for the tiny test instance"
  type        = string
  default     = "t3.micro"
}

variable "operator_cidr" {
  description = "Your IP in CIDR form, e.g. 203.0.113.10/32 - SSH is only allowed from here"
  type        = string
  # intentionally no default: force the operator to set it explicitly
}

variable "operator_ssh_public_key" {
  description = "Public key (OpenSSH format) used to SSH into the instance as the operator - not a secret, safe to store in state"
  type        = string
}

# --- Secret inputs: NEVER give these real defaults, NEVER commit real values ---

variable "external_api_key" {
  description = "Value of the external API key to store in Secrets Manager"
  type        = string
  sensitive   = true
}

variable "ssh_deploy_private_key" {
  description = "Contents of the SSH deploy private key (PEM) to store in Secrets Manager"
  type        = string
  sensitive   = true
}