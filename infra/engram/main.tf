terraform {
  required_version = ">= 1.9"

  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.111"
    }
  }
}

# Root module aparte del cluster, con su propio state: `tofu destroy` en infra/
# es la forma de probar el bootstrap del cluster (CLAUDE.md §8) y no debe
# llevarse por delante la memoria. Mismo cifrado (TF_ENCRYPTION de infra/.envrc).
provider "proxmox" {
  endpoint  = var.pve_endpoint
  api_token = var.pve_api_token
  insecure  = true

  ssh {
    agent       = false
    username    = "root"
    private_key = file(var.ssh_private_key_path)
  }
}

resource "proxmox_virtual_environment_vm" "engram" {
  name      = "engram"
  vm_id     = 104
  node_name = var.pve_node
  tags      = ["engram", "tofu"]

  stop_on_destroy = true
  on_boot         = true

  clone {
    vm_id = var.template_vm_id
    full  = true
    # Fuera del thin pool: si local-lvm se llena (escenario 7 de la Fase 9)
    # corrompe las VMs que tenga dentro. La memoria no debe caer con el cluster.
    datastore_id = var.datastore_id
  }

  agent {
    enabled = true
    timeout = "5m"
  }

  cpu {
    cores = 1
    type  = "host"
  }

  memory {
    # Postgres + engram cloud + Caddy + zerotier-one. Sin ballooning, por la
    # misma razón que los nodos: nadie dentro se entera si el host le quita RAM.
    dedicated = 1024
    floating  = 0
  }

  disk {
    datastore_id = var.datastore_id
    interface    = "scsi0"
    size         = 8
    # El provider ignora file_format en un clone: el disco sale raw igualmente,
    # y declarar qcow2 deja un diff perpetuo. Raw en almacenamiento de
    # directorio no admite snapshots; la protección es el backup diario.
    file_format = "raw"
    discard     = "on"
    ssd         = true
  }

  network_device {
    bridge = "vmbr0"
  }

  initialization {
    datastore_id = var.datastore_id
    interface    = "ide2"

    ip_config {
      ipv4 {
        address = "${var.ip}/24"
        gateway = var.gateway
      }
    }

    dns {
      servers = var.dns_servers
    }

    user_account {
      username = "debian"
      keys     = [var.ssh_public_key]
    }
  }

  lifecycle {
    ignore_changes = [initialization[0].user_account]
  }
}
