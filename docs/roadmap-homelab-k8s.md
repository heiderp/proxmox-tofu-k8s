# Roadmap: Homelab Kubernetes sobre Proxmox con GitOps

**Objetivo final:** poder destruir todo el cluster y reconstruirlo desde Git en menos de 30 minutos, con aplicaciones expuestas a internet vía Cloudflare Tunnel, y haber practicado lo suficiente para aprobar el CKA.

**Tiempo estimado total:** 8-12 semanas a ritmo de fin de semana.

> **Nota sobre versiones:** los comandos usan versiones concretas para que sean copiables. Verifica siempre la versión actual en la documentación oficial antes de ejecutar — el ecosistema se mueve rápido.

---

## Índice

| Fase | Qué construyes | Tiempo |
|---|---|---|
| 0 | Verificación de hardware | 2-3 h |
| 1 | Proxmox VE instalado y endurecido | 3-4 h |
| 2 | Plantilla cloud-init reutilizable | 2 h |
| 3 | OpenTofu creando VMs | 4-6 h |
| 4 | Cluster kubeadm funcionando | 6-8 h |
| 5 | ArgoCD y el loop de GitOps | 8-10 h |
| 6 | Plataforma: red, TLS, secretos | 8-10 h |
| 7 | Exposición pública con Cloudflare | 3-4 h |
| 8 | Observabilidad y backups | 6-8 h |
| 9 | Entrenamiento CKA | continuo |
| 10 | (Opcional) Cluster API / Talos | 10+ h |

---

## Topología de este roadmap

| Nodo | Rol | vCPU | RAM | Disco | IP |
|---|---|---|---|---|---|
| `k8s-cp-1` | control plane | 2 | **4096 MB** | 40 GB | 192.168.1.51 |
| `k8s-wk-1` | worker | 2 | **2048 MB** | 30 GB | 192.168.1.52 |
| `k8s-wk-2` | worker | 2 | **2048 MB** | 30 GB | 192.168.1.53 |

**Total asignado a VMs: 8 GB.** Suma ~2-3 GB para Proxmox y llegas a un host de 12-16 GB.

> Si instalaste con ZFS, limita el ARC a 2 GB (ver Fase 1.2) o el hipervisor se comerá la memoria que necesitan las VMs.

### Presupuesto de memoria — dónde va cada MB

Esto no es informativo, es **la restricción que gobierna todas las decisiones del documento**. Con 2 GB por worker el margen es real pero estrecho, y el modo de fallo es traicionero.

**Control plane (4096 MB):**

| Componente | Aprox. |
|---|---|
| Debian + systemd + containerd + kubelet | 430 MB |
| kube-apiserver | 500-800 MB |
| etcd | 150-400 MB |
| controller-manager + scheduler | 150 MB |
| Cilium agent (slim) + CoreDNS + kube-proxy | 300 MB |
| **Ocupado** | **~1.6-2.1 GB** |
| **Libre** | **~2.0-2.4 GB** |

**Cada worker (2048 MB):**

| Componente | Aprox. |
|---|---|
| Debian + systemd + containerd + kubelet | 430 MB |
| Cilium agent (slim) + kube-proxy | 250 MB |
| Reservas del kubelet (ver 4.4b) | 300 MB |
| **Ocupado** | **~980 MB** |
| **Disponible para tus pods** | **~1.0 GB por worker** |

### Consecuencias que debes aceptar de entrada

| Puedes | No puedes (sin ampliar RAM) |
|---|---|
| Cluster kubeadm completo con NetworkPolicies | `kube-prometheus-stack` estándar |
| ArgoCD (con límites ajustados, ver 5.1) | Loki |
| MetalLB, cert-manager, Gateway API | Longhorn / Rook-Ceph |
| Cloudflare Tunnel + apps pequeñas | Segundo cluster simultáneo (Fase 10) |
| Todos los escenarios del CKA | Elasticsearch, Keycloak, GitLab |

Para observabilidad se usa **VictoriaMetrics en vez de Prometheus** (Fase 8.1) — no es un downgrade, es la decisión correcta en este presupuesto.

### El fallo que vas a encontrar — reconócelo rápido

Cuando llegues al límite, el OOM killer mata procesos y **el síntoma parece de red**: `kubectl` con timeouts intermitentes, nodos parpadeando entre `Ready` y `NotReady`, pods atascados en `Terminating`. Vas a depurar Cilium durante horas cuando el problema es memoria.

Antes de sospechar de cualquier otra cosa, ejecuta siempre:

```bash
dmesg -T | grep -i "killed process"
kubectl get pods -A | grep -i OOMKilled
kubectl top nodes    # requiere metrics-server
free -h              # en el nodo afectado
```

---

# Fase 0 — Verificación de hardware

No te saltes esto. Descubrir a mitad de camino que el CPU no soporta las imágenes modernas es frustrante.

### 0.1 Verificar virtualización por hardware

Arranca cualquier Linux live (Ubuntu live USB sirve) y ejecuta:

```bash
# Debe devolver un número mayor a 0
egrep -c '(vmx|svm)' /proc/cpuinfo

# Ver el modelo exacto
lscpu | grep -E 'Model name|Virtualization'
```

Si devuelve `0`, entra al BIOS/UEFI y habilita **Intel VT-x** o **AMD-V**. Suele estar en *Advanced → CPU Configuration*. Habilita también **VT-d / AMD-Vi (IOMMU)** si existe.

### 0.2 Verificar nivel de microarquitectura

Este es el que sorprende a la gente. Muchas imágenes de contenedor y distribuciones modernas requieren `x86-64-v2` como mínimo:

```bash
/lib/x86_64-linux-gnu/ld-linux-x86-64.so.2 --help | grep supported
```

Debe listar al menos `x86-64-v2 (supported)`. Si tu CPU es anterior a ~2009 (pre-Nehalem / pre-Bulldozer) vas a tener problemas serios. En ese caso, plantéate si el proyecto vale la pena con ese equipo.

### 0.3 Salud de los discos

```bash
sudo apt install smartmontools -y
sudo smartctl -a /dev/sda | grep -E 'Reallocated|Power_On_Hours|Wear_Leveling|Media_Wearout'
```

**Esto es crítico:** etcd es extremadamente sensible a la latencia de escritura con `fsync`. Un disco mecánico o un SSD SATA barato y gastado te va a dar timeouts de elección de líder constantemente, y vas a perder días depurando un problema que no es de Kubernetes.

Prueba la latencia real:

```bash
sudo apt install fio -y
sudo fio --name=etcd-test --rw=write --ioengine=sync --fdatasync=1 \
  --size=200m --bs=2300 --filename=/tmp/testfile
```

Mira el percentil 99 de `fsync/fdatasync`. **Debe estar por debajo de 10 ms.** Si está en 50-100 ms, consigue un SSD/NVMe aunque sea de 250 GB solo para los nodos de control plane.

### 0.4 Plan de red

Anota antes de empezar:

- Rango de tu LAN (ej. `192.168.1.0/24`)
- IP fija para Proxmox (ej. `192.168.1.10`)
- **Rango reservado para las VMs** (ej. `192.168.1.50-59`) — configura una exclusión en el DHCP de tu router
- **Rango reservado para MetalLB** (ej. `192.168.1.200-220`) — también fuera del DHCP

### 0.5 Medir consumo

Con un medidor de enchufe, anota el consumo en reposo. Multiplica por 8760 horas y por tu tarifa eléctrica. Si el número te incomoda, mejor saberlo ahora.

**Checkpoint Fase 0:** tienes VT-x activo, sabes que soportas `x86-64-v2`, tienes un disco con fsync < 10 ms y un plan de IPs escrito.

---

# Fase 1 — Instalar Proxmox VE

### 1.1 Crear el medio de instalación

Descarga el ISO de `proxmox.com/en/downloads` (Proxmox VE 9.x). Escríbelo con:

- **Linux/macOS:** `dd if=proxmox-ve_9.x.iso of=/dev/sdX bs=1M status=progress conv=fsync`
- **Windows:** Rufus en modo **DD**, no ISO
- O **Ventoy**, que es más cómodo si vas a probar varias ISOs

### 1.2 Instalación

Durante el instalador:

**Filesystem:**
- `ext4` con LVM-thin → menos RAM, más simple. **Recomendado si tienes ≤ 32 GB.**
- `zfs (RAID1)` → snapshots instantáneos, checksums, compresión. Necesita ~1 GB de RAM por TB. **Con el presupuesto de este roadmap (8 GB en VMs), elige ext4/LVM-thin.** El ARC de ZFS competiría directamente con tus nodos.

Si eliges ZFS, limita el ARC después de instalar:

```bash
echo "options zfs zfs_arc_max=2147483648" > /etc/modprobe.d/zfs.conf  # 2 GB — no más, con 8 GB comprometidos en VMs
update-initramfs -u -k all
```

**Red:** IP estática, no DHCP. Hostname en formato FQDN (`pve.homelab.local`).

### 1.3 Post-instalación obligatoria

Entra por SSH como root:

```bash
# Ver el codename de Debian de tu versión de PVE
lsb_release -cs   # trixie en PVE 9, bookworm en PVE 8
```

**Desactivar el repo enterprise y activar el gratuito.** En PVE 9 los repos usan formato deb822 (`.sources`):

```bash
# Desactivar enterprise
sed -i 's/^Components:/# Components:/' /etc/apt/sources.list.d/pve-enterprise.sources 2>/dev/null

# Añadir no-subscription
cat > /etc/apt/sources.list.d/pve-no-subscription.sources <<'EOF'
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: trixie
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF

apt update && apt full-upgrade -y
```

> En PVE 8 el formato es el clásico: comenta la línea en `/etc/apt/sources.list.d/pve-enterprise.list` y añade
> `deb http://download.proxmox.com/debian/pve bookworm pve-no-subscription` a `/etc/apt/sources.list`.

**Herramientas útiles:**

```bash
apt install -y vim git curl htop libguestfs-tools
```

`libguestfs-tools` lo vas a necesitar en la Fase 2.

**Quitar el aviso de suscripción** (opcional, cosmético): busca el script post-install de la comunidad `community-scripts/ProxmoxVE`, pero léelo antes de ejecutarlo — nunca corras a ciegas un script con `curl | bash`.

### 1.4 Crear el usuario y token para OpenTofu

Esto es lo que le permitirá a Tofu crear VMs sin usar root:

```bash
# Crear el usuario
pveum user add tofu@pve

# Crear un rol con los permisos mínimos necesarios
pveum role add Provisioner -privs "VM.Allocate VM.Clone VM.Config.CDROM \
VM.Config.CPU VM.Config.Cloudinit VM.Config.Disk VM.Config.HWType \
VM.Config.Memory VM.Config.Network VM.Config.Options VM.Monitor \
VM.Audit VM.PowerMgmt Datastore.AllocateSpace Datastore.Audit \
Sys.Audit Sys.Console Sys.Modify SDN.Use"

# Asignar el rol en toda la jerarquía
pveum aclmod / -user tofu@pve -role Provisioner

# Generar el token (privsep=0 hereda los permisos del usuario)
pveum user token add tofu@pve tofu-token --privsep 0
```

**Guarda el valor del token que imprime. No se muestra otra vez.** Formato final: `tofu@pve!tofu-token=xxxxxxxx-xxxx-...`

### 1.5 Snapshot mental del estado

Verifica que puedes:
- Entrar a `https://192.168.1.10:8006`
- Hacer SSH como root
- `pveversion` devuelve la versión

**Checkpoint Fase 1:** Proxmox instalado, actualizado, con repos correctos y un token de API guardado en tu gestor de contraseñas.

---

# Fase 2 — Plantilla cloud-init

Esta plantilla es la base de todas las VMs. Hacerla bien ahorra horas después.

### 2.1 Descargar una imagen cloud

```bash
cd /var/lib/vz/template/iso
wget https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-amd64.qcow2
```

> Alternativa Ubuntu: `https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img`

### 2.2 Inyectar el guest agent en la imagen

Las imágenes cloud no traen `qemu-guest-agent`, y sin él Proxmox no ve las IPs de las VMs ni puede apagarlas limpiamente. Se instala **antes** de crear la plantilla:

```bash
virt-customize -a debian-13-genericcloud-amd64.qcow2 \
  --install qemu-guest-agent,cloud-init \
  --run-command 'systemctl enable qemu-guest-agent' \
  --truncate /etc/machine-id
```

El `--truncate /etc/machine-id` es importante: si no lo haces, todos los clones comparten el mismo machine-id y el DHCP les da la misma IP.

### 2.3 Crear la plantilla

```bash
VMID=9000

qm create $VMID \
  --name debian13-cloudinit \
  --memory 2048 --cores 2 --cpu host \
  --net0 virtio,bridge=vmbr0 \
  --scsihw virtio-scsi-single \
  --agent enabled=1 \
  --ostype l26

# Importar el disco (usa 'local-lvm' o 'local-zfs' según tu instalación)
qm disk import $VMID debian-13-genericcloud-amd64.qcow2 local-lvm

# Conectar el disco importado
qm set $VMID --scsi0 local-lvm:vm-$VMID-disk-0,discard=on,ssd=1

# Disco de cloud-init
qm set $VMID --ide2 local-lvm:cloudinit

# Arrancar desde el disco
qm set $VMID --boot order=scsi0

# Consola serie (necesaria en imágenes cloud)
qm set $VMID --serial0 socket --vga serial0

# Usuario y llave SSH por defecto
qm set $VMID --ciuser debian --sshkeys ~/.ssh/id_ed25519.pub

# Convertir en plantilla
qm template $VMID
```

> Si no tienes llave SSH aún: `ssh-keygen -t ed25519 -C "homelab"` en tu máquina de trabajo, y copia la pública al host de Proxmox.

### 2.4 Probar la plantilla

```bash
qm clone 9000 199 --name test-vm --full
qm set 199 --ipconfig0 ip=192.168.1.99/24,gw=192.168.1.1
qm resize 199 scsi0 +18G
qm start 199
```

Espera un minuto y verifica: `ssh debian@192.168.1.99`. Si entra sin contraseña, la plantilla está bien.

```bash
qm stop 199 && qm destroy 199
```

**Checkpoint Fase 2:** puedes clonar una VM funcional con SSH y guest agent en menos de 60 segundos.

---

# Fase 3 — OpenTofu

### 3.1 Instalar OpenTofu en tu máquina de trabajo

```bash
curl --proto '=https' --tlsv1.2 -fsSL https://get.opentofu.org/install-opentofu.sh -o install-opentofu.sh
chmod +x install-opentofu.sh
./install-opentofu.sh --install-method deb   # o --install-method standalone
rm install-opentofu.sh

tofu version
```

### 3.2 Estructura del repositorio

Crea el repo que va a ser la fuente de verdad de todo el proyecto:

```
homelab/
├── infra/                    # OpenTofu: VMs
│   ├── main.tf
│   ├── variables.tf
│   ├── outputs.tf
│   ├── terraform.tfvars      # <-- en .gitignore
│   └── .gitignore
├── ansible/                  # Configuración del SO y bootstrap de k8s
│   ├── inventory.yml
│   ├── roles/
│   └── playbooks/
└── gitops/                   # Todo lo que vive dentro de Kubernetes
    ├── bootstrap/
    ├── infrastructure/
    └── apps/
```

### 3.3 `infra/main.tf`

```hcl
terraform {
  required_version = ">= 1.9"
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.66"   # verifica la última en el registry
    }
  }
}

provider "proxmox" {
  endpoint  = var.pve_endpoint          # https://192.168.1.10:8006/
  api_token = var.pve_api_token
  insecure  = true                      # cert autofirmado
  ssh {
    agent    = true
    username = "root"
  }
}

locals {
  nodes = {
    "k8s-cp-1" = { vmid = 101, ip = "192.168.1.51", cores = 2, memory = 4096, disk = 40 }
    "k8s-wk-1" = { vmid = 102, ip = "192.168.1.52", cores = 2, memory = 2048, disk = 30 }
    "k8s-wk-2" = { vmid = 103, ip = "192.168.1.53", cores = 2, memory = 2048, disk = 30 }
  }
}

resource "proxmox_virtual_environment_vm" "k8s" {
  for_each = local.nodes

  name      = each.key
  vm_id     = each.value.vmid
  node_name = var.pve_node
  tags      = ["kubernetes", "tofu"]

  clone {
    vm_id = 9000
    full  = true
  }

  agent { enabled = true }

  cpu {
    cores = each.value.cores
    type  = "host"
  }

  memory {
    dedicated = each.value.memory
    floating  = 0              # 0 = ballooning DESACTIVADO. Ver nota abajo.
  }

  disk {
    datastore_id = "local-lvm"
    interface    = "scsi0"
    size         = each.value.disk
    discard      = "on"
    ssd          = true
  }

  network_device {
    bridge = "vmbr0"
  }

  initialization {
    ip_config {
      ipv4 {
        address = "${each.value.ip}/24"
        gateway = var.gateway
      }
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
```

> **Por qué `floating = 0`:** el ballooning de Proxmox permite que el hipervisor reclame RAM de una VM cuando hay presión. Suena bien, pero con nodos de 2 GB es catastrófico: el kubelet calcula su capacidad al arrancar y no se entera de que le quitaron memoria, así que sigue programando pods hasta que el OOM killer entra en acción. **Memoria fija y punto.**

### 3.4 `infra/variables.tf`

```hcl
variable "pve_endpoint"   { type = string }
variable "pve_api_token"  { type = string, sensitive = true }
variable "pve_node"       { type = string, default = "pve" }
variable "gateway"        { type = string, default = "192.168.1.1" }
variable "ssh_public_key" { type = string }
```

### 3.5 Cifrado del state

Tu state va a contener el token de la API de Proxmox. **No lo subas a Git sin cifrar.** OpenTofu lo cifra del lado del cliente:

```bash
# La forma más limpia: variable de entorno, no en el código
export TF_ENCRYPTION='
key_provider "pbkdf2" "homelab" {
  passphrase = "una-frase-larga-y-aleatoria-que-guardas-en-tu-gestor"
}
method "aes_gcm" "default" {
  keys = key_provider.pbkdf2.homelab
}
state {
  method = method.aes_gcm.default
  enforced = true
}
plan {
  method = method.aes_gcm.default
  enforced = true
}
'
```

Ponlo en un archivo `.envrc` con `direnv` (y añade `.envrc` al `.gitignore`).

### 3.6 El primer apply

```bash
cd infra/
tofu init
tofu plan
tofu apply
```

Deberías tener 3 VMs corriendo en 2-3 minutos.

**Ahora la prueba que importa:**

```bash
tofu destroy
tofu apply
```

Si las VMs vuelven idénticas, has entendido el punto de la IaC.

### 3.7 `outputs.tf` para alimentar Ansible

```hcl
output "node_ips" {
  value = { for k, v in local.nodes : k => v.ip }
}
```

**Checkpoint Fase 3:** `tofu apply` levanta 3 VMs accesibles por SSH desde cero, y todo el código está en Git salvo secretos.

---

# Fase 4 — Cluster Kubernetes con kubeadm

Aquí es donde aprendes de verdad. Resiste la tentación de usar un script mágico.

### 4.1 Preparar Ansible

```bash
pip install --user ansible
```

`ansible/inventory.yml`:

```yaml
all:
  vars:
    ansible_user: debian
    ansible_python_interpreter: /usr/bin/python3
  children:
    control_plane:
      hosts:
        k8s-cp-1: { ansible_host: 192.168.1.51 }
    workers:
      hosts:
        k8s-wk-1: { ansible_host: 192.168.1.52 }
        k8s-wk-2: { ansible_host: 192.168.1.53 }
```

Verifica conectividad: `ansible -i inventory.yml all -m ping`

### 4.2 Prerequisitos en todos los nodos

Estos pasos son exactamente lo que el CKA espera que sepas. Escríbelos como rol de Ansible, pero **ejecútalos a mano al menos una vez** para entenderlos.

```bash
# 1. Desactivar swap (kubelet se niega a arrancar con swap activo)
swapoff -a
sed -i '/ swap / s/^/#/' /etc/fstab

# 2. Módulos de kernel
cat > /etc/modules-load.d/k8s.conf <<EOF
overlay
br_netfilter
EOF
modprobe overlay && modprobe br_netfilter

# 3. Parámetros sysctl (sin esto, el tráfico entre pods no funciona)
cat > /etc/sysctl.d/k8s.conf <<EOF
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sysctl --system

# 4. Sincronización de reloj (etcd es intolerante con la deriva)
apt install -y chrony
systemctl enable --now chrony
```

### 4.3 Container runtime (containerd)

```bash
apt install -y containerd

mkdir -p /etc/containerd
containerd config default > /etc/containerd/config.toml

# EL paso que todo el mundo olvida: el cgroup driver debe ser systemd
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

systemctl restart containerd
systemctl enable containerd
```

> Si `SystemdCgroup` queda en `false`, el cluster arranca pero los nodos se vuelven inestables bajo carga. Es un clásico de troubleshooting.

### 4.4 Instalar kubeadm, kubelet, kubectl

```bash
K8S_VERSION="v1.34"   # ajusta a la versión del examen que vas a rendir

apt install -y apt-transport-https ca-certificates curl gpg
mkdir -p /etc/apt/keyrings

curl -fsSL https://pkgs.k8s.io/core:/stable:/${K8S_VERSION}/deb/Release.key \
  | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] \
https://pkgs.k8s.io/core:/stable:/${K8S_VERSION}/deb/ /" \
  > /etc/apt/sources.list.d/kubernetes.list

apt update
apt install -y kubelet kubeadm kubectl
apt-mark hold kubelet kubeadm kubectl   # evita upgrades accidentales
```

### 4.4b Reservas del kubelet — obligatorio con 2 GB

Sin esto, el kernel decide qué matar cuando falta memoria, y suele elegir mal. Con reservas, el **kubelet** desaloja pods de forma ordenada antes de llegar a ese punto.

En cada nodo, edita `/var/lib/kubelet/config.yaml` y añade:

```yaml
# --- workers (2 GB) ---
systemReserved:
  memory: "200Mi"
  cpu: "100m"
kubeReserved:
  memory: "100Mi"
  cpu: "100m"
evictionHard:
  memory.available: "150Mi"
  nodefs.available: "10%"
evictionMinimumReclaim:
  memory.available: "100Mi"
```

En el control plane, más generoso porque el apiserver es volátil:

```yaml
# --- control plane (4 GB) ---
systemReserved:
  memory: "300Mi"
  cpu: "200m"
kubeReserved:
  memory: "400Mi"
  cpu: "200m"
evictionHard:
  memory.available: "300Mi"
```

Aplica y verifica:

```bash
systemctl restart kubelet

# La capacidad "allocatable" debe ser menor que la "capacity"
kubectl describe node k8s-wk-1 | grep -A6 "Allocatable"
```

Deberías ver algo cercano a **1.6 GB allocatable** en un worker de 2 GB. Esa es la cifra real con la que trabajas.

> **Nota para el examen:** en el CKA nunca vas a tocar estas reservas, y `swapoff -a` sigue siendo paso obligatorio de instalación. Esto es afinación operativa de tu homelab, no material evaluable — pero entender la diferencia entre `capacity` y `allocatable` sí lo es.

### 4.5 Inicializar el control plane

En `k8s-cp-1`:

```bash
kubeadm init \
  --pod-network-cidr=10.244.0.0/16 \
  --apiserver-advertise-address=192.168.1.51 \
  --control-plane-endpoint=192.168.1.51:6443
```

Guarda el comando `kubeadm join` que imprime al final. Si lo pierdes:

```bash
kubeadm token create --print-join-command
```

Configura kubectl:

```bash
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config
```

**Explórate el resultado** — esto es material de examen:

```bash
ls /etc/kubernetes/manifests/       # static pods del control plane
ls /etc/kubernetes/pki/             # certificados
kubeadm certs check-expiration      # caducan al año
systemctl status kubelet
journalctl -u kubelet -f
```

### 4.6 Instalar el CNI (Cilium)

Los nodos estarán en `NotReady` hasta que instales una red de pods.

```bash
CILIUM_CLI_VERSION=$(curl -s https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt)
curl -L --fail --remote-name-all \
  https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-linux-amd64.tar.gz
tar xzvf cilium-linux-amd64.tar.gz -C /usr/local/bin
rm cilium-linux-amd64.tar.gz
```

**Instalación en modo slim** — ajustada al presupuesto de 2 GB por worker:

```bash
cilium install \
  --set ipam.operator.clusterPoolIPv4PodCIDRList="10.244.0.0/16" \
  --set hubble.enabled=false \
  --set hubble.relay.enabled=false \
  --set hubble.ui.enabled=false \
  --set operator.replicas=1 \
  --set resources.limits.memory=300Mi \
  --set resources.requests.memory=150Mi

cilium status --wait
```

Desactivar Hubble ahorra ~200 MB por nodo. Lo puedes reactivar el día que amplíes RAM:

```bash
cilium hubble enable --ui
```

**Por qué Cilium y no Flannel:** Flannel consume ~50 MB frente a los ~250 MB de Cilium slim, y es tentador. Pero **Flannel no implementa NetworkPolicy en absoluto** — los objetos se crean y se ignoran silenciosamente. Como NetworkPolicy es material de examen dentro del dominio de Services & Networking (20%), estudiarías con un cluster que te da falsos positivos en cada ejercicio. No merece la pena por 200 MB.

Si aun con el modo slim el cluster va apretado, la alternativa correcta es **Calico** (~150 MB, sí soporta NetworkPolicy), no Flannel.

### 4.7 Unir los workers

En cada worker, ejecuta el `kubeadm join ...` guardado. Luego, desde el control plane:

```bash
kubectl get nodes -o wide     # los 3 en Ready
kubectl get pods -A
```

Etiqueta los workers (cosmético pero útil):

```bash
kubectl label node k8s-wk-1 node-role.kubernetes.io/worker=worker
kubectl label node k8s-wk-2 node-role.kubernetes.io/worker=worker
```

### 4.8 SNAPSHOT — el paso más importante

Desde el host de Proxmox, con las VMs **apagadas** para consistencia:

```bash
for id in 101 102 103; do
  qm shutdown $id && sleep 20
done

for id in 101 102 103; do
  qm snapshot $id cluster-limpio --description "kubeadm + cilium, estado base"
  qm start $id
done
```

Este snapshot es tu red de seguridad para toda la Fase 9. Restaurar es:

```bash
qm rollback 101 cluster-limpio
```

**Checkpoint Fase 4:** `kubectl get nodes` muestra 3 nodos `Ready`, y tienes un snapshot al que volver.

---

# Fase 5 — GitOps con ArgoCD

### 5.1 Instalar ArgoCD (la única vez que lo haces a mano)

```bash
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl wait --for=condition=available --timeout=600s deployment/argocd-server -n argocd
```

Contraseña inicial:

```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d; echo
```

Acceso temporal (hasta que tengas Gateway):

```bash
kubectl port-forward svc/argocd-server -n argocd 8080:443
```

Entra a `https://localhost:8080` con usuario `admin`.

**Ajuste obligatorio en esta topología.** ArgoCD son cinco componentes y, sin límites, entre todos rondan los 800 MB — casi un worker entero. Recórtalo:

```bash
# El repo-server es el que más consume (clona repos y renderiza Helm)
kubectl -n argocd set resources deploy/argocd-repo-server \
  --limits=memory=384Mi --requests=memory=192Mi

kubectl -n argocd set resources deploy/argocd-server \
  --limits=memory=192Mi --requests=memory=96Mi

kubectl -n argocd set resources statefulset/argocd-application-controller \
  --limits=memory=384Mi --requests=memory=192Mi

# Desactiva componentes que no vas a usar todavía
kubectl -n argocd scale deploy/argocd-applicationset-controller --replicas=0
kubectl -n argocd scale deploy/argocd-notifications-controller --replicas=0
```

Total: ~700 MB pasa a ~500 MB con límites duros. Cuando lo migres a Git (Fase 5.3), pon estos valores en el `values.yaml` del chart para que sean permanentes.

> Si el `repo-server` empieza a morir con `OOMKilled` al sincronizar charts grandes, súbele el límite a 512Mi antes que cualquier otra cosa.

### 5.2 Estructura del repo GitOps

```
gitops/
├── bootstrap/
│   ├── root-app.yaml              # la Application raíz (app-of-apps)
│   └── projects.yaml
├── infrastructure/
│   ├── metallb/
│   │   ├── application.yaml
│   │   └── values.yaml
│   ├── cert-manager/
│   ├── envoy-gateway/
│   ├── sealed-secrets/
│   └── cloudflared/
└── apps/
    ├── podinfo/
    └── ...
```

### 5.3 El patrón app-of-apps

`gitops/bootstrap/root-app.yaml`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: root
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: https://github.com/TU_USUARIO/homelab.git
    targetRevision: main
    path: gitops/infrastructure
    directory:
      recurse: true
      include: '*/application.yaml'
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

Aplícalo **una sola vez**:

```bash
kubectl apply -f gitops/bootstrap/root-app.yaml
```

A partir de aquí, todo lo que añadas al directorio `infrastructure/` en Git aparece solo en el cluster. **Deja de usar `kubectl apply`.**

### 5.4 Primera aplicación de prueba

`gitops/apps/podinfo/application.yaml`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: podinfo
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://stefanprodan.github.io/podinfo
    chart: podinfo
    targetRevision: 6.7.*
  destination:
    server: https://kubernetes.default.svc
    namespace: podinfo
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions: [CreateNamespace=true]
```

Commit + push. En menos de 3 minutos deberías verlo en la UI de Argo.

### 5.5 El experimento que hace clic

```bash
kubectl -n podinfo scale deployment podinfo --replicas=10
```

Espera 60 segundos y vuelve a mirar. Argo lo revierte a lo que dice Git. **Eso es `selfHeal`, y ese es todo el concepto de GitOps en una frase.**

**Checkpoint Fase 5:** haces un commit y aparece en el cluster sin tocar la terminal.

---

# Fase 6 — La plataforma

Todo lo de esta fase se despliega **vía Git**, no a mano.

### 6.1 MetalLB (LoadBalancer para bare metal)

Sin cloud provider, los `Service` de tipo `LoadBalancer` se quedan en `<pending>` para siempre. MetalLB reparte IPs de tu LAN.

```yaml
# infrastructure/metallb/ipaddresspool.yaml
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: lan-pool
  namespace: metallb-system
spec:
  addresses:
    - 192.168.1.200-192.168.1.220   # el rango que reservaste en la Fase 0
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: lan-l2
  namespace: metallb-system
spec:
  ipAddressPools: [lan-pool]
```

### 6.2 Gateway API + Envoy Gateway

Salta Ingress por completo — está congelado y `ingress-nginx` llegó a fin de vida en marzo de 2026. Gateway API también entró al temario del CKA, así que aprenderlo te sirve doble.

Primero los CRDs (van aparte del controlador):

```bash
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.5.0/standard-install.yaml
```

Luego Envoy Gateway como Application de Argo, y define tu Gateway:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: envoy
spec:
  controllerName: gateway.envoyproxy.io/gatewayclass-controller
---
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: main
  namespace: gateway-system
spec:
  gatewayClassName: envoy
  listeners:
    - name: http
      protocol: HTTP
      port: 80
      allowedRoutes:
        namespaces: { from: All }
```

Y una ruta hacia podinfo:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: podinfo
  namespace: podinfo
spec:
  parentRefs:
    - name: main
      namespace: gateway-system
  hostnames: ["podinfo.tudominio.com"]
  rules:
    - backendRefs:
        - name: podinfo
          port: 9898
```

### 6.3 Secretos

Con ArgoCD, la opción más simple es **Sealed Secrets**: cifras con la llave pública del cluster, el resultado es seguro en Git público, y solo el controlador dentro del cluster puede descifrarlo.

```bash
# CLI
kubeseal --fetch-cert > pub-cert.pem

kubectl create secret generic mi-secreto \
  --dry-run=client --from-literal=token=abc123 -o yaml \
  | kubeseal --cert pub-cert.pem -o yaml > sealed-secret.yaml
```

`sealed-secret.yaml` va a Git sin problema.

> **Importante:** haz backup de la llave maestra del controlador. Si pierdes el cluster sin ella, ningún SealedSecret se puede descifrar:
> ```bash
> kubectl get secret -n kube-system -l sealedsecrets.bitnami.com/sealed-secrets-key -o yaml > sealed-secrets-key-BACKUP.yaml
> ```
> Guárdalo **fuera** del repo, en tu gestor de contraseñas.

### 6.4 cert-manager

Para TLS interno. Usa el desafío DNS-01, no HTTP-01 — no tienes puertos abiertos:

```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: tu@email.com
    privateKeySecretRef: { name: letsencrypt-account-key }
    solvers:
      - dns01:
          cloudflare:
            apiTokenSecretRef:
              name: cloudflare-api-token
              key: api-token
```

### 6.5 Almacenamiento

Empieza simple. `local-path-provisioner` de Rancher da PVs sobre el disco del nodo:

```bash
# como Application de Argo
https://github.com/rancher/local-path-provisioner
```

Marca su StorageClass como default.

**En esta topología, `local-path` no es un punto de partida: es el destino.** Longhorn necesita ~500 MB por nodo solo para sus agentes (instance-manager, engine, replica), y con 1 GB útil por worker se comería la mitad del cluster. Rook/Ceph está aún más lejos de tu alcance.

La limitación real de `local-path` es que el pod queda atado al nodo donde se creó el volumen. Si ese nodo cae, el pod no puede reprogramarse. Es un compromiso aceptable aquí; simplemente sé consciente de que tus PVs no son de alta disponibilidad.

Si necesitas almacenamiento compartido, la salida más barata en RAM es **NFS desde el propio host de Proxmox** (o desde un NAS) con `csi-driver-nfs`, que consume ~50 MB. Externalizas el problema en vez de resolverlo dentro del cluster.

**Checkpoint Fase 6:** accedes a podinfo por su hostname a través del Gateway, con una IP de MetalLB, y todos los manifiestos están en Git.

---

# Fase 7 — Exponer a internet con Cloudflare Tunnel

### 7.1 Preparativos

1. Un dominio (Namecheap, Porkbun, ~$10/año) con los nameservers apuntando a Cloudflare
2. Cuenta gratuita de Cloudflare
3. En el dashboard: **Zero Trust → Networks → Tunnels → Create a tunnel**, tipo `Cloudflared`
4. Copia el **token del túnel**

### 7.2 Guardar el token

```bash
kubectl create secret generic tunnel-token \
  --namespace cloudflared \
  --dry-run=client --from-literal=token='TU_TOKEN' -o yaml \
  | kubeseal --cert pub-cert.pem -o yaml > gitops/infrastructure/cloudflared/sealed-token.yaml
```

### 7.3 Desplegar cloudflared

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: cloudflared
  namespace: cloudflared
spec:
  replicas: 2
  selector:
    matchLabels: { app: cloudflared }
  template:
    metadata:
      labels: { app: cloudflared }
    spec:
      containers:
        - name: cloudflared
          image: cloudflare/cloudflared:latest
          args:
            - tunnel
            - --no-autoupdate
            - --metrics
            - 0.0.0.0:2000
            - run
          env:
            - name: TUNNEL_TOKEN
              valueFrom:
                secretKeyRef:
                  name: tunnel-token
                  key: token
          livenessProbe:
            httpGet: { path: /ready, port: 2000 }
            initialDelaySeconds: 10
```

### 7.4 Configurar el enrutamiento

En el dashboard de Cloudflare, en **Public Hostnames** del túnel, apunta **todo** a tu Gateway interno:

- Hostname: `*.tudominio.com`
- Service: `http://envoy-gateway-service.gateway-system.svc.cluster.local:80`

Así el enrutamiento fino lo hace Gateway API dentro del cluster, y Cloudflare solo es el transporte. No duplicas lógica en dos sitios.

### 7.5 Proteger lo privado con Cloudflare Access

Para Grafana, ArgoCD y cualquier cosa que no deba ser pública: **Zero Trust → Access → Applications**. Añades el hostname, defines una política (`emails ending in @tudominio.com`, o tu email concreto) y Cloudflare pone un login OIDC delante. Gratis hasta 50 usuarios y no escribes una línea de código.

> **Regla:** nada sale a internet sin Access delante, salvo que sea deliberadamente público.

**Checkpoint Fase 7:** `https://podinfo.tudominio.com` funciona desde el móvil con datos, con certificado válido, y tu router no tiene ni un puerto abierto.

---

# Fase 8 — Observabilidad y backups

### 8.1 Stack de métricas y logs

**`kube-prometheus-stack` no cabe en esta topología.** Prometheus solo pide 1-2 GB, y tus workers tienen 1 GB útil cada uno. Instalarlo te va a dar un `OOMKilled` en bucle.

La alternativa correcta es **VictoriaMetrics**: es compatible con PromQL y con el formato de scrape de Prometheus, pero `vmsingle` opera cómodo en 200-300 MB. No es un downgrade — es lo que usarías igualmente en un entorno con presión de memoria.

Chart: `victoria-metrics-k8s-stack` (incluye vmsingle, vmagent, Grafana, node-exporter y kube-state-metrics, con los mismos dashboards y reglas del stack de Prometheus).

```yaml
# gitops/infrastructure/victoria-metrics/values.yaml
vmsingle:
  spec:
    retentionPeriod: "7d"          # 7 días es suficiente para un homelab
    resources:
      limits:   { memory: 400Mi }
      requests: { memory: 200Mi }
    storage:
      resources:
        requests: { storage: 8Gi }

vmagent:
  spec:
    scrapeInterval: "60s"          # 30s por defecto; 60s reduce cardinalidad y RAM
    resources:
      limits:   { memory: 200Mi }
      requests: { memory: 100Mi }

grafana:
  resources:
    limits:   { memory: 200Mi }
    requests: { memory: 100Mi }
  persistence:
    enabled: true
    size: 2Gi

alertmanager:
  enabled: false                   # actívalo después, si te sobra margen

kube-state-metrics:
  resources:
    limits: { memory: 128Mi }
```

Presupuesto total: **~900 MB**, que ocupa prácticamente un worker completo. Deja el otro worker libre para tus aplicaciones.

### 8.1b Logs — sin Loki, de momento

Loki en modo `SingleBinary` necesita 300-500 MB, y ya no te queda. Las opciones:

1. **Empieza sin agregación de logs.** `kubectl logs` y `stern` cubren el 90% de los casos en un cluster de tres nodos. Es la opción honesta.
2. Si necesitas historial, **Grafana Alloy enviando a Loki Cloud** (tier gratuito: 50 GB/mes). Alloy como DaemonSet consume ~80 MB por nodo y la ingesta se va fuera. Ahorras la RAM del backend.

Instala `stern` en tu máquina, que te va a servir todos los días:

```bash
kubectl logs -f -l app=podinfo -n podinfo --all-containers
stern podinfo -n podinfo          # más cómodo, multi-pod
```

### 8.1c metrics-server — instálalo primero

Independientemente de lo anterior, este es pequeño (~50 MB) y lo vas a necesitar constantemente para diagnosticar memoria (y para HPA, que es material de examen):

```bash
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml

# Certificados autofirmados en el kubelet: necesario en clusters kubeadm caseros
kubectl -n kube-system patch deploy metrics-server --type=json \
  -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'

kubectl top nodes
kubectl top pods -A --sort-by=memory
```

Ese último comando va a ser tu herramienta más usada en este cluster.

### 8.2 Backups del cluster

**Velero** hacia un MinIO local o Backblaze B2:

```bash
velero backup create semanal --include-namespaces podinfo,argocd
velero schedule create diario --schedule="0 3 * * *"
```

**Snapshots de etcd** — practica esto porque cae en el examen:

```bash
ETCDCTL_API=3 etcdctl snapshot save /backup/etcd-$(date +%F).db \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key

ETCDCTL_API=3 etcdctl snapshot status /backup/etcd-*.db --write-out=table
```

**Backups de Proxmox:** configura *Datacenter → Backup* con un job semanal hacia un disco externo o NAS. Si tienes espacio, instala Proxmox Backup Server en una VM para backups incrementales y deduplicados.

### 8.3 Renovate — cerrar el loop

Instala la app de Renovate en tu repo de GitHub. `renovate.json`:

```json
{
  "$schema": "https://docs.renovatebot.com/renovate-schema.json",
  "extends": ["config:recommended"],
  "kubernetes": { "managerFilePatterns": ["/gitops/.+\\.yaml$/"] },
  "helm-values": { "managerFilePatterns": ["/gitops/.+\\.yaml$/"] }
}
```

Ahora: sale una versión nueva de un chart → Renovate abre un PR → haces merge → Argo despliega. **El loop completo, sin terminal.**

**Checkpoint Fase 8:** tienes dashboards de Grafana, alertas configuradas, backups automáticos verificados (restaura uno de prueba) y PRs automáticos de actualización.

---

# Fase 9 — Entrenamiento para el CKA

Ahora usas el cluster para lo que se diseñó: romperlo.

### 9.1 Distribución del estudio

Basado en los pesos del temario: **Troubleshooting 30%, Cluster Architecture 25%, Services & Networking 20%, Workloads 15%, Storage 10%**. Invierte al menos un tercio de tu tiempo en troubleshooting.

### 9.2 Escenarios de destrucción (uno por sesión)

Antes de cada uno: `qm snapshot`. Después: `qm rollback`.

| # | Rompe esto | Deberías aprender |
|---|---|---|
| 1 | `systemctl stop kubelet` en un worker | Diagnóstico con `journalctl -u kubelet` |
| 2 | Edita `/etc/containerd/config.toml` y pon `SystemdCgroup = false` | Por qué el cgroup driver importa |
| 3 | Mueve `/etc/kubernetes/manifests/kube-apiserver.yaml` | Static pods, cómo el kubelet los gestiona |
| 4 | Corrompe un `--data-dir` de etcd | Restaurar desde snapshot con `etcdctl snapshot restore` |
| 5 | Cambia el puerto del apiserver en su manifiesto | Cómo el control plane se auto-referencia |
| 6 | Aplica una NetworkPolicy `deny-all` | Depurar conectividad entre pods |
| 7 | Llena el disco de un nodo | Taints automáticos, eviction, `DiskPressure` |
| 8 | Adelanta el reloj del sistema un año | Certificados expirados, `kubeadm certs renew` |
| 9 | Rompe CoreDNS | Resolución DNS dentro del cluster |
| 10 | Upgrade de 1.34 a 1.35 con `kubeadm upgrade` | El procedimiento completo, drain incluido |

### 9.3 Rutina de velocidad

El examen son ~17 tareas en 2 horas. Practica:

```bash
# Alias y autocompletado — configúralos en los primeros 30 segundos del examen
alias k=kubectl
source <(kubectl completion bash)
complete -o default -F __start_kubectl k
export do="--dry-run=client -o yaml"

# Generar en vez de escribir YAML a mano
k run nginx --image=nginx $do > pod.yaml
k create deploy web --image=nginx --replicas=3 $do > deploy.yaml
```

Aprende a navegar `kubernetes.io/docs` rápido — es la **única** documentación permitida durante el examen.

### 9.4 Últimas 4 semanas

Usa **killer.sh** (incluido con el registro del examen, dos sesiones). Es deliberadamente más difícil que el examen real. No gastes ambas sesiones al principio: guarda una para la semana previa.

---

# Fase 10 (opcional) — Cluster API y/o Talos

Solo cuando lo anterior te resulte rutinario.

> **Restricción en esta topología:** no hay RAM para dos clusters simultáneos. La Fase 10 exige **apagar el cluster de laboratorio** antes de empezar:
> ```bash
> qm shutdown 101 102 103
> ```
> Es una ventaja, no un obstáculo: te obliga a comprobar que puedes reconstruir el cluster desde Git cuando quieras volver. Si apagarlo te da miedo, es señal de que el trabajo de las Fases 3 a 5 no está terminado.

### 10.1 Cluster API sobre Proxmox

```bash
# Management cluster efímero
kind create cluster --name capi-mgmt

clusterctl init --infrastructure proxmox --bootstrap kubeadm --control-plane kubeadm
```

Necesitarás:
- La plantilla cloud-init de la Fase 2
- Un rango de IPs libre para el IPAM in-cluster
- El token de la API de Proxmox de la Fase 1

Genera y aplica un cluster:

```bash
clusterctl generate cluster mi-cluster \
  --infrastructure proxmox \
  --kubernetes-version v1.34.0 \
  --control-plane-machine-count 1 \
  --worker-machine-count 2 > cluster.yaml

kubectl apply -f cluster.yaml
```

Prueba la reconciliación: borra una VM desde la UI de Proxmox y observa cómo CAPI la recrea sola. Después, escala:

```bash
kubectl scale machinedeployment mi-cluster-md-0 --replicas=4
```

Cuando funcione, haz el **pivot**: mueve los controladores de CAPI del cluster `kind` a un cluster permanente con `clusterctl move`.

### 10.2 Cluster de plataforma con Talos

Si tienes RAM de sobra, monta un segundo cluster con Talos y migra la plataforma allí, dejando el de kubeadm exclusivamente como laboratorio de destrucción.

```bash
talosctl gen config homelab https://192.168.1.61:6443
talosctl apply-config --insecure -n 192.168.1.61 --file controlplane.yaml
talosctl bootstrap -n 192.168.1.61
talosctl kubeconfig -n 192.168.1.61
```

Notarás de inmediato la diferencia: no hay SSH, no hay systemd, no hay nada que tocar. Y esa es exactamente la razón por la que no sirve para estudiar el CKA.

---

# Reglas que te ahorrarán dolor

1. **Snapshot antes de cada experimento.** Cuesta 10 segundos y salva horas.
2. **Nada entra al cluster sin pasar por Git** (a partir de la Fase 5). Si te descubres haciendo `kubectl apply`, párate.
3. **Un cambio a la vez.** Cuando algo falle, quieres una sola variable sospechosa.
4. **Documenta en el propio repo.** Un `docs/decisiones.md` con "por qué elegí X" te va a servir en entrevistas.
5. **Verifica los backups restaurando.** Un backup no probado no es un backup.
6. **Fija versiones.** Nada de `latest` en producción — ni en tu homelab, que a estas alturas es lo mismo.
7. **Si llevas 3 horas atascado en almacenamiento, sáltatelo.** Usa `local-path` y sigue. Vuelve después.
8. **Toda carga lleva `limits` de memoria.** Con 1 GB útil por worker, un solo pod sin límite puede tumbar el nodo entero. Sin excepciones.
9. **Antes de instalar cualquier chart, busca su consumo.** `kubectl top pods -A --sort-by=memory` después de cada despliegue nuevo. Si algo se come 300 MB, decide conscientemente si vale ese espacio.
10. **Comportamiento raro = revisa memoria primero.** `dmesg -T | grep -i "killed process"` antes de sospechar de la red, del CNI o de Kubernetes.

---

# Criterio de éxito final

Sabrás que terminaste cuando puedas ejecutar, en este orden, sin consultar notas:

```bash
cd infra/ && tofu destroy -auto-approve
tofu apply -auto-approve
ansible-playbook -i inventory.yml playbooks/cluster.yml
kubectl apply -f gitops/bootstrap/root-app.yaml
```

...y tener en menos de 30 minutos un cluster completo con red, TLS, observabilidad y aplicaciones expuestas a internet.

Eso, en una entrevista, vale más que cualquier certificación. La certificación es el papel; esto es la evidencia.
