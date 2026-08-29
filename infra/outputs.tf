# Leído del recurso, no de locals: si cloud-init no aplica la IP configurada,
# esto lo destapa en vez de repetir la que queríamos.
output "node_ips" {
  description = "IPv4 reportadas por el guest agent de cada nodo."
  value = {
    for k, vm in proxmox_virtual_environment_vm.k8s :
    k => try(
      [for addr in flatten(vm.ipv4_addresses) : addr if addr != "127.0.0.1"][0],
      null
    )
  }
}

output "node_ids" {
  description = "VMID asignado a cada nodo."
  value       = { for k, vm in proxmox_virtual_environment_vm.k8s : k => vm.vm_id }
}
