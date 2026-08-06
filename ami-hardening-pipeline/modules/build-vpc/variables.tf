variable "project_name" {
  description = "Project name used in resource naming"
  type        = string
}

variable "environment" {
  description = "Environment name (dev, staging, prod)"
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block for the build VPC"
  type        = string
}

variable "subnet_cidr" {
  description = "CIDR block for the single build subnet"
  type        = string
}

variable "availability_zone" {
  description = "Availability zone for the build subnet"
  type        = string
}
