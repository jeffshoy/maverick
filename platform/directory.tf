############################################
# Directory Service — choose one path based on var.directory_type
############################################

data "aws_secretsmanager_secret_version" "directory_admin_password" {
  secret_id = var.directory_admin_password_secret_arn
}

# --- Option A: AWS Managed Microsoft AD ---
# Use when there is no existing on-prem AD to federate against, or you want
# AWS to fully manage the domain controllers.

resource "aws_directory_service_directory" "managed_ad" {
  count    = var.directory_type == "managed_ad" ? 1 : 0
  name     = var.directory_name
  password = data.aws_secretsmanager_secret_version.directory_admin_password.secret_string
  edition  = var.directory_edition
  type     = "MicrosoftAD"

  vpc_settings {
    vpc_id     = aws_vpc.vdi.id
    subnet_ids = aws_subnet.workspaces[*].id
  }

  tags = merge(var.tags, {
    Name = "${var.project_name}-managed-ad"
  })
}

# --- Option B: AD Connector ---
# Use when federating to an existing on-prem Active Directory over VPN/Direct Connect.
# Requires on-prem DNS reachable from the workspaces subnets and a service account
# with delegated permissions to join computers to the domain.

resource "aws_directory_service_directory" "ad_connector" {
  count      = var.directory_type == "ad_connector" ? 1 : 0
  name       = var.directory_name
  short_name = var.directory_short_name
  password   = data.aws_secretsmanager_secret_version.directory_admin_password.secret_string
  type       = "ADConnector"

  connect_settings {
    customer_dns_ips  = var.onprem_dns_ips
    customer_username = var.connect_ad_service_account_username
    vpc_id            = aws_vpc.vdi.id
    subnet_ids        = aws_subnet.workspaces[*].id
  }

  tags = merge(var.tags, {
    Name = "${var.project_name}-ad-connector"
  })
}

locals {
  directory_id = var.directory_type == "managed_ad" ? aws_directory_service_directory.managed_ad[0].id : aws_directory_service_directory.ad_connector[0].id
}

############################################
# IP Access Control Group — restrict which source IPs can connect
############################################

resource "aws_workspaces_ip_group" "allowed" {
  name        = "${var.project_name}-allowed-ips"
  description = "Approved office and VPN CIDRs permitted to connect to WorkSpaces"

  dynamic "rules" {
    for_each = var.allowed_client_cidrs
    content {
      source      = rules.value
      description = "Allowed client CIDR"
    }
  }
}

############################################
# WorkSpaces Directory Registration
# This is the step that actually enables the directory for WorkSpaces use,
# and sets self-service permissions, default OU, and IP group association.
############################################

resource "aws_workspaces_directory" "vdi" {
  directory_id = local.directory_id
  subnet_ids   = aws_subnet.workspaces[*].id
  ip_group_ids = [aws_workspaces_ip_group.allowed.id]

  self_service_permissions {
    restart_workspace   = var.self_service_permissions.restart_workspace
    increase_volume_size = var.self_service_permissions.increase_volume
    change_compute_type = var.self_service_permissions.change_compute_type
    switch_running_mode = var.self_service_permissions.switch_running_mode
    rebuild_workspace   = var.self_service_permissions.rebuild_workspace
  }

  workspace_access_properties {
    device_type_windows    = "ALLOW"
    device_type_osx        = "ALLOW"
    device_type_web        = "ALLOW"
    device_type_ios        = "ALLOW"
    device_type_android    = "ALLOW"
    device_type_chromeos   = "ALLOW"
    device_type_zeroclient = "ALLOW"
    device_type_linux      = "DENY"
  }

  workspace_creation_properties {
    enable_internet_access              = var.enable_internet_access
    enable_maintenance_mode             = var.enable_maintenance_mode
    user_enabled_as_local_administrator = false
  }

  tags = merge(var.tags, {
    Name = "${var.project_name}-workspaces-directory"
  })

  depends_on = [aws_workspaces_ip_group.allowed]
}
