variable "pve_endpoint" {
  description = "URL de la API de Proxmox, con barra final."
  type        = string
  default     = "https://192.168.1.20:8006/"
}

variable "pve_api_token" {
  description = "Token de API con formato usuario@reino!nombre=uuid."
  type        = string
  sensitive   = true
}

variable "pve_node" {
  description = "Nombre del nodo Proxmox. Host sin cluster, se llama 'pve'."
  type        = string
  default     = "pve"
}

variable "datastore_id" {
  description = "Almacenamiento para discos y drive cloud-init."
  type        = string
  default     = "local-lvm"
}

variable "template_vm_id" {
  description = "VMID de la plantilla cloud-init creada en la Fase 2."
  type        = number
  default     = 9000
}

variable "gateway" {
  type    = string
  default = "192.168.1.1"
}

variable "dns_servers" {
  description = "Resolvers para cloud-init. Las VMs van con IP estática."
  type        = list(string)
  default     = ["192.168.1.1"]
}

variable "ssh_public_key" {
  description = "Contenido de ~/.ssh/homelab.pub, autorizada al usuario 'debian'."
  type        = string
}

variable "ssh_private_key_path" {
  description = "Llave privada que el provider usa para el SSH al nodo Proxmox."
  type        = string
  default     = "~/.ssh/homelab"
}
