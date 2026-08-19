# Dedicated build VPC — only created when vpc_id/subnet_id are left null.
module "build_vpc" {
  count  = var.vpc_id == null || var.subnet_id == null ? 1 : 0
  source = "./modules/build-vpc"

  project_name      = var.project_name
  environment       = var.environment
  vpc_cidr          = var.build_vpc_cidr
  subnet_cidr       = var.build_subnet_cidr
  availability_zone = var.build_availability_zone
}

locals {
  resolved_vpc_id    = var.vpc_id != null ? var.vpc_id : one(module.build_vpc[*].vpc_id)
  resolved_subnet_id = var.subnet_id != null ? var.subnet_id : one(module.build_vpc[*].subnet_id)
}

# Shared IAM role/instance profile, CIS compliance evidence bucket, and default
# build security group — created once, consumed by all 4 pipelines below.
module "imagebuilder_core" {
  source = "./modules/imagebuilder-core"

  project_name      = var.project_name
  environment       = var.environment
  vpc_id            = local.resolved_vpc_id
  security_group_id = var.security_group_id
  kms_key_arn       = var.kms_key_arn
}

# ── Base image resolution ─────────────────────────────────────────────────────

data "aws_ssm_parameter" "windows2019" {
  name = "/aws/service/ami-windows-latest/Windows_Server-2019-English-Full-Base"
}

data "aws_ssm_parameter" "windows2022" {
  name = "/aws/service/ami-windows-latest/Windows_Server-2022-English-Full-Base"
}

data "aws_ami" "windows2019" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "image-id"
    values = [data.aws_ssm_parameter.windows2019.value]
  }
}

data "aws_ami" "windows2022" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "image-id"
    values = [data.aws_ssm_parameter.windows2022.value]
  }
}

# Owned directly by Red Hat's account, not a Marketplace product — confirmed
# 2026-08-04 via `aws ec2 describe-images` (ProductCodes: null on the resolved
# AMI), so no subscription/opt-in step is needed before building from it.
data "aws_ami" "rhel9" {
  count       = var.rhel9_ami_id_override == "" ? 1 : 0
  most_recent = true
  owners      = ["309956199498"] # Red Hat

  filter {
    name   = "name"
    values = ["RHEL-9*_HVM-*"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}

locals {
  resolved_rhel9_ami_id = var.rhel9_ami_id_override != "" ? var.rhel9_ami_id_override : one(data.aws_ami.rhel9[*].id)
}

data "aws_ami" "rhel9_resolved" {
  # Re-lookup by the resolved ID so root_device_name is always available regardless
  # of whether the ID came from the override var or the data source above.
  filter {
    name   = "image-id"
    values = [local.resolved_rhel9_ami_id]
  }
}

# Owned directly by Canonical's account, not a Marketplace product — confirmed
# 2026-08-04 via `aws ec2 describe-images` (ProductCodes: null on the resolved
# AMI), so no subscription/opt-in step is needed before building from it.
data "aws_ami" "ubuntu2204" {
  count       = var.ubuntu2204_ami_id_override == "" ? 1 : 0
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu-pro-server/images/hvm-ssd/ubuntu-jammy-22.04-amd64-pro-server-*"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}

locals {
  resolved_ubuntu2204_ami_id = var.ubuntu2204_ami_id_override != "" ? var.ubuntu2204_ami_id_override : one(data.aws_ami.ubuntu2204[*].id)
}

data "aws_ami" "ubuntu2204_resolved" {
  filter {
    name   = "image-id"
    values = [local.resolved_ubuntu2204_ami_id]
  }
}

# Owned directly by Canonical's account, not a Marketplace product — same
# ownership pattern as ubuntu2204 above. Name filter uses "hvm-ssd-gp3" (not
# "hvm-ssd" like the jammy filter above) — confirmed 2026-08-19 by directly
# resolving real matching AMIs for this exact pattern; Canonical's noble
# catalog entries use gp3 as the published root volume type, unlike jammy's.
data "aws_ami" "ubuntu2404" {
  count       = var.ubuntu2404_ami_id_override == "" ? 1 : 0
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu-pro-server/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-pro-server-*"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}

locals {
  resolved_ubuntu2404_ami_id = var.ubuntu2404_ami_id_override != "" ? var.ubuntu2404_ami_id_override : one(data.aws_ami.ubuntu2404[*].id)
}

data "aws_ami" "ubuntu2404_resolved" {
  filter {
    name   = "image-id"
    values = [local.resolved_ubuntu2404_ami_id]
  }
}

# ── Component documents ───────────────────────────────────────────────────────

locals {
  windows2019_component_document = templatefile("${path.module}/components/windows-2019/cis-hardening.yaml.tpl", {
    logs_bucket = module.imagebuilder_core.logs_bucket_name
  })

  windows2022_component_document = templatefile("${path.module}/components/windows-2022/cis-hardening.yaml.tpl", {
    logs_bucket = module.imagebuilder_core.logs_bucket_name
  })

  rhel9_component_document = templatefile("${path.module}/components/rhel9/cis-hardening.yaml.tpl", {
    logs_bucket = module.imagebuilder_core.logs_bucket_name
  })

  ubuntu2204_component_document = templatefile("${path.module}/components/ubuntu-2204/cis-hardening.yaml.tpl", {
    logs_bucket = module.imagebuilder_core.logs_bucket_name
  })

  ubuntu2404_component_document = templatefile("${path.module}/components/ubuntu-2404/cis-hardening.yaml.tpl", {
    logs_bucket = module.imagebuilder_core.logs_bucket_name
  })
}

# ── Pipelines ──────────────────────────────────────────────────────────────────

module "windows2019_pipeline" {
  source = "./modules/imagebuilder-pipeline"

  project_name     = var.project_name
  environment      = var.environment
  pipeline_name    = "windows2019"
  platform         = "Windows"
  parent_image_id  = data.aws_ami.windows2019.id
  root_device_name = data.aws_ami.windows2019.root_device_name

  component_documents = [
    { name = "cis-hardening", version = "1.1.0", document = local.windows2019_component_document },
  ]
  recipe_version = "1.1.1"

  instance_types        = var.windows_build_instance_types
  instance_profile_name = module.imagebuilder_core.instance_profile_name
  subnet_id             = local.resolved_subnet_id
  security_group_ids    = [module.imagebuilder_core.security_group_id]
  logs_bucket_name      = module.imagebuilder_core.logs_bucket_name
  ami_name_prefix       = "${var.project_name}-${var.environment}-windows2019-cis"
  distribution_regions  = var.distribution_regions
  kms_key_arn           = var.kms_key_arn
  schedule_expression   = var.windows2019_schedule_expression
}

module "windows2022_pipeline" {
  source = "./modules/imagebuilder-pipeline"

  project_name     = var.project_name
  environment      = var.environment
  pipeline_name    = "windows2022"
  platform         = "Windows"
  parent_image_id  = data.aws_ami.windows2022.id
  root_device_name = data.aws_ami.windows2022.root_device_name

  component_documents = [
    { name = "cis-hardening", version = "1.1.0", document = local.windows2022_component_document },
  ]
  recipe_version = "1.1.1"

  instance_types        = var.windows_build_instance_types
  instance_profile_name = module.imagebuilder_core.instance_profile_name
  subnet_id             = local.resolved_subnet_id
  security_group_ids    = [module.imagebuilder_core.security_group_id]
  logs_bucket_name      = module.imagebuilder_core.logs_bucket_name
  ami_name_prefix       = "${var.project_name}-${var.environment}-windows2022-cis"
  distribution_regions  = var.distribution_regions
  kms_key_arn           = var.kms_key_arn
  schedule_expression   = var.windows2022_schedule_expression
}

module "rhel9_pipeline" {
  source = "./modules/imagebuilder-pipeline"

  project_name     = var.project_name
  environment      = var.environment
  pipeline_name    = "rhel9"
  platform         = "Linux"
  parent_image_id  = local.resolved_rhel9_ami_id
  root_device_name = data.aws_ami.rhel9_resolved.root_device_name

  component_documents = [
    { name = "cis-hardening", version = "1.1.0", document = local.rhel9_component_document },
  ]
  recipe_version = "1.1.1"

  instance_types        = var.linux_build_instance_types
  instance_profile_name = module.imagebuilder_core.instance_profile_name
  subnet_id             = local.resolved_subnet_id
  security_group_ids    = [module.imagebuilder_core.security_group_id]
  logs_bucket_name      = module.imagebuilder_core.logs_bucket_name
  ami_name_prefix       = "${var.project_name}-${var.environment}-rhel9-cis"
  distribution_regions  = var.distribution_regions
  kms_key_arn           = var.kms_key_arn
  schedule_expression   = var.rhel9_schedule_expression
}

module "ubuntu2204_pipeline" {
  source = "./modules/imagebuilder-pipeline"

  project_name     = var.project_name
  environment      = var.environment
  pipeline_name    = "ubuntu2204"
  platform         = "Linux"
  parent_image_id  = local.resolved_ubuntu2204_ami_id
  root_device_name = data.aws_ami.ubuntu2204_resolved.root_device_name

  component_documents = [
    { name = "cis-hardening", version = "1.0.3", document = local.ubuntu2204_component_document },
  ]
  recipe_version = "1.0.4"

  instance_types        = var.linux_build_instance_types
  instance_profile_name = module.imagebuilder_core.instance_profile_name
  subnet_id             = local.resolved_subnet_id
  security_group_ids    = [module.imagebuilder_core.security_group_id]
  logs_bucket_name      = module.imagebuilder_core.logs_bucket_name
  ami_name_prefix       = "${var.project_name}-${var.environment}-ubuntu2204-cis"
  distribution_regions  = var.distribution_regions
  kms_key_arn           = var.kms_key_arn
  schedule_expression   = var.ubuntu2204_schedule_expression
}

module "ubuntu2404_pipeline" {
  source = "./modules/imagebuilder-pipeline"

  project_name     = var.project_name
  environment      = var.environment
  pipeline_name    = "ubuntu2404"
  platform         = "Linux"
  parent_image_id  = local.resolved_ubuntu2404_ami_id
  root_device_name = data.aws_ami.ubuntu2404_resolved.root_device_name

  component_documents = [
    { name = "cis-hardening", version = "1.0.0", document = local.ubuntu2404_component_document },
  ]
  recipe_version = "1.0.0"

  instance_types        = var.linux_build_instance_types
  instance_profile_name = module.imagebuilder_core.instance_profile_name
  subnet_id             = local.resolved_subnet_id
  security_group_ids    = [module.imagebuilder_core.security_group_id]
  logs_bucket_name      = module.imagebuilder_core.logs_bucket_name
  ami_name_prefix       = "${var.project_name}-${var.environment}-ubuntu2404-cis"
  distribution_regions  = var.distribution_regions
  kms_key_arn           = var.kms_key_arn
  schedule_expression   = var.ubuntu2404_schedule_expression
}
