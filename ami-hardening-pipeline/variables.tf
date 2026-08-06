variable "aws_region" {
  description = "Primary AWS region"
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Environment name (dev, staging, prod)"
  type        = string
}

variable "project_name" {
  description = "Project name used for resource naming and prefixes"
  type        = string
}

variable "default_tags" {
  description = "Default tags applied to all resources via the provider"
  type        = map(string)
  default     = {}
}

# ── Network ────────────────────────────────────────────────────────────────────
# Leave vpc_id/subnet_id null to have this project create its own minimal,
# dedicated build VPC (single public subnet, no NAT — build instances are
# ephemeral and only need outbound internet). Set both to use an existing VPC
# instead.

variable "vpc_id" {
  description = "Existing VPC ID that Image Builder build instances launch into. Leave null to create a dedicated build VPC."
  type        = string
  default     = null
}

variable "subnet_id" {
  description = "Existing subnet ID that Image Builder build instances launch into. Leave null to create a dedicated build VPC."
  type        = string
  default     = null
}

variable "build_vpc_cidr" {
  description = "CIDR block for the auto-created build VPC (only used when vpc_id/subnet_id are null)"
  type        = string
  default     = "10.99.0.0/24"
}

variable "build_subnet_cidr" {
  description = "CIDR block for the auto-created build subnet (only used when vpc_id/subnet_id are null)"
  type        = string
  default     = "10.99.0.0/26"
}

variable "build_availability_zone" {
  description = "Availability zone for the auto-created build subnet (only used when vpc_id/subnet_id are null)"
  type        = string
  default     = "us-east-1a"
}

variable "security_group_id" {
  description = "Security group ID for build instances. Leave null to auto-create a default egress-only build SG."
  type        = string
  default     = null
}

# ── Encryption / logging ──────────────────────────────────────────────────────

variable "kms_key_arn" {
  description = "KMS key ARN for AMI and logs bucket encryption. Leave null to use default SSE-S3/EBS encryption."
  type        = string
  default     = null
}

# ── Image Builder AMI overrides ───────────────────────────────────────────────

variable "rhel9_ami_id_override" {
  description = "RHEL 9 parent AMI ID. Leave empty to auto-resolve the latest Marketplace RHEL 9 AMI."
  type        = string
  default     = ""
}

variable "ubuntu2204_ami_id_override" {
  description = "Ubuntu 22.04 Pro parent AMI ID. Leave empty to auto-resolve the latest Canonical Ubuntu Pro server AMI."
  type        = string
  default     = ""
}

# ── Build instance sizing ─────────────────────────────────────────────────────

variable "windows_build_instance_types" {
  description = "Instance types for Windows Image Builder build instances"
  type        = list(string)
  default     = ["t3.large"]
}

variable "linux_build_instance_types" {
  description = "Instance types for Linux Image Builder build instances"
  type        = list(string)
  default     = ["t3.medium"]
}

# ── Distribution ──────────────────────────────────────────────────────────────

variable "distribution_regions" {
  description = "Additional regions to distribute produced AMIs to. Empty list = same region as the build only."
  type        = list(string)
  default     = []
}

# ── Schedules (null = manual trigger only, no automatic recurring builds) ────

variable "windows2019_schedule_expression" {
  description = "Cron expression for scheduled Windows 2019 pipeline builds. Null = manual trigger only."
  type        = string
  default     = null
}

variable "windows2022_schedule_expression" {
  description = "Cron expression for scheduled Windows 2022 pipeline builds. Null = manual trigger only."
  type        = string
  default     = null
}

variable "rhel9_schedule_expression" {
  description = "Cron expression for scheduled RHEL 9 pipeline builds. Null = manual trigger only."
  type        = string
  default     = null
}

variable "ubuntu2204_schedule_expression" {
  description = "Cron expression for scheduled Ubuntu 22.04 pipeline builds. Null = manual trigger only."
  type        = string
  default     = null
}
