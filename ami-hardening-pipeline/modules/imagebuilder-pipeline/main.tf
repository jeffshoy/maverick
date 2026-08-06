# One custom CIS-hardening component per entry in var.component_documents.
resource "aws_imagebuilder_component" "cis" {
  for_each = { for c in var.component_documents : c.name => c }

  name     = "${var.project_name}-${var.environment}-${var.pipeline_name}-${each.value.name}"
  platform = var.platform
  version  = each.value.version
  data     = each.value.document

  tags = {
    Name = "${var.project_name}-${var.environment}-${var.pipeline_name}-${each.value.name}"
  }

  # Components/recipes are immutable per version and can't be deleted while a
  # pipeline still references them. create_before_destroy lets a version bump
  # create the new one and cut the pipeline over before the old one is destroyed.
  lifecycle {
    create_before_destroy = true
  }
}

# Recipe: parent image + custom CIS components (in list order) + any additional
# (e.g. AWS-managed) component ARNs appended after.
resource "aws_imagebuilder_image_recipe" "this" {
  name         = "${var.project_name}-${var.environment}-${var.pipeline_name}-cis"
  version      = var.recipe_version
  parent_image = var.parent_image_id

  dynamic "component" {
    for_each = [for c in var.component_documents : aws_imagebuilder_component.cis[c.name].arn]
    content {
      component_arn = component.value
    }
  }

  dynamic "component" {
    for_each = var.additional_component_arns
    content {
      component_arn = component.value
    }
  }

  block_device_mapping {
    device_name = var.root_device_name

    ebs {
      volume_size           = var.root_volume_size_gb
      volume_type           = "gp3"
      encrypted             = true
      kms_key_id            = var.kms_key_arn
      delete_on_termination = true
    }
  }

  tags = {
    Name = "${var.project_name}-${var.environment}-${var.pipeline_name}-cis"
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_imagebuilder_infrastructure_configuration" "this" {
  name                  = "${var.project_name}-${var.environment}-${var.pipeline_name}-infra"
  instance_profile_name = var.instance_profile_name
  instance_types        = var.instance_types
  subnet_id             = var.subnet_id
  security_group_ids    = var.security_group_ids

  # Build instances aren't SSH/RDP-reachable and take no inbound traffic —
  # terminate on failure rather than leaving a build instance running for debugging.
  terminate_instance_on_failure = true

  logging {
    s3_logs {
      s3_bucket_name = var.logs_bucket_name
      s3_key_prefix  = "${var.pipeline_name}/"
    }
  }

  tags = {
    Name = "${var.project_name}-${var.environment}-${var.pipeline_name}-infra"
  }
}

resource "aws_imagebuilder_distribution_configuration" "this" {
  name = "${var.project_name}-${var.environment}-${var.pipeline_name}-dist"

  distribution {
    region = data.aws_region.current.name

    ami_distribution_configuration {
      name = "${var.ami_name_prefix}-{{ imagebuilder:buildDate }}"

      kms_key_id = var.kms_key_arn
    }
  }

  dynamic "distribution" {
    for_each = var.distribution_regions
    content {
      region = distribution.value

      ami_distribution_configuration {
        name       = "${var.ami_name_prefix}-{{ imagebuilder:buildDate }}"
        kms_key_id = var.kms_key_arn
      }
    }
  }

  tags = {
    Name = "${var.project_name}-${var.environment}-${var.pipeline_name}-dist"
  }
}

data "aws_region" "current" {}

resource "aws_imagebuilder_image_pipeline" "this" {
  name                             = "${var.project_name}-${var.environment}-${var.pipeline_name}-pipeline"
  image_recipe_arn                 = aws_imagebuilder_image_recipe.this.arn
  infrastructure_configuration_arn = aws_imagebuilder_infrastructure_configuration.this.arn
  distribution_configuration_arn   = aws_imagebuilder_distribution_configuration.this.arn

  dynamic "schedule" {
    for_each = var.schedule_expression != null ? [var.schedule_expression] : []
    content {
      schedule_expression                = schedule.value
      pipeline_execution_start_condition = "EXPRESSION_MATCH_ONLY"
    }
  }

  tags = {
    Name = "${var.project_name}-${var.environment}-${var.pipeline_name}-pipeline"
  }
}
