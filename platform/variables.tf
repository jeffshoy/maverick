variable "aws_region" {
  description = "AWS region to deploy WorkSpaces platform into"
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Environment tag (e.g. prod, staging)"
  type        = string
  default     = "prod"
}

variable "project_name" {
  description = "Prefix used for naming all resources"
  type        = string
  default     = "vdi"
}

# --- Networking ---

variable "vpc_cidr" {
  description = "CIDR block for the dedicated VDI VPC"
  type        = string
  default     = "10.50.0.0/16"
}

variable "workspaces_subnet_cidrs" {
  description = "CIDR blocks for WorkSpaces subnets, one per AZ (minimum 2 required by AWS)"
  type        = list(string)
  default     = ["10.50.1.0/24", "10.50.2.0/24"]
}

variable "availability_zones" {
  description = "AZs to spread WorkSpaces subnets across. Must match length of workspaces_subnet_cidrs."
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b"]
}

variable "allowed_client_cidrs" {
  description = "Source CIDRs allowed to connect to WorkSpaces (office IPs, VPN CIDR). Used in the IP Access Control Group."
  type        = list(string)
}

variable "onprem_ad_cidr" {
  description = "CIDR of on-prem network reachable via VPN/Direct Connect, for AD Connector DNS/LDAP/Kerberos egress. Leave null if using AWS Managed Microsoft AD instead."
  type        = string
  default     = null
}

# --- Directory Service ---

variable "directory_type" {
  description = "Either 'ad_connector' (federate to existing on-prem AD) or 'managed_ad' (AWS Managed Microsoft AD)"
  type        = string
  default     = "managed_ad"

  validation {
    condition     = contains(["ad_connector", "managed_ad"], var.directory_type)
    error_message = "directory_type must be either 'ad_connector' or 'managed_ad'."
  }
}

variable "directory_name" {
  description = "Fully qualified domain name for the directory (e.g. corp.example.com)"
  type        = string
}

variable "directory_short_name" {
  description = "NetBIOS short name for the directory"
  type        = string
  default     = null
}

variable "directory_edition" {
  description = "Edition for AWS Managed Microsoft AD: 'Standard' or 'Enterprise'"
  type        = string
  default     = "Standard"
}

# Only used when directory_type = "ad_connector"
variable "onprem_dns_ips" {
  description = "On-prem DNS server IPs for AD Connector (required if directory_type = ad_connector)"
  type        = list(string)
  default     = []
}

variable "connect_ad_service_account_username" {
  description = "Service account username for AD Connector to bind to on-prem AD (required if directory_type = ad_connector)"
  type        = string
  default     = null
}

# --- Secrets ---
# Directory admin/service-account passwords are pulled from Secrets Manager, never hardcoded.

variable "directory_admin_password_secret_arn" {
  description = "Secrets Manager ARN holding the directory admin (or AD Connector service account) password"
  type        = string
}

# --- WorkSpaces Directory Settings ---

variable "self_service_permissions" {
  description = "Which self-service actions end users can perform on their own WorkSpace"
  type = object({
    restart_workspace    = optional(bool, true)
    increase_volume      = optional(bool, false)
    change_compute_type  = optional(bool, false)
    switch_running_mode  = optional(bool, true)
    rebuild_workspace    = optional(bool, true)
  })
  default = {}
}

variable "enable_internet_access" {
  description = "Whether WorkSpaces get a default internet gateway route. Recommended false for enterprises routing egress through an inspected NAT/proxy."
  type        = bool
  default     = false
}

variable "enable_maintenance_mode" {
  description = "Whether AWS-managed maintenance window (OS patch/update) is enabled for the directory"
  type        = bool
  default     = true
}

variable "tags" {
  description = "Common tags applied to all resources"
  type        = map(string)
  default     = {}
}
