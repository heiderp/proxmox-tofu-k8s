# Mismos nombres que infra/variables.tf: infra/engram/terraform.tfvars es un
# symlink a ../terraform.tfvars y comparten token y llave.

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
  type    = string
  default = "pve"
}

variable "datastore_id" {
  description = "Almacenamiento tipo directorio sobre el root FS, fuera del thin pool."
  type        = string
  default     = "local"
}

variable "template_vm_id" {
  type    = number
  default = 9000
}

variable "ip" {
  type    = string
  default = "192.168.1.54"
}

variable "gateway" {
  type    = string
  default = "192.168.1.1"
}

variable "dns_servers" {
  type    = list(string)
  default = ["192.168.1.1"]
}

variable "ssh_public_key" {
  description = "Contenido de ~/.ssh/homelab.pub, autorizada al usuario 'debian'."
  type        = string
}

variable "ssh_private_key_path" {
  type    = string
  default = "~/.ssh/homelab"
}
