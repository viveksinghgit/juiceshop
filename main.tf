provider "azurerm" {
  tenant_id       = "tenantid_value" #change to actual
  subscription_id = "subscriptionid_value" #change to actual
  client_id       = "clientid_value" #change to actual
  client_secret   = "clientsecret_value" #change to actual
  features {}
}



resource "azurerm_resource_group" "my_rg" {
  name     = "juiceshop-rg"
  location = "Central India" 
}

resource "azurerm_virtual_network" "my_vnet" {
  name                = "juiceshop-vnet"
  address_space       = ["10.11.0.0/16"]
  location            = azurerm_resource_group.my_rg.location
  resource_group_name = azurerm_resource_group.my_rg.name
}

resource "azurerm_subnet" "my_subnet" {
  name                 = "juiceshop-subnet"
  resource_group_name  = azurerm_resource_group.my_rg.name
  virtual_network_name = azurerm_virtual_network.my_vnet.name
  address_prefixes       = ["10.11.0.0/24"]
    delegation {
    name = "aci"
    service_delegation {
      name = "Microsoft.ContainerInstance/containerGroups"
    }
    }
} 

resource "azurerm_container_group" "juiceshop" {
  name                = "juiceshop-container"
  location            = azurerm_resource_group.my_rg.location
  resource_group_name = azurerm_resource_group.my_rg.name
  os_type             = "Linux" 
  ip_address_type     = "Private"
  subnet_ids           = [azurerm_subnet.my_subnet.id] 

  container {
    name   = "juiceshop"
    image  = "bkimminich/juice-shop:v15.0.0"
    cpu    = "1"
    memory = "1.5"
    ports {
      port     = 3000
      protocol = "TCP"
    }
  }

  container {
    name   = "nginx-proxy"
    image  = "nginx:1.25-alpine"
    cpu    = "0.5"
    memory = "0.5"
    ports {
      port     = 80
      protocol = "TCP"
    }
  }
}


resource "azurerm_lb" "juiceshop_lb" {
  name                = "juiceshop-lb"
  location            = azurerm_resource_group.my_rg.location
  resource_group_name = azurerm_resource_group.my_rg.name

  frontend_ip_configuration {
    name                 = "public-ip"
    public_ip_address_id = azurerm_public_ip.juiceshop_pip.id
  }
}


resource "azurerm_lb_backend_address_pool" "juiceshop_backend_pool" {
  loadbalancer_id     = azurerm_lb.juiceshop_lb.id
  name                = "juiceshop-backend-pool"
}


resource "azurerm_lb_probe" "juiceshop_probe" {
  loadbalancer_id     = azurerm_lb.juiceshop_lb.id 
  name                = "juiceshop-probe"
  protocol            = "Http"
  port                = 80
  interval_in_seconds = 5
  number_of_probes    = 2
  request_path        = "/" 
}


resource "azurerm_lb_rule" "juiceshop_rule" {
  loadbalancer_id                = azurerm_lb.juiceshop_lb.id
  name                           = "juiceshop-rule"
  protocol                       = "Tcp"
  frontend_ip_configuration_name = "public-ip"
  frontend_port                  = 80
  backend_port                   = 80  
  backend_address_pool_ids       = [azurerm_lb_backend_address_pool.juiceshop_backend_pool.id]
  probe_id                       = azurerm_lb_probe.juiceshop_probe.id
}

resource "azurerm_public_ip" "juiceshop_pip" {
  name                = "juiceshop-pip"
  location            = azurerm_resource_group.my_rg.location
  resource_group_name = azurerm_resource_group.my_rg.name
  allocation_method   = "Static"
}


resource "azurerm_network_security_group" "juiceshop_nsg" {  
  name                = "juiceshop-nsg"
  location            = azurerm_resource_group.my_rg.location
  resource_group_name = azurerm_resource_group.my_rg.name

  security_rule {  
    name                       = "allow-zscaler"
    priority                   = 100
    access                     = "Allow"
    protocol                   = "*"
    direction                  = "Inbound"
    source_address_prefix      = "8.25.203.0/24"  
    destination_address_prefix = "*"
    destination_port_range     = "*"
    source_port_range          = "*" 
  }
}



resource "null_resource" "nginx_setup" {
    provisioner "local-exec" {
        command = <<EOT
        
        az extension add --name azure-keyvault-secrets
        az keyvault secret download --vault-name juiceshopkv --name cert-pem --file /etc/nginx/nginx.crt
        az keyvault secret download --vault-name juiceshopkv --name key-pem --file /etc/nginx/nginx.key

       
        cat <<EOF > /etc/nginx/nginx.conf
        server {
            listen 80;
            server_name localhost;

            location / {
                proxy_pass http://juiceshop:3000;
                proxy_set_header Host \$host;
                proxy_set_header X-Real-IP \$remote_addr;
            }
        }
        EOF

        
        service nginx restart
        EOT
    }

    triggers = {
        template = "${azurerm_container_group.juiceshop.id}"
    }
}
