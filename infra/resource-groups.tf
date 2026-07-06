data "azurerm_resource_group" "platform" {
  name = "rg-${local.resource_suffix}"
}
