variable "project_name" {
  description = "Project name used in resource naming"
  type        = string
}

variable "environment" {
  description = "Environment name (dev, staging, prod)"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID to deploy the default build security group into"
  type        = string
}

variable "security_group_id" {
  description = "Existing security group ID for build instances. Leave null to auto-create a default egress-only build SG."
  type        = string
  default     = null
}

variable "kms_key_arn" {
  description = "KMS key ARN for the logs bucket. Leave null to use default SSE-S3 encryption."
  type        = string
  default     = null
}
