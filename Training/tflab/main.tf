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
    owner = "training"
  }
}

# Resource Group
resource "azurerm_resource_group" "lab" {
  name     = "rg-ailab-${var.participant_name}"
  location = var.location
  tags     = local.common_tags
}

# Virtual Network
resource "azurerm_virtual_network" "lab" {
  name                = "vnet-ailab"
  address_space       = ["10.0.0.0/16"]
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name
  tags                = local.common_tags
}

# Subnets
resource "azurerm_subnet" "app" {
  name                 = "snet-app"
  resource_group_name  = azurerm_resource_group.lab.name
  virtual_network_name = azurerm_virtual_network.lab.name
  address_prefixes     = ["10.0.1.0/24"]
}

resource "azurerm_subnet" "db" {
  name                 = "snet-db"
  resource_group_name  = azurerm_resource_group.lab.name
  virtual_network_name = azurerm_virtual_network.lab.name
  address_prefixes     = ["10.0.2.0/24"]
}

resource "azurerm_subnet" "bastion" {
  name                 = "AzureBastionSubnet"
  resource_group_name  = azurerm_resource_group.lab.name
  virtual_network_name = azurerm_virtual_network.lab.name
  address_prefixes     = ["10.0.3.64/26"]
}

# NSGs — NOTE: intentional security issues for Lab 1 AI review exercise
resource "azurerm_network_security_group" "app" {
  name                = "nsg-app"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name

  security_rule {
    name                       = "AllowSSH"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = "10.0.3.0/27"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "AllowRDP"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "3389"
    source_address_prefix      = "10.0.3.0/27"
    destination_address_prefix = "*"
  }
  tags = local.common_tags
}

resource "azurerm_network_security_group" "db" {
  name                = "nsg-db"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name

  security_rule {
    name                       = "AllowPostgres"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "5432"
    source_address_prefix      = "10.0.1.0/24"
    destination_address_prefix = "*"
  }
  tags = local.common_tags
}

# NSG Associations
resource "azurerm_subnet_network_security_group_association" "app" {
  subnet_id                 = azurerm_subnet.app.id
  network_security_group_id = azurerm_network_security_group.app.id
}

resource "azurerm_subnet_network_security_group_association" "db" {
  subnet_id                 = azurerm_subnet.db.id
  network_security_group_id = azurerm_network_security_group.db.id
}

# Azure Bastion
# Bastion + Public IP are gated by var.deploy_bastion (default: false).
# Deploy only during lab sessions to avoid $0.195/hr 24/7 billing (~$108/month saving).
# Before lab:  terraform apply -var="deploy_bastion=true"
# After lab:   terraform apply -var="deploy_bastion=false"  (or set false in tfvars)
resource "azurerm_public_ip" "bastion" {
  count               = var.deploy_bastion ? 1 : 0
  name                = "pip-bastion"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = local.common_tags
}

resource "azurerm_bastion_host" "lab" {
  count               = var.deploy_bastion ? 1 : 0
  name                = "bastion-ailab"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name
  sku                 = "Basic"

  ip_configuration {
    name                 = "configuration"
    subnet_id            = azurerm_subnet.bastion.id
    public_ip_address_id = azurerm_public_ip.bastion[0].id
  }
  tags = local.common_tags
}

# Network Interfaces
resource "azurerm_network_interface" "app" {
  name                = "nic-app"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name
  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.app.id
    private_ip_address_allocation = "Static"
    private_ip_address            = "10.0.1.10"
  }
  tags = local.common_tags
}

resource "azurerm_network_interface" "db" {
  name                = "nic-db"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name
  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.db.id
    private_ip_address_allocation = "Static"
    private_ip_address            = "10.0.2.10"
  }
  tags = local.common_tags
}

resource "azurerm_network_interface" "win" {
  name                = "nic-win"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name
  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.app.id
    private_ip_address_allocation = "Static"
    private_ip_address            = "10.0.1.20"
  }
  tags = local.common_tags
}

# Virtual Machines
# vm-app: Azure Advisor recommends Standard_B1ms based on 3.2% average CPU.
# Recommendation REJECTED: peaks reach 97.4% across 4 lab stress exercises.
# B1ms has 1 vCPU (vs 2), 2 GiB RAM (vs 8 GiB), and a 144-credit bank (vs 576).
# Downsizing would throttle multi-exercise sessions, halve burst throughput, and
# risk OOM. Cost saving is $6.87/month — not justified. Review if lab workload changes.
resource "azurerm_linux_virtual_machine" "app" {
  name                            = "vm-app"
  resource_group_name             = azurerm_resource_group.lab.name
  location                        = azurerm_resource_group.lab.location
  size                            = "Standard_B2ms"
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
  boot_diagnostics {
    storage_account_uri = azurerm_storage_account.lab.primary_blob_endpoint
  }
  tags = local.common_tags
}

resource "azurerm_linux_virtual_machine" "db" {
  name                            = "vm-db"
  resource_group_name             = azurerm_resource_group.lab.name
  location                        = azurerm_resource_group.lab.location
  size                            = "Standard_B2ms"
  admin_username                  = "labadmin"
  admin_password                  = var.admin_password
  disable_password_authentication = false
  network_interface_ids           = [azurerm_network_interface.db.id]
  custom_data                     = base64encode(file("${path.module}/cloud-init-db.yaml"))
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
  boot_diagnostics {
    storage_account_uri = azurerm_storage_account.lab.primary_blob_endpoint
  }
  tags = local.common_tags
}

resource "azurerm_windows_virtual_machine" "win" {
  name                  = "vm-win"
  resource_group_name   = azurerm_resource_group.lab.name
  location              = azurerm_resource_group.lab.location
  size                  = "Standard_B2s"
  admin_username        = "labadmin"
  admin_password        = var.admin_password
  network_interface_ids = [azurerm_network_interface.win.id]
  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
    disk_size_gb         = 128
  }
  source_image_reference {
    publisher = "MicrosoftWindowsServer"
    offer     = "WindowsServer"
    sku       = "2022-datacenter-azure-edition"
    version   = "latest"
  }
  boot_diagnostics {
    storage_account_uri = azurerm_storage_account.lab.primary_blob_endpoint
  }
  tags = local.common_tags
}

# Storage Account
resource "azurerm_storage_account" "lab" {
  name                     = "stailab${var.participant_name}"
  resource_group_name      = azurerm_resource_group.lab.name
  location                 = azurerm_resource_group.lab.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
  account_kind             = "StorageV2"
  access_tier              = "Hot"
  blob_properties {
    delete_retention_policy {
      days = 30
    }
    container_delete_retention_policy {
      days = 30
    }
  }
  tags = local.common_tags
}

# Auto-shutdown schedules
resource "azurerm_dev_test_global_vm_shutdown_schedule" "app" {
  virtual_machine_id    = azurerm_linux_virtual_machine.app.id
  location              = azurerm_resource_group.lab.location
  enabled               = true
  daily_recurrence_time = "1300"
  timezone              = "UTC"
  notification_settings { enabled = false }
  tags                  = local.common_tags
}

resource "azurerm_dev_test_global_vm_shutdown_schedule" "db" {
  virtual_machine_id    = azurerm_linux_virtual_machine.db.id
  location              = azurerm_resource_group.lab.location
  enabled               = true
  daily_recurrence_time = "1300"
  timezone              = "UTC"
  notification_settings { enabled = false }
  tags                  = local.common_tags
}

resource "azurerm_dev_test_global_vm_shutdown_schedule" "win" {
  virtual_machine_id    = azurerm_windows_virtual_machine.win.id
  location              = azurerm_resource_group.lab.location
  enabled               = true
  daily_recurrence_time = "1300"
  timezone              = "UTC"
  notification_settings { enabled = false }
  tags                  = local.common_tags
}
