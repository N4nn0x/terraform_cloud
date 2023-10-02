terraform {
  
required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.74.0"
    }
  }
}

provider "azurerm" {
  features {}
  client_id       = var.ARM_CLIENT_ID
  client_secret   = var.ARM_CLIENT_SECRET
  subscription_id = var.ARM_SUBSCRIPTION_ID
  tenant_id       = var.ARM_TENANT_ID
}

resource "azurerm_resource_group" "mtc-rg" {
  name     = "mtc-resources"
  location = "Australia East"
  tags = {
    environment = "Dev"
  }
}

resource "azurerm_virtual_network" "mtc-vn" {
  name                = "mtc-network"
  resource_group_name = azurerm_resource_group.mtc-rg.name
  location            = azurerm_resource_group.mtc-rg.location
  address_space       = ["10.123.0.0/16"]

  tags = {
    environment = "dev"
  }
}

resource "azurerm_subnet" "mtc-subnet" {
  name                 = "mtc-subnet"
  resource_group_name  = azurerm_resource_group.mtc-rg.name
  virtual_network_name = azurerm_virtual_network.mtc-vn.name
  address_prefixes     = ["10.123.1.0/24"]
}

resource "azurerm_network_security_group" "mtc-sg" {
  name                = "mtc-sg"
  location            = azurerm_resource_group.mtc-rg.location
  resource_group_name = azurerm_resource_group.mtc-rg.name

  tags = {
    environment = "dev"
  }
}

resource "azurerm_network_security_rule" "mtc-dev-rule" {
  name                        = "mtc-dev-rule"
  priority                    = 100
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"  # Set the protocol to TCP for SSH
  source_port_range           = "*"    # Allow traffic from any source port
  destination_port_range      = "22"   # Allow traffic only on port 22 (SSH)
  source_address_prefix       = "*"    # Allow traffic from any source IP address
  destination_address_prefix  = "*"    # Allow traffic to any destination IP address
  resource_group_name         = azurerm_resource_group.mtc-rg.name
  network_security_group_name = azurerm_network_security_group.mtc-sg.name
}

resource "azurerm_subnet_network_security_group_association" "mtc-sga" {
  subnet_id                 = azurerm_subnet.mtc-subnet.id
  network_security_group_id = azurerm_network_security_group.mtc-sg.id
}

resource "azurerm_public_ip" "mtc-ip" {
  name                = "mtc-ip"
  resource_group_name = azurerm_resource_group.mtc-rg.name
  location            = azurerm_resource_group.mtc-rg.location
  allocation_method   = "Dynamic"

  tags = {
    environment = "dev"
  }
}

resource "azurerm_network_interface" "mtc-nic" {
  name                = "mtc-nic"
  location            = azurerm_resource_group.mtc-rg.location
  resource_group_name = azurerm_resource_group.mtc-rg.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.mtc-subnet.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.mtc-ip.id
  }

  tags = {
    environment = "dev"
  }
}

resource "azurerm_linux_virtual_machine" "mtc-vm" {
  name                = "mtc-vm"
  resource_group_name = azurerm_resource_group.mtc-rg.name
  location            = azurerm_resource_group.mtc-rg.location
  size                = "Standard_B1s"
  admin_username      = "adminuser"
  network_interface_ids = [
    azurerm_network_interface.mtc-nic.id,
  ]

  custom_data = filebase64("customdata.tpl")

  admin_ssh_key {
    username   = "adminuser"
    public_key = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQDqX/iaoZIhTAgG9pV8f6bJksdPMC7UMIwufWAW3Nfx41uOcHiWAxR3cXl6RYCNX+2a2U7qY+WGG72t6pqbdS8giNmacVdIz39gmEkg+zG1RjytkmOhyLBGICN3IvMzU+OBBL0HG20f45ftJIloddtJq+yc3A+vmIWgTqQ8QeR1ByTj9d474nuGEtBotPui8h4X4s6x0QkKos4qZgKQIiOitH4Zw3YpwVqoAw21Y/hHtHBIm/m3DqjYNse0usPss6RipLvK3tCZUKvlmQ8KWJSvq+iqPdMH16lmv22aQNlOKYrV550DU6HKSnwSy1RpijlT7agBVTPsE95/ezweWVsBHNFf0kX83tXbYYVaiOuIykt9UD4uPtsnoKmQDQMvkwPmHcvge8zDHArzPq/Safn83UHB/N4lAQXJjEqW0uuxXKsVz7XNkDbaesvf7Ab4+r7sAyzsLC7guVmc2b57zDnosbw8p+DrI6R0SD+JUXpQRH4yoNu58jvX856HZxWOeQM="
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-focal"
    sku       = "20_04-lts-gen2"
    version   = "latest"
  }

  #To enable SSH once provisioned
  provisioner "local-exec" {
    command = templatefile("${var.host_os}-ssh-script.tpl", {
      hostname     = self.public_ip_address,
      user         = "adminuser",
      identityfile = "~/.ssh/mtcazurekey"
    })
    interpreter = var.host_os == "windows" ? ["Powershell", "-Command"] : ["bash", "-c"]
  }

  #To STOP the VM once provisioned (will still incur charges)
  custom_data1 = <<-EOF
    #!/bin/bash
    az vm stop --name mtc-vm --resource-group mtc-resources
    EOF

  tags = {
    environment = "dev"
  }
}

data "azurerm_public_ip" "mtc-ip-data" {
  name                = azurerm_public_ip.mtc-ip.name
  resource_group_name = azurerm_resource_group.mtc-rg.name
}

output "public_ip_address" {
  value = "${azurerm_linux_virtual_machine.mtc-vm.name}: ${data.azurerm_public_ip.mtc-ip-data.ip_address}"
}

