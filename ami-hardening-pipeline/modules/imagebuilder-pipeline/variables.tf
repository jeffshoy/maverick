variable "project_name" {
  description = "Project name used in resource naming"
  type        = string
}

variable "environment" {
  description = "Environment name (dev, staging, prod)"
  type        = string
}

variable "pipeline_name" {
  description = "Short OS identifier used in resource naming, e.g. \"windows2022\", \"rhel9\""
  type        = string
}

variable "platform" {
  description = "Image Builder platform for this recipe/component set"
  type        = string
  validation {
    condition     = contains(["Windows", "Linux"], var.platform)
    error_message = "platform must be \"Windows\" or \"Linux\"."
  }
}

variable "parent_image_id" {
  description = "AMI ID to use as the recipe's parent (base) image"
  type        = string
}

variable "root_device_name" {
  description = "Root device name of the parent image (e.g. /dev/sda1 for Windows, /dev/xvda for most Linux) — read from the AMI, never hardcode"
  type        = string
}

variable "component_documents" {
  description = "List of custom CIS-hardening components to create and attach to the recipe, in run order"
  type = list(object({
    name     = string
    version  = string
    document = string
  }))
}

variable "additional_component_arns" {
  description = "ARNs of existing (e.g. AWS-managed) components to append after the custom components"
  type        = list(string)
  default     = []
}

variable "instance_types" {
  description = "Instance types Image Builder may use for the build/test instance"
  type        = list(string)
  default     = ["t3.medium"]
}

variable "instance_profile_name" {
  description = "IAM instance profile name for the infrastructure configuration (from imagebuilder-core module)"
  type        = string
}

variable "subnet_id" {
  description = "Subnet ID the build instance launches into"
  type        = string
}

variable "security_group_ids" {
  description = "Security group IDs attached to the build instance"
  type        = list(string)
}

variable "logs_bucket_name" {
  description = "S3 bucket name where Image Builder writes its own build logs"
  type        = string
}

variable "ami_name_prefix" {
  description = "Name prefix for produced AMIs, e.g. \"myproject-prod-rhel9-cis\""
  type        = string
}

variable "distribution_regions" {
  description = "Additional regions to distribute produced AMIs to. Empty list = same region as the build only."
  type        = list(string)
  default     = []
}

variable "kms_key_arn" {
  description = "KMS key ARN for AMI re-encryption on distribution. Null = default EBS encryption key."
  type        = string
  default     = null
}

variable "schedule_expression" {
  description = "Cron expression for recurring builds. Null = manual trigger only, no schedule block."
  type        = string
  default     = null
}

variable "root_volume_size_gb" {
  description = "Root EBS volume size in GB for the produced AMI"
  type        = number
  default     = 30
}

variable "recipe_version" {
  description = "Semantic version for the image recipe. Bump on any recipe change — recipes are immutable per version."
  type        = string
  default     = "1.0.0"
}
