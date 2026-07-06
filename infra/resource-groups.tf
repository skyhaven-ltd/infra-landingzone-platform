# Created by scripts/bootstrap-platform.sh (state storage + platform Key Vault
# live here); referenced read-only so Terraform never manages its lifecycle.
data "azurerm_resource_group" "platform" {
  name = "rg-${local.resource_suffix}"
}

resource "azurerm_resource_group" "networking" {
  name     = "rg-netw-${local.resource_suffix}"
  location = var.location
  tags     = local.tags
}
