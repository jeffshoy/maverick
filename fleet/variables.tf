variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "workspaces_directory_id" {
  description = "Output from the platform layer: aws_workspaces_directory.vdi.id"
  type        = string
}

variable "bundle_id" {
  description = "WorkSpaces bundle ID (AWS-managed or custom). Look up custom bundle IDs via `aws workspaces describe-workspace-bundles`."
  type        = string
}

variable "root_volume_size_gb" {
  type    = number
  default = 80
}

variable "user_volume_size_gb" {
  type    = number
  default = 50
}

variable "running_mode" {
  description = "AUTO_STOP (billed hourly, stops after idle timeout — cheaper for part-time users) or ALWAYS_ON (billed monthly)"
  type        = string
  default     = "AUTO_STOP"
}

variable "running_mode_auto_stop_timeout_minutes" {
  type    = number
  default = 60
}

# Each user gets their own WorkSpace. This map drives provisioning —
# add/remove entries here as part of your onboarding/offboarding process,
# ideally generated from an HR/ITSM trigger rather than edited by hand at scale.
variable "users" {
  description = "Map of username => AD user config for individual WorkSpace provisioning"
  type = map(object({
    user_name          = string
    root_volume_size_gb = optional(number)
    user_volume_size_gb = optional(number)
    running_mode        = optional(string)
  }))
}

variable "tags" {
  type    = map(string)
  default = {}
}
