aws_region   = "us-east-1"
environment  = "dev"
project_name = "ami-hardening"

default_tags = {
  Project     = "ami-hardening-pipeline"
  ManagedBy   = "terraform"
  Environment = "dev"
  Owner       = "security-team"
}

vpc_id            = null # leave null to auto-create a dedicated build VPC
subnet_id         = null
security_group_id = null
kms_key_arn       = null

build_vpc_cidr          = "10.99.0.0/24"
build_subnet_cidr       = "10.99.0.0/26"
build_availability_zone = "us-east-1a"

rhel9_ami_id_override      = ""
ubuntu2204_ami_id_override = ""
ubuntu2404_ami_id_override = ""

windows_build_instance_types = ["t3.large"]
linux_build_instance_types   = ["t3.medium"]

distribution_regions = []

# dev builds are manual-trigger only, no recurring schedule
windows2019_schedule_expression = null
windows2022_schedule_expression = null
rhel9_schedule_expression       = null
ubuntu2204_schedule_expression  = null
ubuntu2404_schedule_expression  = null
