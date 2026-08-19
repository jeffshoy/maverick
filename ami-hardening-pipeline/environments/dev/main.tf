module "ami_hardening_pipeline" {
  source = "../../"

  aws_region   = var.aws_region
  environment  = var.environment
  project_name = var.project_name

  vpc_id            = var.vpc_id
  subnet_id         = var.subnet_id
  security_group_id = var.security_group_id
  kms_key_arn       = var.kms_key_arn

  build_vpc_cidr          = var.build_vpc_cidr
  build_subnet_cidr       = var.build_subnet_cidr
  build_availability_zone = var.build_availability_zone

  rhel9_ami_id_override      = var.rhel9_ami_id_override
  ubuntu2204_ami_id_override = var.ubuntu2204_ami_id_override
  ubuntu2404_ami_id_override = var.ubuntu2404_ami_id_override

  windows_build_instance_types = var.windows_build_instance_types
  linux_build_instance_types   = var.linux_build_instance_types

  distribution_regions = var.distribution_regions

  windows2019_schedule_expression = var.windows2019_schedule_expression
  windows2022_schedule_expression = var.windows2022_schedule_expression
  rhel9_schedule_expression       = var.rhel9_schedule_expression
  ubuntu2204_schedule_expression  = var.ubuntu2204_schedule_expression
  ubuntu2404_schedule_expression  = var.ubuntu2404_schedule_expression

  default_tags = var.default_tags
}
