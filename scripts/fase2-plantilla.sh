#!/usr/bin/env bash
#
# Fase 2 — Plantilla cloud-init Debian 13 (VMID 9000) para Proxmox VE.
#
# Se ejecuta EN EL HOST Proxmox, como root:
#   ./fase2-plantilla.sh build    # descarga imagen, inyecta guest agent, crea plantilla 9000
#   ./fase2-plantilla.sh test     # clona a 199, arranca y cronometra hasta que responda SSH
#   ./fase2-plantilla.sh clean    # destruye la VM 199 de prueba
#
# El porqué de cada decisión está en docs/BITACORA.md; el procedimiento manual equivalente,
# en docs/roadmap-homelab-k8s.md (Fase 2).

set -euo pipefail

# --- Configuración ------------------------------------------------------------------------

VMID="${VMID:-9000}"
VMNAME="${VMNAME:-debian13-cloudinit}"
STORAGE="${STORAGE:-local-lvm}"          # instalación ext4 + LVM-thin; sería local-zfs con ZFS
BRIDGE="${BRIDGE:-vmbr0}"
CIUSER="${CIUSER:-debian}"
PUBKEY="${PUBKEY:-/root/homelab.pub}"
MEMORY="${MEMORY:-2048}"
CORES="${CORES:-2}"

ISO_DIR="${ISO_DIR:-/var/lib/vz/template/iso}"
IMG_BASE="debian-13-genericcloud-amd64.qcow2"
IMG_URL="https://cloud.debian.org/images/cloud/trixie/latest/${IMG_BASE}"
SUMS_URL="https://cloud.debian.org/images/cloud/trixie/latest/SHA512SUMS"
IMG_WORK="debian-13-work.qcow2"          # copia sobre la que trabaja virt-customize

# Parámetros de la VM de prueba
TEST_VMID="${TEST_VMID:-199}"
TEST_IP="${TEST_IP:-192.168.1.99/24}"
TEST_GW="${TEST_GW:-192.168.1.1}"
TEST_DISK_GROW="${TEST_DISK_GROW:-+18G}"
TEST_TIMEOUT="${TEST_TIMEOUT:-120}"

# --- Utilidades ---------------------------------------------------------------------------

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

vm_exists() { qm status "$1" &>/dev/null; }

preflight() {
  [[ $EUID -eq 0 ]] || die "hay que ejecutarlo como root en el host Proxmox"
  command -v qm >/dev/null            || die "'qm' no encontrado — ¿esto es un host Proxmox?"
  command -v virt-customize >/dev/null || die "falta libguestfs-tools: apt install libguestfs-tools"
  pvesm status | awk 'NR>1 {print $1}' | grep -qx "$STORAGE" \
    || die "el almacenamiento '$STORAGE' no existe. Disponibles: $(pvesm status | awk 'NR>1 {print $1}' | tr '\n' ' ')"
  [[ -f $PUBKEY ]] || die "no está la llave pública en $PUBKEY (cópiala con scp desde la máquina de trabajo)"
}

# --- build --------------------------------------------------------------------------------

fetch_image() {
  mkdir -p "$ISO_DIR"
  cd "$ISO_DIR"

  if [[ -f $IMG_BASE ]]; then
    log "imagen ya descargada: $ISO_DIR/$IMG_BASE"
  else
    log "descargando $IMG_BASE"
    wget -q --show-progress "$IMG_URL"
  fi

  log "verificando checksum SHA512"
  wget -qO SHA512SUMS.tmp "$SUMS_URL"
  if grep " ${IMG_BASE}\$" SHA512SUMS.tmp | sha512sum -c --status -; then
    log "checksum correcto"
    rm -f SHA512SUMS.tmp
  else
    rm -f SHA512SUMS.tmp
    die "checksum incorrecto en $IMG_BASE — bórrala y vuelve a ejecutar"
  fi
}

customize_image() {
  cd "$ISO_DIR"
  # virt-customize modifica la imagen in-place: se trabaja sobre una copia para que el script
  # pueda re-ejecutarse sin volver a descargar ni acumular capas de cambios.
  log "copiando imagen base a $IMG_WORK"
  cp -f "$IMG_BASE" "$IMG_WORK"

  log "inyectando qemu-guest-agent y cloud-init"
  virt-customize -a "$IMG_WORK" \
    --install qemu-guest-agent,cloud-init \
    --run-command 'systemctl enable qemu-guest-agent' \
    --truncate /etc/machine-id
  # --truncate /etc/machine-id: sin esto todos los clones comparten machine-id y el DHCP les
  # entrega la misma IP.
}

create_template() {
  if vm_exists "$VMID"; then
    die "el VMID $VMID ya existe. Para rehacer la plantilla: qm destroy $VMID"
  fi

  log "creando VM $VMID ($VMNAME)"
  qm create "$VMID" \
    --name "$VMNAME" \
    --memory "$MEMORY" --cores "$CORES" --cpu host \
    --net0 "virtio,bridge=$BRIDGE" \
    --scsihw virtio-scsi-single \
    --agent enabled=1 \
    --ostype l26

  log "importando disco desde $IMG_WORK"
  qm disk import "$VMID" "$ISO_DIR/$IMG_WORK" "$STORAGE"

  log "conectando discos y configurando arranque"
  qm set "$VMID" --scsi0 "$STORAGE:vm-$VMID-disk-0,discard=on,ssd=1"
  qm set "$VMID" --ide2 "$STORAGE:cloudinit"
  qm set "$VMID" --boot order=scsi0
  qm set "$VMID" --serial0 socket --vga serial0   # las imágenes cloud sólo hablan por serie
  qm set "$VMID" --ciuser "$CIUSER" --sshkeys "$PUBKEY"

  log "convirtiendo $VMID en plantilla"
  qm template "$VMID"

  log "plantilla lista. Siguiente: $0 test"
}

cmd_build() {
  preflight
  fetch_image
  customize_image
  create_template
}

# --- test ---------------------------------------------------------------------------------

cmd_test() {
  preflight
  vm_exists "$VMID" || die "no existe la plantilla $VMID — ejecuta primero: $0 build"
  vm_exists "$TEST_VMID" && die "el VMID $TEST_VMID ya está ocupado. Límpialo con: $0 clean"

  log "clonando $VMID → $TEST_VMID"
  qm clone "$VMID" "$TEST_VMID" --name test-vm --full

  qm set "$TEST_VMID" --ipconfig0 "ip=$TEST_IP,gw=$TEST_GW"
  qm resize "$TEST_VMID" scsi0 "$TEST_DISK_GROW"

  local start elapsed ip
  start=$(date +%s)
  log "arrancando $TEST_VMID"
  qm start "$TEST_VMID"

  log "esperando al guest agent (timeout ${TEST_TIMEOUT}s)"
  while :; do
    elapsed=$(( $(date +%s) - start ))
    (( elapsed < TEST_TIMEOUT )) || die "el guest agent no respondió en ${TEST_TIMEOUT}s"
    ip=$(qm guest cmd "$TEST_VMID" network-get-interfaces 2>/dev/null \
         | grep -oE '"ip-address" *: *"[0-9.]+"' | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' \
         | grep -v '^127\.' | head -1) || true
    [[ -n ${ip:-} ]] && break
    sleep 3
  done

  log "guest agent respondiendo tras ${elapsed}s — IP: $ip"
  (( elapsed <= 60 )) && log "checkpoint Fase 2 CUMPLIDO (< 60s)" \
                      || warn "por encima de los 60s del checkpoint"

  echo
  log "verifica desde la máquina de trabajo:"
  echo "    ssh -i ~/.ssh/homelab $CIUSER@${TEST_IP%%/*} 'systemctl is-active qemu-guest-agent'"
  log "y luego limpia con: $0 clean"
}

# --- clean --------------------------------------------------------------------------------

cmd_clean() {
  vm_exists "$TEST_VMID" || { log "no hay VM $TEST_VMID que limpiar"; return 0; }
  log "destruyendo la VM de prueba $TEST_VMID"
  qm stop "$TEST_VMID" || true
  sleep 2
  qm destroy "$TEST_VMID"
  log "limpio"
}

# --- main ---------------------------------------------------------------------------------

case "${1:-build}" in
  build) cmd_build ;;
  test)  cmd_test  ;;
  clean) cmd_clean ;;
  *)     die "uso: $0 [build|test|clean]" ;;
esac
