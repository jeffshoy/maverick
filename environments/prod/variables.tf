variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "environment" {
  type    = string
  default = "prod"
}

variable "project_name" {
  type = string
}

variable "default_tags" {
  type    = map(string)
  default = {}
}

variable "vpc_id" {
  type    = string
  default = null
}

variable "subnet_id" {
  type    = string
  default = null
}

variable "security_group_id" {
  type    = string
  default = null
}

variable "build_vpc_cidr" {
  type    = string
  default = "10.99.1.0/24"
}

variable "build_subnet_cidr" {
  type    = string
  default = "10.99.1.0/26"
}

variable "build_availability_zone" {
  type    = string
  default = "us-east-1a"
}

variable "kms_key_arn" {
  type    = string
  default = null
}

variable "rhel9_ami_id_override" {
  type    = string
  default = ""
}

variable "ubuntu2204_ami_id_override" {
  type    = string
  default = ""
}

variable "windows_build_instance_types" {
  type    = list(string)
  default = ["t3.large"]
}

variable "linux_build_instance_types" {
  type    = list(string)
  default = ["t3.medium"]
}

variable "distribution_regions" {
  type    = list(string)
  default = []
}

variable "windows2019_schedule_expression" {
  type    = string
  default = null
}

variable "windows2022_schedule_expression" {
  type    = string
  default = null
}

variable "rhel9_schedule_expression" {
  type    = string
  default = null
}

variable "ubuntu2204_schedule_expression" {
  type    = string
  default = null
}
