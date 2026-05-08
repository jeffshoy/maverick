variable "aws_region" {
  type = string
  default = "us-east-1"
}

variable "instance_type" {
  type = string
  default = "t3.micro"
}

variable "subnet_ids" {
  type = list(string)
  description = "List of subnet IDs for the ASG"
}

variable "security_group_ids" {
  type = list(string)
  description = "List of security group IDs for the instances"
}

variable "key_name" {
  type = string
  default = null
}

variable "cluster_name" {
  type = string
  default = "enterprise-eks"
}

variable "environment" {
  type = string
  default = "dev"
}

variable "bucket_name" {
  type = string
  default = "enterprise-s3-bucket"
}

variable "vpc_cidr" {
  type = string
  default = "10.0.0.0/16"
}
