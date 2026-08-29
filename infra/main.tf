terraform {
  required_version = ">= 1.9"

  required_providers {
    proxmox = {
      source = "bpg/proxmox"
      # El roadmap se escribió contra ~> 0.66; el esquema cambió bastante desde
      # entonces. Fijado a la serie actual y validado con `tofu validate`.
      version = "~> 0.111"
    }
  }
}

provider "proxmox" {
  endpoint  = var.pve_endpoint
  api_token = var.pve_api_token
  insecure  = true # certificado autofirmado CN=pve.homelab.local

  # El provider abre SSH al nodo para las operaciones que la API no cubre
  # (importar discos, etc.). Sin ssh-agent: la llave del homelab no tiene
  # passphrase, así que se lee directa del archivo (decisión de la Fase 2).
  ssh {
    agent       = false
    username    = "root"
    private_key = file(var.ssh_private_key_path)
  }
}

locals {
  # Discos: 25 + 20 + 20 = 65 GB sobre un thin pool de 66,87 GB.
  # Memoria: 4 + 2 + 2 = 8 GB sobre 15,7 GB del host.
  nodes = {
    "k8s-cp-1" = { vmid = 101, ip = "192.168.1.51", cores = 2, memory = 4096, disk = 25 }
    "k8s-wk-1" = { vmid = 102, ip = "192.168.1.52", cores = 2, memory = 2048, disk = 20 }
    "k8s-wk-2" = { vmid = 103, ip = "192.168.1.53", cores = 2, memory = 2048, disk = 20 }
  }
}

resource "proxmox_virtual_environment_vm" "k8s" {
  for_each = local.nodes

  name      = each.key
  vm_id     = each.value.vmid
  node_name = var.pve_node
  tags      = ["kubernetes", "tofu"]

  # Sin esto, `destroy` se queda esperando un apagado ACPI que nadie atiende.
  stop_on_destroy = true
  # Sin esto, un reboot del host deja el cluster caído.
  on_boot = true

  clone {
    vm_id = var.template_vm_id
    full  = true
  }

  agent {
    enabled = true
    # Falla claro a los 5 min en vez de colgarse indefinidamente.
    timeout = "5m"
  }

  cpu {
    cores = each.value.cores
    type  = "host"
  }

  memory {
    dedicated = each.value.memory
    # 0 = ballooning DESACTIVADO. Con nodos de 2 GB el kubelet calcula su
    # capacidad al arrancar y no se entera si el hipervisor le quita RAM:
    # sigue programando pods hasta que entra el OOM killer.
    floating = 0
  }

  disk {
    datastore_id = var.datastore_id
    interface    = "scsi0"
    size         = each.value.disk
    discard      = "on"
    ssd          = true
  }

  network_device {
    bridge = "vmbr0"
  }

  initialization {
    # Explícitos para no chocar con el drive cloud-init que la plantilla 9000
    # ya trae montado en ide2.
    datastore_id = var.datastore_id
    interface    = "ide2"

    ip_config {
      ipv4 {
        address = "${each.value.ip}/24"
        gateway = var.gateway
      }
    }

    # Con IP estática cloud-init no hereda resolver de DHCP: sin esto los
    # nodos arrancan sin DNS y el primer `apt update` de la Fase 4 falla.
    dns {
      servers = var.dns_servers
    }

    user_account {
      username = "debian"
      keys     = [var.ssh_public_key]
    }
  }

  lifecycle {
    # El provider no puede leer de vuelta la contraseña/llaves de cloud-init,
    # así que sin esto cada `plan` propone recrear las VMs.
    ignore_changes = [initialization[0].user_account]
  }
}
