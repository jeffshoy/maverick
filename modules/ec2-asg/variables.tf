variable "instance_type" {
  type = string
}

variable "subnet_ids" {
  type = list(string)
}

variable "security_group_ids" {
  type = list(string)
}

variable "key_name" {
  type = string
  default = null
}
