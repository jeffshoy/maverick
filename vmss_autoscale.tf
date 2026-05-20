data "azurerm_subscription" "current" {}

# --- VMSS ---
resource "azurerm_windows_virtual_machine_scale_set" "vmss" {
  name                = var.vmss_name
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  sku                 = var.vm_size
  instances           = var.vmss_instance_count
  admin_username      = var.admin_username
  admin_password      = var.admin_password

  source_image_reference {
    publisher = "MicrosoftWindowsServer"
    offer     = "WindowsServer"
    sku       = "2022-Datacenter"
    version   = "latest"
  }

  os_disk {
    storage_account_type = "Standard_LRS"
    caching              = "ReadWrite"
  }

  network_interface {
    name    = "nic-vmss"
    primary = true

    ip_configuration {
      name      = "ipconfig"
      primary   = true
      subnet_id = azurerm_subnet.subnet.id
    }
  }
}

# --- Storage Account for Function App ---
resource "azurerm_storage_account" "func_storage" {
  name                     = var.func_storage_account_name
  resource_group_name      = azurerm_resource_group.rg.name
  location                 = azurerm_resource_group.rg.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
  min_tls_version          = "TLS1_2"
}

# --- App Service Plan (Consumption) ---
resource "azurerm_service_plan" "func_plan" {
  name                = "func-autoscale-plan"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  os_type             = "Linux"
  sku_name            = "Y1"
}

# --- Function App ---
resource "azurerm_linux_function_app" "func_app" {
  name                       = "func-vmss-autoscale"
  resource_group_name        = azurerm_resource_group.rg.name
  location                   = azurerm_resource_group.rg.location
  storage_account_name       = azurerm_storage_account.func_storage.name
  storage_account_access_key = azurerm_storage_account.func_storage.primary_access_key
  service_plan_id            = azurerm_service_plan.func_plan.id

  identity {
    type = "SystemAssigned"
  }

  site_config {
    application_stack {
      python_version = "3.11"
    }
  }

  app_settings = {
    "FUNCTIONS_WORKER_RUNTIME" = "python"
    "AZURE_SUBSCRIPTION_ID"    = data.azurerm_subscription.current.subscription_id
    "VMSS_RESOURCE_GROUP"      = azurerm_resource_group.rg.name
    "VMSS_NAME"                = var.vmss_name
    "SCALE_OUT_CAPACITY"       = "5"
    "SCALE_IN_CAPACITY"        = "1"
  }
}

# --- Grant Function App Managed Identity rights to manage VMSS ---
resource "azurerm_role_assignment" "func_vmss_contributor" {
  scope                = data.azurerm_subscription.current.id
  role_definition_name = "Virtual Machine Contributor"
  principal_id         = azurerm_linux_function_app.func_app.identity[0].principal_id
}

# --- Action Group ---
resource "azurerm_monitor_action_group" "autoscale_ag" {
  name                = "ag-vmss-autoscale"
  resource_group_name = azurerm_resource_group.rg.name
  short_name          = "vmss-scale"

  email_receiver {
    name          = "admin"
    email_address = var.alert_email
  }

  azure_function_receiver {
    name                     = "vmss-scale-function"
    function_app_resource_id = azurerm_linux_function_app.func_app.id
    function_name            = "vmss_autoscale"
    http_trigger_url         = "https://${azurerm_linux_function_app.func_app.default_hostname}/api/vmss_autoscale"
    use_common_alert_schema  = true
  }
}

# --- CPU Scale Out (>80%) ---
resource "azurerm_monitor_metric_alert" "cpu_scale_out" {
  name                = "alert-cpu-scale-out"
  resource_group_name = azurerm_resource_group.rg.name
  scopes              = [azurerm_windows_virtual_machine_scale_set.vmss.id]
  description         = "Scale out when CPU > 80%"
  severity            = 2
  frequency           = "PT1M"
  window_size         = "PT5M"

  criteria {
    metric_namespace = "Microsoft.Compute/virtualMachineScaleSets"
    metric_name      = "Percentage CPU"
    aggregation      = "Average"
    operator         = "GreaterThan"
    threshold        = 80
  }

  action {
    action_group_id = azurerm_monitor_action_group.autoscale_ag.id
    webhook_properties = {
      "scaleDirection" = "out"
    }
  }
}

# --- CPU Scale In (<20%) ---
resource "azurerm_monitor_metric_alert" "cpu_scale_in" {
  name                = "alert-cpu-scale-in"
  resource_group_name = azurerm_resource_group.rg.name
  scopes              = [azurerm_windows_virtual_machine_scale_set.vmss.id]
  description         = "Scale in when CPU < 20%"
  severity            = 2
  frequency           = "PT1M"
  window_size         = "PT5M"

  criteria {
    metric_namespace = "Microsoft.Compute/virtualMachineScaleSets"
    metric_name      = "Percentage CPU"
    aggregation      = "Average"
    operator         = "LessThan"
    threshold        = 20
  }

  action {
    action_group_id = azurerm_monitor_action_group.autoscale_ag.id
    webhook_properties = {
      "scaleDirection" = "in"
    }
  }
}

# --- RAM Scale Out (available memory < 20%) ---
resource "azurerm_monitor_metric_alert" "ram_scale_out" {
  name                = "alert-ram-scale-out"
  resource_group_name = azurerm_resource_group.rg.name
  scopes              = [azurerm_windows_virtual_machine_scale_set.vmss.id]
  description         = "Scale out when available memory < 20%"
  severity            = 2
  frequency           = "PT1M"
  window_size         = "PT5M"

  criteria {
    metric_namespace = "Microsoft.Compute/virtualMachineScaleSets"
    metric_name      = "Available Memory Bytes"
    aggregation      = "Average"
    operator         = "LessThan"
    threshold        = 20
  }

  action {
    action_group_id = azurerm_monitor_action_group.autoscale_ag.id
    webhook_properties = {
      "scaleDirection" = "out"
    }
  }
}
