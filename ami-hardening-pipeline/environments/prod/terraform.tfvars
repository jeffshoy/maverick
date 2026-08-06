aws_region   = "us-east-1"
environment  = "prod"
project_name = "ami-hardening"

default_tags = {
  Project     = "ami-hardening-pipeline"
  ManagedBy   = "terraform"
  Environment = "prod"
  Owner       = "security-team"
}

vpc_id            = null # leave null to auto-create a dedicated build VPC
subnet_id         = null
security_group_id = null
kms_key_arn       = null

build_vpc_cidr          = "10.99.1.0/24"
build_subnet_cidr       = "10.99.1.0/26"
build_availability_zone = "us-east-1a"

rhel9_ami_id_override      = ""
ubuntu2204_ami_id_override = ""

windows_build_instance_types = ["t3.large"]
linux_build_instance_types   = ["t3.medium"]

distribution_regions = []

# prod rebuilds monthly to pick up new CVE fixes from upstream package updates.
# cron(minute hour day month weekday) — 03:00 UTC on the 1st of each month, staggered
# by a few minutes per OS so all 4 don't start their build instances simultaneously.
windows2019_schedule_expression = "cron(0 3 1 * ? *)"
windows2022_schedule_expression = "cron(5 3 1 * ? *)"
rhel9_schedule_expression       = "cron(10 3 1 * ? *)"
ubuntu2204_schedule_expression  = "cron(15 3 1 * ? *)"
