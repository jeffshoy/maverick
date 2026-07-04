variable "key_vault_name" { type = string }
variable "location" { type = string }
variable "resource_group_name" { type = string }
variable "purge_protection_enabled" {
  type    = bool
  default = true
}
variable "tags" { type = map(string) }
