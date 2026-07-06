variable "workload" {
  type        = string
  description = "Workload or platform layer name used in resource naming."
}

variable "location" {
  type        = string
  description = "Resource location for Azure resources."
  default     = "uksouth"
}

variable "location_short" {
  type        = string
  description = "Short Azure region code (e.g. uks, ukw)."
  default     = "uks"
}

variable "instance" {
  type        = string
  description = "Two-digit instance number (e.g. 01)."
  default     = "01"
}

variable "environment" {
  type        = string
  description = "Name of Azure environment."
  default     = "prd"
}

variable "virtual_network" {
  description = "Virtual Network configuration."
  type = object({
    address_space = string
    dns_servers   = list(string)
  })
}

variable "subnets" {
  description = "Subnet Configuration."
  type = list(object({
    name             = string
    endpoints        = optional(list(string), [])
    address_prefixes = list(string)

    create_route_table = optional(bool, true)
    routes = optional(list(object({
      name                   = string
      address_prefix         = string
      next_hop_type          = string
      next_hop_in_ip_address = optional(string)
    })), [])

    network_security_group_enabled = optional(bool, true)
    nsg_rules = optional(list(object({
      access                       = optional(string)
      description                  = optional(string)
      destination_address_prefix   = optional(string)
      destination_address_prefixes = optional(list(string))
      destination_port_ranges      = optional(list(string))
      destination_port_range       = optional(string)
      direction                    = optional(string)
      name                         = string
      priority                     = number
      protocol                     = optional(string)
      source_address_prefix        = optional(string)
      source_address_prefixes      = optional(list(string))
      source_port_range            = optional(string)
      source_port_ranges           = optional(list(string))
    })), [])

    delegation = optional(list(object({
      name         = string
      service_name = string
      actions      = list(string)
    })), [])
  }))
  default = []
}

variable "management_group_subscriptions" {
  description = "Subscription IDs to associate with each management group."
  type = object({
    platform = optional(list(string), [])
    personal = optional(list(string), [])
    customer = optional(list(string), [])
  })
  default = {}
}

variable "dns_zones" {
  description = "Public DNS zones to create."
  type = list(object({
    name       = string
    cloudflare = optional(bool, false)
  }))
}

variable "cloudflare_api_token" {
  description = "Cloudflare API token with Zone and DNS edit permissions."
  type        = string
  sensitive   = true
}

variable "cloudflare_account_id" {
  description = "Cloudflare account ID."
  type        = string
}

variable "porkbun_api_key" {
  description = "Porkbun API key used to delegate nameservers from Porkbun to Cloudflare."
  type        = string
  sensitive   = true
}

variable "porkbun_secret_api_key" {
  description = "Porkbun secret API key used to delegate nameservers from Porkbun to Cloudflare."
  type        = string
  sensitive   = true
}

variable "budget_contact_emails" {
  description = "Email addresses to notify for budget alerts."
  type        = list(string)
}
