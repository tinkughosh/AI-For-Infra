terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.0"
    }
  }
}

provider "azurerm" {
  features {}
}

locals {
  common_tags = {
    owner       = "training"
    project     = "capstone"
    tower       = "network"
    participant = var.participant_name
  }
}

# ─────────────────────────────────────────────
# Resource Group
# ─────────────────────────────────────────────
resource "azurerm_resource_group" "capstone" {
  name     = "rg-capstone-${var.participant_name}"
  location = var.location
  tags     = local.common_tags
}

# ─────────────────────────────────────────────
# Virtual Network
# ─────────────────────────────────────────────
resource "azurerm_virtual_network" "capstone" {
  name                = "vnet-capstone"
  address_space       = ["10.10.0.0/16"]
  location            = azurerm_resource_group.capstone.location
  resource_group_name = azurerm_resource_group.capstone.name
  tags                = local.common_tags
}

# snet-app: hosts vm-app (public-facing, SSH accessible)
resource "azurerm_subnet" "app" {
  name                 = "snet-app"
  resource_group_name  = azurerm_resource_group.capstone.name
  virtual_network_name = azurerm_virtual_network.capstone.name
  address_prefixes     = ["10.10.1.0/24"]
}

# snet-backend: hosts vm-backend (private, no public IP)
resource "azurerm_subnet" "backend" {
  name                 = "snet-backend"
  resource_group_name  = azurerm_resource_group.capstone.name
  virtual_network_name = azurerm_virtual_network.capstone.name
  address_prefixes     = ["10.10.2.0/24"]
}

# ─────────────────────────────────────────────
# Network Security Groups
# ─────────────────────────────────────────────

# NSG for snet-app: allow inbound SSH (22) from internet
resource "azurerm_network_security_group" "app" {
  name                = "nsg-app"
  location            = azurerm_resource_group.capstone.location
  resource_group_name = azurerm_resource_group.capstone.name

  security_rule {
    name                       = "AllowSSH"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "DenyAllInbound"
    priority                   = 4096
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  tags = local.common_tags
}

# NSG for snet-backend: allow SSH from internet + ICMP from snet-app
# The AllowAppToBackend rule will be the fault-injection target (source will be broken)
resource "azurerm_network_security_group" "backend" {
  name                = "nsg-backend"
  location            = azurerm_resource_group.capstone.location
  resource_group_name = azurerm_resource_group.capstone.name

  security_rule {
    name                       = "AllowSSH"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  # This rule is the fault-injection target — source will be changed to break connectivity
  security_rule {
    name                       = "AllowAppToBackend"
    priority                   = 200
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Icmp"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "10.10.1.0/24"   # snet-app — correct source
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "DenyAllInbound"
    priority                   = 4096
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  tags = local.common_tags
}

# NSG Associations
resource "azurerm_subnet_network_security_group_association" "app" {
  subnet_id                 = azurerm_subnet.app.id
  network_security_group_id = azurerm_network_security_group.app.id
}

resource "azurerm_subnet_network_security_group_association" "backend" {
  subnet_id                 = azurerm_subnet.backend.id
  network_security_group_id = azurerm_network_security_group.backend.id
}

# ─────────────────────────────────────────────
# Public IPs — both VMs accessible via SSH
# ─────────────────────────────────────────────
resource "azurerm_public_ip" "app" {
  name                = "pip-app"
  location            = azurerm_resource_group.capstone.location
  resource_group_name = azurerm_resource_group.capstone.name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = local.common_tags
}

resource "azurerm_public_ip" "backend" {
  name                = "pip-backend"
  location            = azurerm_resource_group.capstone.location
  resource_group_name = azurerm_resource_group.capstone.name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = local.common_tags
}

# ─────────────────────────────────────────────
# Network Interfaces
# ─────────────────────────────────────────────
resource "azurerm_network_interface" "app" {
  name                = "nic-app"
  location            = azurerm_resource_group.capstone.location
  resource_group_name = azurerm_resource_group.capstone.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.app.id
    private_ip_address_allocation = "Static"
    private_ip_address            = "10.10.1.10"
    public_ip_address_id          = azurerm_public_ip.app.id
  }

  tags = local.common_tags
}

resource "azurerm_network_interface" "backend" {
  name                = "nic-backend"
  location            = azurerm_resource_group.capstone.location
  resource_group_name = azurerm_resource_group.capstone.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.backend.id
    private_ip_address_allocation = "Static"
    private_ip_address            = "10.10.2.10"
    public_ip_address_id          = azurerm_public_ip.backend.id
  }

  tags = local.common_tags
}

# ─────────────────────────────────────────────
# Virtual Machines
# ─────────────────────────────────────────────

# vm-app: public-facing, password auth, used as the jump point for connectivity testing
resource "azurerm_linux_virtual_machine" "app" {
  name                            = "vm-app"
  resource_group_name             = azurerm_resource_group.capstone.name
  location                        = azurerm_resource_group.capstone.location
  size                            = "Standard_B1ms"
  admin_username                  = "labadmin"
  admin_password                  = var.admin_password
  disable_password_authentication = false
  network_interface_ids           = [azurerm_network_interface.app.id]

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
    disk_size_gb         = 30
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts-gen2"
    version   = "latest"
  }

  tags = local.common_tags
}

# vm-backend: public IP + SSH enabled; ICMP from vm-app will be the fault-injection target
resource "azurerm_linux_virtual_machine" "backend" {
  name                            = "vm-backend"
  resource_group_name             = azurerm_resource_group.capstone.name
  location                        = azurerm_resource_group.capstone.location
  size                            = "Standard_B1ms"
  admin_username                  = "labadmin"
  admin_password                  = var.admin_password
  disable_password_authentication = false
  network_interface_ids           = [azurerm_network_interface.backend.id]

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
    disk_size_gb         = 30
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts-gen2"
    version   = "latest"
  }

  tags = local.common_tags
}
