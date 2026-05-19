resource "azurerm_log_analytics_workspace" "law" {
  name                = "law-${var.vm_name}"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  sku                 = "PerGB2018"
  retention_in_days   = 30
}

resource "azurerm_virtual_machine_extension" "mma" {
  name                       = "MicrosoftMonitoringAgent"
  virtual_machine_id         = azurerm_windows_virtual_machine.vm.id
  publisher                  = "Microsoft.EnterpriseCloud.Monitoring"
  type                       = "MicrosoftMonitoringAgent"
  type_handler_version       = "1.0"
  auto_upgrade_minor_version = true

  settings = jsonencode({
    workspaceId = azurerm_log_analytics_workspace.law.workspace_id
  })

  protected_settings = jsonencode({
    workspaceKey = azurerm_log_analytics_workspace.law.primary_shared_key
  })
}

resource "azurerm_monitor_diagnostic_setting" "vm_diag" {
  name                       = "diag-${var.vm_name}"
  target_resource_id         = azurerm_windows_virtual_machine.vm.id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.law.id

  metric {
    category = "AllMetrics"
    enabled  = true
  }
}

resource "azurerm_monitor_action_group" "alerts" {
  name                = "ag-${var.vm_name}"
  resource_group_name = azurerm_resource_group.rg.name
  short_name          = "vmalerts"

  email_receiver {
    name          = "admin"
    email_address = var.alert_email
  }
}

resource "azurerm_monitor_scheduled_query_rules_alert" "vm_heartbeat" {
  name                = "alert-${var.vm_name}-heartbeat"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  description         = "VM stopped sending heartbeats to Log Analytics"
  enabled             = true
  severity            = 1
  frequency           = 5
  time_window         = 10
  data_source_id      = azurerm_log_analytics_workspace.law.id

  query = <<-QUERY
    Heartbeat
    | where Computer =~ "${var.vm_name}"
    | summarize LastHeartbeat = max(TimeGenerated)
    | where LastHeartbeat < ago(5m)
  QUERY

  action {
    action_group = [azurerm_monitor_action_group.alerts.id]
  }

  trigger {
    operator  = "GreaterThan"
    threshold = 0
  }
}

resource "azurerm_monitor_scheduled_query_rules_alert" "disk_space_low" {
  name                = "alert-${var.vm_name}-disk-space"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  description         = "C: drive free space below 15%"
  enabled             = true
  severity            = 2
  frequency           = 15
  time_window         = 30
  data_source_id      = azurerm_log_analytics_workspace.law.id

  query = <<-QUERY
    Perf
    | where Computer =~ "${var.vm_name}"
    | where ObjectName == "LogicalDisk" and CounterName == "% Free Space"
    | where InstanceName == "C:"
    | summarize AvgFreeSpace = avg(CounterValue) by Computer, InstanceName
    | where AvgFreeSpace < 15
  QUERY

  action {
    action_group = [azurerm_monitor_action_group.alerts.id]
  }

  trigger {
    operator  = "GreaterThan"
    threshold = 0
  }
}

resource "azurerm_monitor_activity_log_alert" "vm_deallocated" {
  name                = "alert-${var.vm_name}-deallocated"
  resource_group_name = azurerm_resource_group.rg.name
  scopes              = [azurerm_resource_group.rg.id]
  description         = "VM was deallocated"

  criteria {
    resource_id    = azurerm_windows_virtual_machine.vm.id
    operation_name = "Microsoft.Compute/virtualMachines/deallocate/action"
    category       = "Administrative"
  }

  action {
    action_group_id = azurerm_monitor_action_group.alerts.id
  }
}

resource "azurerm_monitor_activity_log_alert" "vm_stopped" {
  name                = "alert-${var.vm_name}-stopped"
  resource_group_name = azurerm_resource_group.rg.name
  scopes              = [azurerm_resource_group.rg.id]
  description         = "VM was powered off"

  criteria {
    resource_id    = azurerm_windows_virtual_machine.vm.id
    operation_name = "Microsoft.Compute/virtualMachines/powerOff/action"
    category       = "Administrative"
  }

  action {
    action_group_id = azurerm_monitor_action_group.alerts.id
  }
}
