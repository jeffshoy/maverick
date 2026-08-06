aws_region   = "us-east-1"
environment  = "dev"
project_name = "ami-hardening"

default_tags = {
  Project     = "ami-hardening-pipeline"
  ManagedBy   = "terraform"
  Environment = "dev"
  Owner       = "security-team"
}

vpc_id            = null # leave null to auto-create a dedicated build VPC (see build_vpc_cidr below)
subnet_id         = null # leave null to auto-create a dedicated build VPC
security_group_id = null # leave null to auto-create a default egress-only build SG
kms_key_arn       = null # leave null to use default SSE-S3/EBS encryption

build_vpc_cidr          = "10.99.0.0/24"
build_subnet_cidr       = "10.99.0.0/26"
build_availability_zone = "us-east-1a"

rhel9_ami_id_override      = "" # leave empty to auto-resolve latest Marketplace RHEL 9 AMI
ubuntu2204_ami_id_override = "" # leave empty to auto-resolve latest Canonical Ubuntu Pro server AMI

windows_build_instance_types = ["t3.large"]
linux_build_instance_types   = ["t3.medium"]

distribution_regions = [] # empty = same region as the build only

windows2019_schedule_expression = null # null = manual trigger only
windows2022_schedule_expression = null
rhel9_schedule_expression       = null
ubuntu2204_schedule_expression  = null
