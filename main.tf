locals {
  location = {
    australiaeast = "aue"
  }
  suffix = format("%s-%s-%s",
    local.location[var.location],
    var.environment,
  var.project)

  custom_data = <<EOF
#cloud-config
runcmd:
- [mkdir, '/actions-runner']
- cd /actions-runner
- [curl, -o, 'actions-runner.tar.gz', -L, 'https://github.com/actions/runner/releases/download/v${var.runner_version}/actions-runner-linux-x64-${var.runner_version}.tar.gz']
- [tar, -xzf, 'actions-runner.tar.gz']
- [chmod, -R, 777, '/actions-runner']
- [su, runner-admin, -c, '/actions-runner/config.sh --url https://github.com/${var.github_organisation} --token ${var.runner_token} --runnergroup ${var.runner_group_name}']
- ./svc.sh install
- ./svc.sh start
- [rm, '/actions-runner/actions-runner.tar.gz']
EOF
}


/*Now that we have our dependencies available to us through the locals we now need to build out the basic Azure components.

azurerm_resource_group - This is the resource group where the resources will be deployed.
azurerm_storage_account - This is the storage account where the boot diagnostics logs will be stored from our IaaS instance.
tls_private_key - The key that we will use to authenticate to our GHAR.*/


resource "azurerm_resource_group" "liquibase" {
  name     = format("rg-%s", local.suffix)
  location = var.location
}

resource "azurerm_storage_account" "liquibase" {
  name                     = format("sa%s", replace(local.suffix, "-", ""))
  resource_group_name      = azurerm_resource_group.liquibase.name
  location                 = azurerm_resource_group.liquibase.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
}

resource "tls_private_key" "liquibase" {
  algorithm = "RSA"
  rsa_bits  = 2048
}


/*The next cab off the rank will be the networking stack.

azurerm_virtual_network - Network where our GHARs will be connected to.
azurerm_subnet - Subnet where our GHARs will be connected to.
azurerm_network_interface - The network interface that will be used by the IaaS instance, and it will lie in the defined subnet.*/

resource "azurerm_virtual_network" "liquibase" {
  name                = format("vn-%s", local.suffix)
  resource_group_name = azurerm_resource_group.liquibase.name
  location            = azurerm_resource_group.liquibase.location

  address_space = [var.network_range]
}

resource "azurerm_subnet" "runners" {
  name                 = format("sn-%s", local.suffix)
  resource_group_name  = azurerm_resource_group.liquibase.name
  virtual_network_name = azurerm_virtual_network.liquibase.name

  address_prefixes = [cidrsubnet(var.network_range, 0, 0)]
}

resource "azurerm_network_interface" "liquibase" {
  name                = format("ni-%s", local.suffix)
  resource_group_name = azurerm_resource_group.liquibase.name
  location            = azurerm_resource_group.liquibase.location

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.runners.id
    private_ip_address_allocation = "Dynamic"
  }
}

/*The last piece of the puzzle is the IaaS instance itself.

azurerm_linux_virtual_machine - The IaaS instance that will be used to run the Github Actions runner.*/

resource "azurerm_linux_virtual_machine" "runners" {
  name                            = replace(format("vm-%s", local.suffix), "-", "")
  resource_group_name             = azurerm_resource_group.liquibase.name
  location                        = azurerm_resource_group.liquibase.location
  size                            = var.runner_size
  admin_username                  = "runner-admin"
  network_interface_ids           = [azurerm_network_interface.liquibase.id]

  admin_ssh_key {
    username   = "runner-admin"
    public_key = tls_private_key.liquibase.public_key_openssh
  }

  os_disk {
    caching              = "None"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = split(":", var.image_urn)[0]
    offer     = split(":", var.image_urn)[1]
    sku       = split(":", var.image_urn)[2]
    version   = split(":", var.image_urn)[3]
  }

  boot_diagnostics {
    storage_account_uri = azurerm_storage_account.liquibase.primary_blob_endpoint
  }

  custom_data = base64encode(local.custom_data)
}