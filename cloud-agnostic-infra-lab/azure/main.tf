# cloud-agnostic-infra-lab / Azure
# AWSとGCPとの概念差異を日本語コメントで明示しながら実装する

terraform {
  required_version = ">= 1.6"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.0"
    }
  }
}

provider "azurerm" {
  features {}
  subscription_id = var.subscription_id
}

# ---------------------------------------------------------------------------
# Resource Group
# AWSにもGCPにも存在しないAzure固有の概念
# リソースの論理グループ = ライフサイクル管理の単位
# 「RGを削除すれば中のリソースも全て消える」という設計が特徴的
# AWSはタグで論理グループ化するがRGのような強制削除はできない
# ---------------------------------------------------------------------------
resource "azurerm_resource_group" "main" {
  name     = "${var.project}-rg"
  location = var.location

  tags = local.common_tags
}

# ---------------------------------------------------------------------------
# Virtual Network
# AWSのVPCに相当するがリソースグループ内に属する点が異なる
# Azureでは「VNetピアリング」がAWSのVPC Peeringより設定が複雑
# ---------------------------------------------------------------------------
resource "azurerm_virtual_network" "main" {
  name                = "${var.project}-vnet"
  address_space       = ["10.0.0.0/16"]
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name

  tags = local.common_tags
}

# ---------------------------------------------------------------------------
# Subnet
# AzureのサブネットはVNet内のリソース（AWSと同様）
# ただしAzureはNSGをサブネット単位とNIC単位の両方にアタッチできる
# AWS: SG = インスタンス単位、NACL = サブネット単位（役割が分離）
# Azure: NSG = サブネット or NIC どちらにもアタッチ可能（柔軟だが複雑）
# ---------------------------------------------------------------------------
resource "azurerm_subnet" "public" {
  name                 = "${var.project}-subnet-public"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = ["10.0.1.0/24"]
}

# ---------------------------------------------------------------------------
# Network Security Group
# AWSのSGとNACLの中間的な概念
# ステートフルでAWSのSGに近いが、優先度番号でルールの順序を制御する点が異なる
# GCPのFirewallルールにも優先度があるため、この点はGCPに近い
# ---------------------------------------------------------------------------
resource "azurerm_network_security_group" "main" {
  name                = "${var.project}-nsg"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name

  security_rule {
    name                       = "AllowHTTP"
    priority                   = 100 # 数値が小さいほど優先度が高い（GCPと同じ概念）
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "80"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  tags = local.common_tags
}

resource "azurerm_subnet_network_security_group_association" "public" {
  subnet_id                 = azurerm_subnet.public.id
  network_security_group_id = azurerm_network_security_group.main.id
}

# ---------------------------------------------------------------------------
# Public IP
# AzureはPublic IPが独立したリソース（AWS/GCPはインスタンス or LBに内包）
# これがAzureの「明示的なリソース管理」思想を表している
# ---------------------------------------------------------------------------
resource "azurerm_public_ip" "lb" {
  name                = "${var.project}-pip-lb"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  allocation_method   = "Static"
  sku                 = "Standard"

  tags = local.common_tags
}

# ---------------------------------------------------------------------------
# Load Balancer
# AzureのLBはAWSのNLB相当（L4）がAzure Load Balancer
# L7（HTTP）はApplication Gateway（ALB相当）で別リソースになる
# 今回はコスト最小化のためL4 LB + バックエンドプール構成を使用
# ---------------------------------------------------------------------------
resource "azurerm_lb" "main" {
  name                = "${var.project}-lb"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  sku                 = "Standard"

  frontend_ip_configuration {
    name                 = "public"
    public_ip_address_id = azurerm_public_ip.lb.id
  }

  tags = local.common_tags
}

resource "azurerm_lb_backend_address_pool" "main" {
  loadbalancer_id = azurerm_lb.main.id
  name            = "${var.project}-bep"
}

resource "azurerm_lb_probe" "http" {
  loadbalancer_id = azurerm_lb.main.id
  name            = "http-probe"
  protocol        = "Http"
  port            = 80
  request_path    = "/"
}

resource "azurerm_lb_rule" "http" {
  loadbalancer_id                = azurerm_lb.main.id
  name                           = "http-rule"
  protocol                       = "Tcp"
  frontend_port                  = 80
  backend_port                   = 80
  frontend_ip_configuration_name = "public"
  backend_address_pool_ids       = [azurerm_lb_backend_address_pool.main.id]
  probe_id                       = azurerm_lb_probe.http.id
}

# ---------------------------------------------------------------------------
# Virtual Machine Scale Set (VMSS)
# AWSのASG、GCPのMIGに相当
# AzureはOrchestrationModeの選択が独特（Uniform vs Flexible）
# Flexibleは2021年以降のモード — 異なるVM SKUを混在させられる
# ---------------------------------------------------------------------------
resource "azurerm_linux_virtual_machine_scale_set" "nginx" {
  name                = "${var.project}-vmss"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  sku                 = "Standard_B1s" # 1vCPU, 1GiB RAM — コスト最小
  instances           = 1
  admin_username      = "azureuser"

  # Spot VM（AWS Spot / GCP Preemptibleに相当）
  priority        = "Spot"
  eviction_policy = "Deallocate" # Deleteより安全（データ保持）

  admin_ssh_key {
    username   = "azureuser"
    public_key = var.ssh_public_key
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts-arm64" # arm64でコスト最適化
    version   = "latest"
  }

  os_disk {
    storage_account_type = "Standard_LRS"
    caching              = "ReadWrite"
    disk_size_gb         = 30
  }

  network_interface {
    name    = "nic"
    primary = true

    ip_configuration {
      name                                   = "internal"
      primary                                = true
      subnet_id                              = azurerm_subnet.public.id
      load_balancer_backend_address_pool_ids = [azurerm_lb_backend_address_pool.main.id]
    }
  }

  custom_data = base64encode(<<-EOF
    #!/bin/bash
    apt-get update -y
    apt-get install -y nginx
    cat > /var/www/html/index.html << 'HTML'
    <h1>cloud-agnostic-infra-lab: Azure</h1>
    <p>Location: Japan East | IaC: Terraform | Compute: B1s Spot (arm64)</p>
    HTML
    systemctl enable --now nginx
  EOF
  )

  tags = local.common_tags
}

locals {
  common_tags = {
    Project     = var.project
    Environment = var.env
    ManagedBy   = "terraform"
    Cloud       = "azure"
  }
}
