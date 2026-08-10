output "vpc_id" {
  value = aws_vpc.vdi.id
}

output "workspaces_subnet_ids" {
  value = aws_subnet.workspaces[*].id
}

output "directory_id" {
  description = "Directory Service ID — consumed by the fleet layer to provision individual WorkSpaces"
  value       = local.directory_id
}

output "workspaces_directory_id" {
  description = "WorkSpaces directory registration ID — required by aws_workspaces_workspace in the fleet layer"
  value       = aws_workspaces_directory.vdi.id
}

output "ip_group_id" {
  value = aws_workspaces_ip_group.allowed.id
}

output "workspaces_security_group_id" {
  value = aws_security_group.workspaces.id
}

output "sns_alert_topic_arn" {
  value = aws_sns_topic.vdi_alerts.arn
}
