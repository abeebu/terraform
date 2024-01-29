resource "random_string" "suffix" {
  length  = 5
  special = false
  upper   = false
}

resource "azurerm_resource_group" "rg" {
  name     = "rg-iothub-${random_string.suffix.result}"
  location = var.location
}

resource "azurerm_storage_account" "sa" {
  name                     = "storageaccount${random_string.suffix.result}"
  resource_group_name      = azurerm_resource_group.rg.name
  location                 = azurerm_resource_group.rg.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
}

resource "azurerm_storage_container" "sa_container" {
  name                  = "storagecontainer${random_string.suffix.result}"
  storage_account_name  = azurerm_storage_account.sa.name
  container_access_type = "private"
}

resource "azurerm_eventhub_namespace" "eventhub_namespace" {
  name                          = "eventhub-namespace-${random_string.suffix.result}"
  resource_group_name           = azurerm_resource_group.rg.name
  location                      = azurerm_resource_group.rg.location
  public_network_access_enabled = false
  sku                           = "Premium"

  network_rulesets {
    default_action                 = "Deny"
    public_network_access_enabled  = false
    trusted_service_access_enabled = true
  }
}

resource "azurerm_eventhub" "eventhub" {
  name                = "eventhub-${random_string.suffix.result}"
  resource_group_name = azurerm_resource_group.rg.name
  namespace_name      = azurerm_eventhub_namespace.eventhub_namespace.name
  partition_count     = 1
  message_retention   = 1
}

resource "azurerm_eventhub_authorization_rule" "eventhub_rule" {
  resource_group_name = azurerm_resource_group.rg.name
  namespace_name      = azurerm_eventhub_namespace.eventhub_namespace.name
  eventhub_name       = azurerm_eventhub.eventhub.name
  name                = "authrule"
  send                = true
}

resource "azurerm_iothub" "iothub" {
  name                          = "iothub-${random_string.suffix.result}"
  resource_group_name           = azurerm_resource_group.rg.name
  location                      = azurerm_resource_group.rg.location
  public_network_access_enabled = false

  sku {
    name     = "S1"
    capacity = 1
  }

  identity {
    type = "SystemAssigned"
  }

  cloud_to_device {
    max_delivery_count = 30
    default_ttl        = "PT1H"
    feedback {
      time_to_live       = "PT1H10M"
      max_delivery_count = 15
      lock_duration      = "PT30S"
    }
  }

}

resource "azurerm_role_assignment" "eventhub" {
  scope                = azurerm_eventhub_namespace.eventhub_namespace.id
  role_definition_name = "Azure Event Hubs Data Sender"
  principal_id         = azurerm_iothub.iothub.identity.0.principal_id
}

resource "azurerm_role_assignment" "storage" {
  scope                = azurerm_storage_account.sa.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_iothub.iothub.identity.0.principal_id
}

resource "azurerm_iothub_endpoint_eventhub" "eventhub" {
  resource_group_name = azurerm_resource_group.rg.name
  iothub_id           = azurerm_iothub.iothub.id
  name                = "eventExport"
  authentication_type = "identityBased"
  entity_path         = azurerm_eventhub.eventhub.name
  endpoint_uri        = format("sb://%s.servicebus.windows.net", azurerm_eventhub_namespace.eventhub_namespace.name)
}

resource "azurerm_iothub_endpoint_storage_container" "storage" {
  resource_group_name        = azurerm_resource_group.rg.name
  iothub_id                  = azurerm_iothub.iothub.id
  authentication_type        = "identityBased"
  name                       = "storageExport"
  endpoint_uri               = azurerm_storage_account.sa.primary_blob_endpoint
  batch_frequency_in_seconds = 120
  max_chunk_size_in_bytes    = 10485760
  container_name             = azurerm_storage_container.sa_container.name
  encoding                   = "Avro"
  file_name_format           = "{iothub}/{partition}_{YYYY}_{MM}_{DD}_{HH}_{mm}"
}

resource "azurerm_iothub_route" "eventhub" {
  resource_group_name = azurerm_resource_group.rg.name
  iothub_name         = azurerm_iothub.iothub.name
  name                = "eventExport"
  source              = "DeviceMessages"
  endpoint_names      = [azurerm_iothub_endpoint_eventhub.eventhub.name]
  enabled             = true
}

resource "azurerm_iothub_route" "storage" {
  resource_group_name = azurerm_resource_group.rg.name
  iothub_name         = azurerm_iothub.iothub.name
  name                = "storageExport"
  source              = "DeviceMessages"
  endpoint_names      = [azurerm_iothub_endpoint_storage_container.storage.name]
  enabled             = true
}

resource "azurerm_iothub_shared_access_policy" "iothub_policy" {
  name                = "iothub-policy-${random_string.suffix.result}"
  resource_group_name = azurerm_resource_group.rg.name
  iothub_name         = azurerm_iothub.iothub.name
  registry_read       = true
  registry_write      = true
  service_connect     = true

  depends_on = [azurerm_private_endpoint.iothub]
}

resource "azurerm_iothub_dps" "dps" {
  name                          = "dps-${random_string.suffix.result}"
  resource_group_name           = azurerm_resource_group.rg.name
  location                      = azurerm_resource_group.rg.location
  allocation_policy             = "Hashed"
  public_network_access_enabled = false

  sku {
    name     = "S1"
    capacity = "1"
  }

  linked_hub {
    connection_string       = azurerm_iothub_shared_access_policy.iothub_policy.primary_connection_string
    location                = azurerm_resource_group.rg.location
    allocation_weight       = 150
    apply_allocation_policy = true
  }
}