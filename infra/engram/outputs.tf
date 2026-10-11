output "ip" {
  description = "IPv4 reportada por el guest agent."
  value = try(
    [for addr in flatten(proxmox_virtual_environment_vm.engram.ipv4_addresses) : addr if addr != "127.0.0.1"][0],
    null
  )
}
