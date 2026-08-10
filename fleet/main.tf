terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # backend "s3" {
  #   bucket         = "your-tfstate-bucket"
  #   key            = "vdi/fleet/terraform.tfstate"
  #   region         = "us-east-1"
  #   dynamodb_table = "your-tflock-table"
  #   encrypt        = true
  # }
}

provider "aws" {
  region = var.aws_region
}

############################################
# Individual user WorkSpaces
#
# NOTE: for high-churn environments (frequent onboard/offboard), consider
# replacing this for_each block with a Lambda triggered off your HR/ITSM
# system instead — Terraform state gets unwieldy past a few hundred
# individually tracked WorkSpaces. This works well for stable populations
# or as a starting point.
############################################

resource "aws_workspaces_workspace" "user" {
  for_each = var.users

  directory_id = var.workspaces_directory_id
  bundle_id    = var.bundle_id
  user_name    = each.value.user_name

  root_volume_encryption_enabled = true
  user_volume_encryption_enabled = true

  workspace_properties {
    running_mode                            = coalesce(each.value.running_mode, var.running_mode)
    running_mode_auto_stop_timeout_in_minutes = var.running_mode_auto_stop_timeout_minutes
    root_volume_size_gib                    = coalesce(each.value.root_volume_size_gb, var.root_volume_size_gb)
    user_volume_size_gib                    = coalesce(each.value.user_volume_size_gb, var.user_volume_size_gb)
    compute_type_name                       = "STANDARD"
  }

  tags = merge(var.tags, {
    Name = "workspace-${each.key}"
    User = each.value.user_name
  })
}

############################################
# Per-workspace disk usage alarm — example of fleet-level monitoring
# that platform-level alarms (aggregated by directory) don't cover
############################################

resource "aws_cloudwatch_metric_alarm" "user_volume_disk_high" {
  for_each = var.users

  alarm_name          = "workspace-${each.key}-uservolume-disk-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods   = 2
  metric_name         = "UserVolumeDiskUsage"
  namespace           = "AWS/WorkSpaces"
  period              = 3600
  statistic           = "Average"
  threshold           = 85 # percent
  alarm_description   = "User volume disk usage above 85% for ${each.value.user_name}"
  dimensions = {
    WorkspaceId = aws_workspaces_workspace.user[each.key].id
  }
  tags = var.tags
}
