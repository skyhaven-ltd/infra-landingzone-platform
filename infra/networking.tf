resource "azurerm_virtual_network" "main" {
  name                = "vnet-${local.resource_suffix}"
  resource_group_name = data.azurerm_resource_group.platform.name
  location            = data.azurerm_resource_group.platform.location
  address_space       = [var.virtual_network.address_space]
  dns_servers         = var.virtual_network.dns_servers
  tags                = local.tags
}

resource "azurerm_subnet" "main" {
  for_each = { for subnet in var.subnets : subnet.name => subnet }

  name                 = "snet-${each.key}-${local.resource_suffix}"
  resource_group_name  = data.azurerm_resource_group.platform.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = each.value.address_prefixes
  service_endpoints    = each.value.endpoints

  dynamic "delegation" {
    for_each = each.value.delegation
    content {
      name = delegation.value.name
      service_delegation {
        name    = delegation.value.service_name
        actions = delegation.value.actions
      }
    }
  }
}

resource "azurerm_network_security_group" "main" {
  for_each = { for subnet in var.subnets : subnet.name => subnet if subnet.network_security_group_enabled }

  name                = "nsg-${each.key}-${local.resource_suffix}"
  resource_group_name = data.azurerm_resource_group.platform.name
  location            = data.azurerm_resource_group.platform.location
  tags                = local.tags

  dynamic "security_rule" {
    for_each = each.value.nsg_rules
    content {
      access                       = security_rule.value.access
      description                  = security_rule.value.description
      destination_address_prefix   = security_rule.value.destination_address_prefix
      destination_address_prefixes = security_rule.value.destination_address_prefixes
      destination_port_range       = security_rule.value.destination_port_range
      destination_port_ranges      = security_rule.value.destination_port_ranges
      direction                    = security_rule.value.direction
      name                         = security_rule.value.name
      priority                     = security_rule.value.priority
      protocol                     = security_rule.value.protocol
      source_address_prefix        = security_rule.value.source_address_prefix
      source_address_prefixes      = security_rule.value.source_address_prefixes
      source_port_range            = security_rule.value.source_port_range
      source_port_ranges           = security_rule.value.source_port_ranges
    }
  }
}

resource "azurerm_subnet_network_security_group_association" "main" {
  for_each = { for subnet in var.subnets : subnet.name => subnet if subnet.network_security_group_enabled }

  subnet_id                 = azurerm_subnet.main[each.key].id
  network_security_group_id = azurerm_network_security_group.main[each.key].id
}

resource "azurerm_route_table" "main" {
  for_each = { for subnet in var.subnets : subnet.name => subnet if subnet.create_route_table }

  name                = "rt-${each.key}-${local.resource_suffix}"
  resource_group_name = data.azurerm_resource_group.platform.name
  location            = data.azurerm_resource_group.platform.location
  tags                = local.tags
}

resource "azurerm_route" "main" {
  for_each = {
    for item in flatten([
      for subnet in var.subnets : [
        for route in subnet.routes : {
          subnet_name            = subnet.name
          route_name             = route.name
          address_prefix         = route.address_prefix
          next_hop_type          = route.next_hop_type
          next_hop_in_ip_address = route.next_hop_in_ip_address
        }
      ] if subnet.create_route_table
    ]) : "${item.subnet_name}-${item.route_name}" => item
  }

  name                   = each.value.route_name
  resource_group_name    = data.azurerm_resource_group.platform.name
  route_table_name       = azurerm_route_table.main[each.value.subnet_name].name
  address_prefix         = each.value.address_prefix
  next_hop_type          = each.value.next_hop_type
  next_hop_in_ip_address = each.value.next_hop_in_ip_address
}

resource "azurerm_subnet_route_table_association" "main" {
  for_each = { for subnet in var.subnets : subnet.name => subnet if subnet.create_route_table }

  subnet_id      = azurerm_subnet.main[each.key].id
  route_table_id = azurerm_route_table.main[each.key].id
}

resource "azurerm_network_watcher" "main" {
  name                = "nw-${local.resource_suffix}"
  resource_group_name = data.azurerm_resource_group.platform.name
  location            = data.azurerm_resource_group.platform.location
  tags                = local.tags
}
