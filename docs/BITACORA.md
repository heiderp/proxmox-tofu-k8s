# Bitácora del proyecto

Este documento explica **qué hace cada fase, por qué existe y qué se decidió en ella**. No repite
los comandos — esos están en [`roadmap-homelab-k8s.md`](roadmap-homelab-k8s.md). Aquí queda la
trayectoria: lo ejecutado, lo decidido y lo que salió mal.

**Leyenda de estado:** ✅ completada · 🔜 en curso / siguiente · ⬜ pendiente

**Cómo mantener este documento:** al cerrar cada fase, antes de pasar a la siguiente, rellena sus
apartados *Decisiones tomadas* e *Incidencias*, y añade la línea correspondiente en la
[línea de tiempo](#línea-de-tiempo). Las decisiones anotadas antes de ejecutar una fase provienen
del roadmap; confírmalas o corrígelas cuando la ejecutes de verdad.

---

## Fase 0 — Verificación de hardware ✅

**Qué construye:** nada. Comprueba que el hardware aguanta el proyecto antes de invertir semanas
en él.

**Por qué existe:** hay tres formas de descubrir tarde que el equipo no sirve, y las tres cuestan
días. Que el CPU no soporte `x86-64-v2` y las imágenes de contenedor modernas fallen con
`SIGILL`. Que la virtualización esté desactivada en el BIOS. Y la peor: que el disco tenga una
latencia de `fsync` alta, porque **etcd es extremadamente sensible a ella** — el síntoma son
timeouts constantes de elección de líder que parecen un bug de Kubernetes y no lo son.

**Decisiones tomadas:**

- **Umbral de disco: p99 de `fsync` por debajo de 10 ms.** Si la prueba con `fio` da 50-100 ms,
  la respuesta correcta no es seguir adelante, es comprar un SSD/NVMe aunque sea de 250 GB solo
  para el control plane.
- **Rangos de IP reservados fuera del DHCP del router:** `192.168.1.50-59` para las VMs,
  `192.168.1.200-220` para el pool de MetalLB. Definirlos aquí evita colisiones que después se
  depuran a ciegas.

**Verificación:**

```bash
egrep -c '(vmx|svm)' /proc/cpuinfo                                  # > 0
/lib/x86_64-linux-gnu/ld-linux-x86-64.so.2 --help | grep supported  # x86-64-v2
sudo fio --name=etcd-test --rw=write --ioengine=sync --fdatasync=1 \
  --size=200m --bs=2300 --filename=/tmp/testfile                    # p99 < 10 ms
```

**Resultado real (2026-08-25):** la prueba de `fio` se ejecutó retroactivamente, antes de empezar
la Fase 3. SSD de 119 GB (`GIT128-L130-2280`, M.2 no rotacional). Latencia de `fdatasync`:

| Percentil | Latencia |
|---|---|
| p99 | **1,34 ms** |
| p99.9 | 6,52 ms |
| p99.95 | 8,59 ms |
| p99.99 | 18,22 ms |

El p99 queda 7,5 veces por debajo del umbral de 10 ms. La cola extrema (p99.99) lo supera, pero a
ese percentil etcd tolera picos aislados. **El disco no es un riesgo para el proyecto.** Si en la
Fase 4 aparecen timeouts de elección de líder, la causa no está aquí.

**Incidencias:**

- **La primera medición fue inválida y daba un falso positivo espectacular.** El comando del
  roadmap escribe en `/tmp`, y en Debian 13 (trixie) **`/tmp` es `tmpfs`** por defecto — o sea,
  RAM. El resultado fue 1220 MiB/s con latencias de `fsync` en *nanosegundos*, cifras imposibles
  para cualquier SSD. La pista que delata el error es la unidad: si `fio` reporta las
  `sync percentiles` en `nsec` en vez de `usec`, no estás midiendo el disco. La medida buena se
  hizo sobre `/var/lib/vz` (que vive en `pve-root`, el mismo SSD físico que `local-lvm`).

---

## Fase 1 — Proxmox VE instalado y endurecido ✅

**Qué construye:** el hipervisor sobre el que vive todo lo demás, con repos correctos y una
identidad de API con privilegios mínimos para que OpenTofu pueda crear VMs.

**Por qué existe:** es la única capa del proyecto que se instala a mano y no se reconstruye desde
Git. Todo lo demás es desechable; esto no. Por eso conviene dejarla bien y documentada.

**Decisiones tomadas:**

- **`ext4` + LVM-thin en vez de ZFS.** ZFS da snapshots instantáneos y checksums, que es
  tentador, pero su ARC necesita ~1 GB de RAM por TB y competiría directamente con los 8 GB
  comprometidos en las VMs. Con este presupuesto de memoria, ZFS es un lujo que se paga en pods
  desalojados. _(Si en algún momento se migra a ZFS: limitar `zfs_arc_max` a 2 GB es obligatorio,
  no opcional.)_
- **Repositorio `pve-no-subscription` en formato deb822 (`.sources`).** PVE 9 está sobre Debian
  trixie y ya usa el formato nuevo; el `.list` clásico de PVE 8 no aplica aquí. El repo
  enterprise se desactiva comentando su línea `Components:`.
- **IP estática y hostname FQDN**, no DHCP. Toda la topología posterior asume direcciones fijas.
- **Usuario `tofu@pve` con rol `Provisioner` de privilegios mínimos, en lugar de `root@pam`.**
  El rol lista exactamente los permisos que el provider necesita (`VM.Allocate`, `VM.Clone`,
  `VM.Config.*`, `Datastore.AllocateSpace`, `SDN.Use`…) y nada más. El token se crea con
  `--privsep 0` para que herede esos permisos del usuario.

  Es más trabajo que usar root y merece la pena por dos razones: el token acaba en el state de
  OpenTofu, y saber traducir "esta herramienta necesita hacer X" a un conjunto concreto de
  privilegios es exactamente el músculo que pide el dominio *Cluster Architecture* del CKA.
- **El valor del token vive en el gestor de contraseñas, nunca en el repo.** Proxmox solo lo
  muestra una vez.

> **Corrección posterior (2026-08-25, al preparar la Fase 3):** la lista de privilegios de arriba
> estaba incompleta. Faltaba el permiso para consultar el guest agent, sin el cual el provider no
> puede leer las IPs de las VMs. Se añadió **`VM.GuestAgent.Audit`** (19 privilegios en total).
> El detalle está en la Fase 3. Estado actual del rol:
>
> ```bash
> ssh pve 'pveum role list | grep -i provisioner'
> ```

**Verificación:**

```bash
pveversion                       # devuelve la versión
apt update                       # sin errores 401 del repo enterprise
# y la UI responde en https://192.168.1.20:8006
```

**Incidencias:** ninguna registrada.

---

## Fase 2 — Plantilla cloud-init ✅

**Qué construye:** una plantilla de VM (VMID 9000) de la que se clonan todos los nodos en
segundos, ya con `qemu-guest-agent` dentro.

**Por qué existe:** es el punto donde el proyecto deja de ser manual. Sin plantilla, cada VM es
una instalación de Debian de 15 minutos; con ella, un clon completo tarda menos de 60 segundos y
OpenTofu puede recrear el cluster entero sin intervención. Hacerla bien aquí ahorra horas en cada
fase posterior.

**Decisiones tomadas:**

- **El guest agent se inyecta en la imagen con `virt-customize`, antes de crear la plantilla.**
  Las imágenes cloud no lo traen, y sin él Proxmox no ve las IPs de las VMs ni puede apagarlas
  limpiamente — lo que rompe `tofu destroy` y los snapshots consistentes.
- **`--truncate /etc/machine-id` es obligatorio.** Si no, todos los clones comparten machine-id y
  el DHCP les entrega la misma IP. Es un fallo que se manifiesta tarde y confunde mucho.
- **Consola serie (`--serial0 socket --vga serial0`)**: las imágenes cloud no arrancan una consola
  gráfica útil; sin esto no hay forma de depurar un arranque fallido.
- **Autenticación solo por llave SSH** desde el primer minuto.
- **Una llave dedicada, `~/.ssh/homelab`, y sin passphrase.** Dedicada porque un homelab
  expuesto a internet (Fase 7) no debe compartir credencial con GitHub ni con AWS: si cae, cae
  sólo esto. Sin passphrase porque Ansible (Fase 4) y el provisioner de OpenTofu (Fase 3)
  conectan de forma no interactiva, y exigir `ssh-agent` cargado convierte cada reconstrucción
  en un paso manual — justo lo que el criterio de éxito prohíbe. La privada no sale de la
  máquina de trabajo; la pública vive en el host como `/root/homelab.pub`, que es lo que lee
  `qm set --sshkeys`.
- **El procedimiento se versiona como script, no como comandos sueltos.**
  `scripts/fase2-plantilla.sh` sustituye a copiar y pegar del roadmap. Motivo: la plantilla se
  va a rehacer (cambio de versión de Debian, ajuste de la imagen), y un procedimiento manual se
  degrada en cada repetición.
- **`build` y `test` son subcomandos separados.** Ningún comando destruye VMs salvo que se pida
  explícitamente; el script aborta si el VMID 9000 ya existe en lugar de sobrescribirlo.
- **`virt-customize` trabaja sobre una copia (`debian-13-work.qcow2`), no sobre la imagen
  descargada.** Modifica in-place: sin la copia, una segunda ejecución acumula capas de cambios
  sobre una imagen ya alterada y el resultado deja de ser reproducible.
- **Almacenamiento `local-lvm`.** Consecuencia directa de la Fase 1 (ext4 + LVM-thin, no ZFS);
  con ZFS los mismos comandos apuntarían a `local-zfs`.

**Verificación / checkpoint:** clonar la plantilla a una VM de prueba, entrar por SSH sin
contraseña y destruirla. Si eso funciona, la plantilla está bien.

**Resultado real (2026-08-24):** plantilla 9000 creada sobre `local-lvm` en PVE 9.2.11. El clon
de prueba (VMID 199, `192.168.1.99`) tuvo el guest agent respondiendo a los **16 segundos** —
muy por debajo del límite de 60 del checkpoint. SSH sin contraseña con `~/.ssh/homelab`,
`qemu-guest-agent` en `active`, `machine-id` regenerado y único en el clon, y el `qm resize`
reflejado dentro del invitado (raíz de 21 GB desde una imagen base de 3 GB, sin tocar nada a
mano: cloud-init expande el sistema de ficheros al arrancar).

**Incidencias:** ninguna. La única fricción es que `ssh-copy-id` contra el host exige teclear la
contraseña de root una vez; no es automatizable ni conviene que lo sea.

---

## Fase 3 — OpenTofu ✅

**Qué construye:** la definición declarativa de los tres nodos. `tofu apply` levanta el cluster
de VMs; `tofu destroy` lo borra.

**Por qué existe:** es la mitad inferior de la promesa del proyecto ("reconstruir desde Git"). La
prueba que importa no es que `apply` funcione, sino que `destroy` seguido de `apply` devuelva
VMs idénticas. Ese ciclo es el que convierte la infraestructura en algo desechable.

**Decisiones tomadas:**

- **OpenTofu en vez de Terraform**, principalmente por el cifrado de state del lado del cliente,
  que aquí no es cosmético: el state contiene el token de la API de Proxmox.
- **Provider `bpg/proxmox`**, con versión fijada.
- **`floating = 0` — ballooning desactivado.** Es la decisión más importante de la fase. El
  ballooning permite al hipervisor reclamar RAM de una VM bajo presión, lo cual suena razonable,
  pero es catastrófico con nodos de 2 GB: **el kubelet calcula su capacidad al arrancar y nunca
  se entera de que le quitaron memoria**, así que sigue programando pods hasta que entra el OOM
  killer. Memoria fija y punto.
- **State cifrado con PBKDF2 vía la variable de entorno `TF_ENCRYPTION`**, no en el código.
  La passphrase vive en `.envrc` (gestionado con `direnv`) y `.envrc` está en `.gitignore`.
- **`terraform.tfvars` fuera del repo**; se versiona solo un `.tfvars.example`.
- **`lifecycle.ignore_changes` sobre `user_account`**, para que cloud-init no fuerce recreaciones
  de VM en cada plan.
- **`outputs.tf` expone las IPs de los nodos** para alimentar el inventario de Ansible sin
  duplicar la lista a mano.

**Verificación previa (2026-08-25).** Antes de escribir una línea de HCL se comprobó el terreno.
Cuatro cosas no cuadraban con lo que el roadmap daba por supuesto:

- **El privilegio `VM.Monitor` ya no existe en PVE 9.** El rol `Provisioner` de la Fase 1 no podía
  leer el guest agent, que es justo de donde salen las IPs de las VMs. Proxmox lo sustituyó por la
  familia `VM.GuestAgent.*` (`.Audit`, `.FileRead`, `.FileWrite`, `.FileSystemMgmt`,
  `.Unrestricted`). Se añadió **`VM.GuestAgent.Audit`** al rol, que es el mínimo para consultar
  `network-get-interfaces`. Sin él, el `read` del recurso devuelve 403 y `outputs.tf` queda
  inservible — con el agravante de que el fallo aparece *después* de crear las VMs, no en el plan.
- **El thin pool no daba para los discos del roadmap.** `local-lvm` tenía 53,87 GB frente a los
  100 GB de 40/30/30. LVM-thin permite sobreaprovisionar, pero un pool al 100% no da error: pasa a
  errores de I/O y **corrompe todas las VMs a la vez**. Se resolvió por los dos lados: extender el
  pool a **66,87 GB** con los 14,63 GB que quedaban sin asignar en el VG, y bajar los discos a
  **25/20/20 = 65 GB**. Queda prácticamente 1:1, sin depender de la vigilancia de nadie. Se dejaron
  1,63 GB libres en el VG por si el LV de metadatos necesita crecer.

  > Ojo al reconstruir el host: **un thin pool se puede extender pero no reducir.** El VG ya no
  > tiene margen (1,63 GB), así que a partir de aquí ampliar `local-lvm` exige recortar `pve/root`
  > (39,5 GB, con 30 GB libres) o añadir un disco. No es un problema hoy; sí lo sería descubrirlo
  > con el cluster montado.
- **El provider iba 45 versiones por detrás.** El roadmap fija `~> 0.66`; la versión publicada es
  la 0.111.1. El HCL del roadmap es un punto de partida, no un copia-pega.
- **`.terraform.lock.hcl` estaba en `.gitignore`.** Contradice la regla nº 6 del README. El
  lockfile es precisamente lo que fija los hashes del provider entre máquinas; se sacó.

Lo que sí estaba correcto: RAM (15,7 GB, ~6 de margen), IPs `.51`-`.53` libres, `vmbr0` en
`192.168.1.20/24`, plantilla 9000 con `agent=1` y cloud-init en `ide2`, nodo llamado `pve`, y la
API respondiendo con su cert autofirmado (`CN=pve.homelab.local`, válido hasta 2028) — que es lo
que justifica el `insecure = true` del provider.

**Decisiones añadidas tras la verificación:**

- **`ssh { agent = false }` con `private_key` explícita.** El main.tf del roadmap usa
  `agent = true`, lo que reintroduce la dependencia de `ssh-agent` que la Fase 2 eliminó a
  propósito al crear la llave sin passphrase. Coherencia: la llave se pasa por ruta.
- **`stop_on_destroy = true` y `on_boot = true`.** El primero evita que `destroy` se cuelgue
  esperando un apagado ACPI — y `destroy` es literalmente la mitad del checkpoint de esta fase.
  El segundo, que un reboot del host deje el cluster caído.
- **`initialization` con `datastore_id` e `interface` explícitos.** La plantilla ya trae un drive
  cloud-init en `ide2`; si el provider no lo reconoce como suyo, cada `plan` propone recrear la VM
  y la idempotencia nunca se alcanza.
- **`outputs.tf` lee `ipv4_addresses` del recurso, no de `locals`.** El output del roadmap devuelve
  la misma lista que se escribió a mano: no verifica nada. Leyéndolo del recurso, el output falla
  si una VM no arrancó, en vez de pasarle a Ansible una IP que no responde.
- **OpenTofu 1.12.6 instalado en modo standalone**, en `~/.local`, sin privilegios de root. El
  instalador oficial aborta con `The release is signed with the incorrect key:` en sistemas con
  GPG 2.4+ y `keyboxd` (Arch): la firma **sí** verifica, pero el script no sabe extraer el keyid
  del keyring y compara contra una cadena vacía. Se instaló a mano verificando la firma
  (`E3E6E43D84CB852EADB0051D0C0AF313E5FD9F80`) y el SHA256 por separado. Comprobado después con un
  `tofu init` de prueba: resuelve y descarga `bpg/proxmox 0.111.1` sin incidencias.

  > Está en `~/.local/opentofu` con symlink en `~/.local/bin/tofu`, no en `/usr/local/bin`: `sudo`
  > pide contraseña en esta máquina y la instalación no la necesita. Para actualizar, repetir el
  > procedimiento manual — no hay repo de apt detrás.

**Verificación / checkpoint:** `tofu destroy && tofu apply` devuelve tres VMs accesibles por SSH,
y todo el código está en Git salvo secretos.

**Resultado real (2026-08-28):** las tres VMs se crearon al primer intento útil y el ciclo completo
`destroy` + `apply` tardó **48 segundos** (5 s de destrucción, 43 s de reconstrucción). Los nodos
quedaron con lo declarado — `k8s-cp-1` 3922 MB / 25 GB, `k8s-wk-1` y `k8s-wk-2` 1974 MB / 20 GB,
guest agent `active` en los tres y `machine-id` distintos entre sí. `tofu plan` en vacío devuelve
`No changes` tanto tras el primer `apply` como tras el ciclo: la idempotencia es real, no aparente.

Las IPs de `outputs.tf` (`.51`/`.52`/`.53`) las reporta el guest agent, así que el output prueba de
paso que cloud-init aplicó la configuración estática. Thin pool tras el `apply`: **8,26 %** de
66,87 GB — los discos son thin, el consumo real crecerá con el uso, no con la reserva.

**Cifrado de state verificado (3.7b):** `terraform.tfstate` empieza por
`"meta": { "key_provider.pbkdf2.homelab": ... }` y contiene `encrypted_data`; `grep tofu@pve` sobre
él no devuelve nada. El token de la API no está en claro en disco. La passphrase se generó con
`openssl rand -base64 32` y vive en `infra/.envrc` (modo 600, ignorado por Git) — hay que copiarla
al gestor de contraseñas: **sin ella el state es irrecuperable y las VMs quedan huérfanas del
código**.

**Incidencias:**

- **`connect: no route to host` contra `192.168.1.20:8006` en el primer `apply`, con el host
  respondiendo a `ping` sin pérdidas.** Fallo transitorio de red en la máquina de trabajo, que
  tiene un túnel VPN (`surfshark`) levantado; el mismo comando funcionó sin cambios un minuto
  después. Lo importante: **el `plan` no lo detecta**. Con el state vacío no hay ningún `read` que
  hacer, así que `plan` sale limpio sin haber tocado la API y el error aparece por primera vez en
  el `apply`. Para descartar la conectividad antes de aplicar sirve
  `curl -sk https://192.168.1.20:8006/`, no `ping`.
- **`Host key verification failed` en los tres nodos después del ciclo `destroy`/`apply`.** Es
  correcto, no un fallo: las VMs son nuevas y generan host keys nuevas, pero `~/.ssh/known_hosts`
  guarda las anteriores para las mismas IPs. Se resuelve con `ssh-keygen -R <ip>`. Tiene
  consecuencia directa en la Fase 4: **Ansible fallará igual en cada reconstrucción**, así que su
  configuración necesita `host_key_checking = False` (o limpiar `known_hosts` como paso previo del
  playbook).

---

## Fase 4 — Cluster Kubernetes con kubeadm ✅

**Qué construye:** el cluster en sí: un control plane, dos workers, red de pods funcionando.

**Por qué existe:** es el núcleo del proyecto y el material más denso del CKA. La regla de esta
fase es resistir la tentación del script mágico: cada paso se ejecuta a mano al menos una vez
para entenderlo, y *después* se convierte en rol de Ansible.

**Decisiones tomadas:**

- **kubeadm en vez de k3s o Talos.** k3s escondería exactamente lo que hay que aprender, y Talos
  no tiene SSH ni systemd que tocar — perfecto para producción, inútil para estudiar
  troubleshooting.
- **`SystemdCgroup = true` en containerd.** El paso que todo el mundo olvida. Con `false` el
  cluster arranca y parece sano, pero los nodos se vuelven inestables bajo carga. Es un clásico
  de examen.
- **`chrony` en todos los nodos.** etcd es intolerante con la deriva de reloj.
- **Reservas del kubelet (`systemReserved`, `kubeReserved`, `evictionHard`) — obligatorias con
  2 GB.** Sin ellas, cuando falta memoria decide el kernel, y el OOM killer suele elegir mal
  (mata al kubelet o a containerd). Con reservas, el kubelet **desaloja pods de forma ordenada**
  antes de llegar a ese punto. El resultado práctico: un worker de 2 GB expone ~1,6 GB
  `allocatable`. Esa es la cifra real con la que se trabaja.
  > Nota de examen: estas reservas no se tocan en el CKA, pero entender la diferencia entre
  > `capacity` y `allocatable` sí es evaluable.
- **Cilium en modo slim como CNI, no Flannel.** Flannel consume ~50 MB frente a ~250 MB de
  Cilium, y con este presupuesto es muy tentador. Pero **Flannel no implementa NetworkPolicy en
  absoluto**: los objetos se crean, se aceptan y se ignoran en silencio. Como NetworkPolicy es
  parte del dominio *Services & Networking* (20% del examen), estudiar con Flannel significaría
  practicar contra un cluster que da falsos positivos en cada ejercicio. No compensa por 200 MB.
  La alternativa válida si va muy justo es Calico (~150 MB), nunca Flannel.
- **Hubble desactivado** (ahorra ~200 MB por nodo). Se reactiva el día que haya más RAM.
- **Snapshot `cluster-limpio` de las tres VMs, apagadas, al terminar la fase.** Es la red de
  seguridad de toda la Fase 9: cada escenario de destrucción termina con un `qm rollback`.

**Decisiones añadidas al ejecutar (2026-08-28):**

- **Kubernetes v1.35, no la v1.34 del roadmap.** v1.35 es la versión sobre la que está el examen
  CKA hoy; el roadmap se escribió cuando la actual era otra. Además deja v1.36 y v1.37 ya
  publicadas por delante, así que el escenario 10 de la Fase 9 (`kubeadm upgrade`) se practica de
  verdad en vez de servir para ponerse al día. Instalado: **v1.35.8**.
- **Cilium por Helm con `values.yaml` versionado**, no `cilium install`. Los límites y el modo
  slim viven en `gitops/infrastructure/cilium/values.yaml`, que la Fase 5 adopta como Application
  de Argo sin reescribir nada. Es la misma regla que ya estaba escrita para ArgoCD: la
  configuración no vive en comandos sueltos. Instalado: **chart 1.20.1**, con la versión fijada.
- **Las reservas del kubelet NO se editan en `/var/lib/kubelet/config.yaml`.** Ese archivo lo
  regenera `kubeadm` en cada `upgrade`, así que la edición manual que propone el roadmap se
  perdería justo en el escenario 10 de la Fase 9, y en silencio. En su lugar:
  las reservas de **worker** van en el `KubeletConfiguration` de
  `ansible/files/kubeadm-config.yaml` (kubeadm las sube al ConfigMap `kubelet-config`, común al
  cluster y respetado en los upgrades), y las del **control plane** como *patch* en
  `/etc/kubernetes/patches/`, que se reaplica con `kubeadm upgrade apply --patches`.
- **La configuración de `kubeadm init` se versiona como archivo, no como flags.**
  `kubeadm init --config` en vez de una fila de `--pod-network-cidr --apiserver-advertise-address
  ...`. Motivo: los flags no se pueden parchear ni releer, y la Fase 9 va a reconstruir este
  cluster muchas veces.

**Resultado real (2026-08-28):** tres nodos `Ready` con v1.35.8 sobre containerd 1.7.24.

| Nodo | Capacity | Allocatable | Reservado |
|---|---|---|---|
| `k8s-cp-1` | 3922 MiB | 2922 MiB | 1000 MiB (300 system + 400 kube + 300 eviction) |
| `k8s-wk-1` / `k8s-wk-2` | 1974 MiB | 1524 MiB | 450 MiB (200 + 100 + 150) |

Las reservas se aplicaron exactamente como se declararon, y `allocatable` queda por debajo de
`capacity` en los tres nodos — que es la comprobación que importa. Verificado además con tráfico
real, no sólo con `kubectl get nodes`: ping entre dos pods en **nodos distintos** (0 % de pérdida),
resolución de `kubernetes.default` contra CoreDNS y salida a DNS externo. Y una `NetworkPolicy`
`deny-all` cortó el tráfico (100 % de pérdida) y al borrarla volvió a 0 % — o sea, **Cilium
aplica NetworkPolicy de verdad**, que es exactamente la razón por la que se descartó Flannel.

Thin pool tras instalar el cluster y tomar los snapshots: **19,9 %** de 66,87 GB (venía del 8,3 %).
RAM del host con las tres VMs arriba: 9,8 GB de 15,7 GB.

**Snapshot `cluster-limpio`** creado en 101/102/103 con las VMs apagadas. Al arrancarlas, el
cluster se recompuso solo: los pods pasan por `Unknown` unos segundos mientras el kubelet vuelve a
reportar, y luego todo queda `Running` sin intervención.

**Incidencias:**

- **`nodeRegistration.patches` no existe en la API `v1beta4` de kubeadm — y kubeadm no lo dice.**
  Es un campo de `v1beta3`. Con `v1beta4` hay que declararlo como `patches:` a nivel raíz de
  `InitConfiguration`. Lo grave es cómo falla: kubeadm degrada el campo desconocido a un *warning*
  (`strict decoding error: unknown field "nodeRegistration.patches"`) que se pierde entre la
  salida del `init`, sigue adelante y crea el cluster **sin aplicar el patch**. El resultado
  habría sido un control plane con las reservas de worker, sin ningún error visible. Se detectó
  porque el `--dry-run` previo mostraba 200Mi donde debían verse 300Mi.

  > Lección general: en kubeadm, un campo mal colocado no es un error, es un warning. El
  > `--dry-run` **con verificación del resultado** — no sólo mirar que termine bien — es lo que lo
  > destapa.
- **`--config` y `--patches` son mutuamente excluyentes**: `can not mix '--config' with arguments
  [patches]`. Con archivo de configuración, la única vía es el campo `patches.directory`.
- **CoreDNS atascado en `ContainerCreating` con `failed to find plugin "loopback" in path
  [/usr/lib/cni]`.** El containerd de Debian trae `bin_dir = "/usr/lib/cni"` (la ruta de Debian),
  mientras que Cilium — como todo el ecosistema Kubernetes — instala sus binarios en
  `/opt/cni/bin`. El directorio de Debian estaba **vacío**, así que no fallaba sólo el plugin de
  Cilium: faltaba hasta `loopback`. Corregido apuntando `bin_dir` a `/opt/cni/bin` en los tres
  nodos y reiniciando containerd. Es un fallo específico de instalar containerd desde los repos de
  Debian en vez de los de Docker; con el paquete de Docker no aparece.
- **La `sandbox_image` de containerd no coincidía con la que espera kubeadm**: `pause:3.8` frente a
  `pause:3.10.1`. No rompe el arranque, y por eso es traicionero: el kubelet sólo protege del
  garbage collector la imagen `pause` que él conoce, así que puede borrar la que containerd está
  usando y tumbar pods sin causa aparente. Alineado con `kubeadm config images list` antes del
  `init`.
- **El primer `kubeadm init --dry-run` falló con `kind and apiVersion is mandatory`** por un `---`
  de más al principio del archivo de configuración: las líneas de comentario iniciales más ese
  separador forman un primer documento YAML vacío, que kubeadm intenta parsear.
- **`swap` ya no existe en la imagen**: `swapon --show` vacío y `/etc/fstab` sin entrada. El paso
  `swapoff -a` del roadmap es un no-op aquí. Se ejecuta igualmente porque es obligatorio en el CKA
  y porque una imagen futura sí podría traerla.
- **`sysctl`, `swapon` y compañía viven en `/usr/sbin`, fuera del `PATH` del usuario `debian`.**
  Al verificar por SSH sin `sudo` sale `command not found`, que parece que el parámetro no se
  aplicó cuando sí lo estaba. Usar la ruta completa o `sudo`.

### 4.10 — De los comandos a los roles (2026-09-02)

**Qué construye:** `ansible/playbooks/cluster.yml` y seis roles (`common`, `kubernetes`,
`containerd`, `control_plane`, `cilium`, `worker`) que reconstruyen el cluster entero sobre las
VMs recién creadas por OpenTofu.

**Decisiones tomadas:**

- **`kubernetes` va antes que `containerd` en el orden de roles.** Parece al revés — el runtime
  primero — pero el assert de la `sandbox_image` le pregunta a `kubeadm config images list` qué
  imagen `pause` espera, y para eso kubeadm tiene que estar instalado. El orden lo impone la
  verificación, no la dependencia funcional (containerd sólo hace falta antes del `init`).
- **containerd se configura partiendo de `containerd config default`, no de un `config.toml`
  versionado.** El formato del archivo cambia entre versiones y uno fijo se queda obsoleto sin
  avisar. El rol declara sólo las tres desviaciones (`SystemdCgroup`, `sandbox_image`, `bin_dir`)
  sobre el default que genera el propio binario instalado.
- **Cilium se instala desde la máquina de trabajo (`delegate_to: localhost`), no desde el nodo.**
  Helm no está en las VMs y no tiene por qué estarlo con 2 GB por worker; además así el
  `values.yaml` del repo sigue siendo la única fuente de la configuración, el mismo que la Fase 5
  adopta como Application de ArgoCD.
- **Dos `assert` que codifican los fallos silenciosos de la sesión anterior.** No son adorno: son
  la traducción a código de las dos cosas que estuvieron a punto de pasar desapercibidas. Uno
  compara la `sandbox_image` con lo que espera kubeadm; el otro lee
  `/var/lib/kubelet/config.yaml` tras el `init` y comprueba que las reservas son las del control
  plane (300Mi/400Mi) y no las de worker — o sea, que el patch se aplicó de verdad. Si el campo
  `patches:` vuelve a colocarse mal, el playbook **para** en vez de crear un cluster desprotegido.
- **Los tokens de unión se generan en cada ejecución**, no se guardan: caducan a las 24 h. Las
  tareas que los manejan van con `no_log`.
- **El playbook no es un `qm rollback` con otro nombre.** La prueba se hizo desde `tofu destroy`,
  no desde el snapshot: un rollback devuelve VMs que ya tuvieron cluster, y eso no prueba que el
  código sepa construirlo desde una VM virgen.

**Resultado real (2026-09-02):** de VM inexistente a tres nodos `Ready` en **4 min 41 s** —
53 s de `tofu destroy` + `apply` y **3 min 48 s** de una sola pasada del playbook, sin
intervención manual. La segunda pasada da `changed=0` en los dos workers; el único `changed` que
queda en el control plane es `helm upgrade`, que crea una revisión nueva aunque no cambie nada
(sin el plugin `helm-diff` no hay forma de distinguirlo, y se prefiere que converja siempre a
saltarlo comparando la versión del chart, que dejaría fuera cualquier edición del `values.yaml`).

Las reservas salieron idénticas a las de la instalación manual: control plane 4016548Ki capacity
/ 2992548Ki allocatable, workers 2021540Ki / 1560740Ki. Verificado además con tráfico real sobre
el cluster reconstruido, no sólo con `kubectl get nodes`: ping pod↔pod entre `k8s-wk-1` y
`k8s-wk-2` (0 % de pérdida), `kubernetes.default` y DNS externo resolviendo, y una `NetworkPolicy`
`deny-all` cortando el tráfico y devolviéndolo al borrarla.

Snapshot `cluster-limpio` recreado en 101/102/103 con las VMs apagadas — el `destroy` se llevó el
anterior, que es el precio de probar en serio. Thin pool al **19,94 %** de 66,87 GB tras
rehacerlo, igual que antes. Al arrancar, los pods pasan por `Unknown` un par de minutos y vuelven
solos a `Running`.

**Incidencias:**

- **`stdout_callback = yaml` ya no existe.** Era el callback de `community.general`, eliminado en
  su versión 12.0.0 (aquí hay la 13.3.0); el `ansible.cfg` escrito en 4.1 lo daba por bueno. La
  salida YAML es hoy una opción del callback nativo: `stdout_callback = default` con
  `result_format = yaml`. Falla al arrancar el playbook, así que es barato — pero conviene saber
  que la configuración de 4.1 caducó sin que nadie la tocara.
- **`dpkg_selections` aborta sobre un paquete que aún no está instalado**
  (`Failed to find package 'kubeadm' to perform selection 'install'`). El rol quita el `hold`
  antes de instalar para poder cambiar de versión, pero sobre una VM virgen no hay nada que
  desmarcar. Resuelto con `package_facts` y un `when` doble: sólo si el paquete existe **y** su
  versión no es la declarada — la segunda condición es además lo que hace la reejecución
  idempotente, porque si no el par quitar-hold/poner-hold reporta `changed` en cada pasada.
- **Un `jsonpath` dentro de un escalar plegado (`>-`) de YAML se rompe.** El plegado convierte los
  saltos en espacios y Ansible parte el comando por espacios, así que `kubectl` recibió medio
  jsonpath como nombre de nodo: `Error from server (NotFound): nodes ".items[*]}..." not found`.
  Se sustituyó por `-o json` y `from_json` en Jinja, que no depende del quoting del shell.
- **La verificación final medía un estado transitorio.** Los asserts corrían inmediatamente
  después del `join` y veían los workers en `NotReady` con dos segundos de vida: el agente de
  Cilium todavía no había arrancado en ellos. Se añadió un `kubectl wait --for=condition=Ready
  nodes --all` al principio del play de verificación. Es el mismo error de método que la lección
  de la fase anterior, por el otro lado: no basta con verificar el resultado, hay que verificarlo
  **cuando ya es el resultado**.

---

## Fase 5 — GitOps con ArgoCD ⬜

**Qué construye:** el loop que cierra el proyecto — un commit en Git se convierte solo en estado
del cluster.

**Por qué existe:** a partir de aquí `kubectl apply` deja de ser la forma de operar. El cluster
pasa de ser algo que se configura a ser algo que se *declara*, y la diferencia se ve mejor
rompiéndola a propósito: escalar un Deployment a mano y ver cómo Argo lo revierte a lo que dice
Git en menos de un minuto. Eso es `selfHeal`, y es todo el concepto en una frase.

**Decisiones tomadas:**

- **ArgoCD se instala a mano exactamente una vez.** Es la única excepción a la regla anterior:
  alguien tiene que arrancar el motor. Después se gestiona a sí mismo desde Git.
- **Patrón app-of-apps:** una única `Application` raíz apunta al directorio `infrastructure/` y
  descubre el resto por recursión. Se aplica una sola vez y nunca más se toca.
- **`prune: true` y `selfHeal: true` desde el principio.** Sin `prune`, borrar un manifiesto de
  Git no borra nada del cluster y la deriva vuelve por la puerta de atrás.
- **Límites de memoria obligatorios en ArgoCD.** Son cinco componentes y, sin límites, entre
  todos rondan los 800 MB: casi un worker entero. Con límites duros bajan a ~500 MB. El
  `repo-server` es el que más consume (clona repos y renderiza Helm) y es el primero que hay que
  subir si empieza a morir con `OOMKilled`.
- **`applicationset-controller` y `notifications-controller` escalados a 0** mientras no se usen.
- Los límites viven en el `values.yaml` del chart, no en comandos sueltos, para que sobrevivan a
  una reinstalación.

**Verificación / checkpoint:** un commit aparece en el cluster sin tocar la terminal.

**Incidencias:** —

---

## Fase 6 — La plataforma ⬜

**Qué construye:** las piezas transversales que necesita cualquier aplicación: IPs de
LoadBalancer, enrutamiento HTTP, certificados, secretos y almacenamiento. Todo desplegado vía
Git, nada a mano.

**Por qué existe:** sin cloud provider, Kubernetes deja varias promesas a medias. Los `Service`
de tipo `LoadBalancer` se quedan en `<pending>` para siempre, no hay quién emita certificados, y
los secretos no tienen forma segura de vivir en un repo. Esta fase rellena esos huecos.

**Decisiones tomadas:**

- **MetalLB en modo L2**, repartiendo IPs del rango reservado en la Fase 0. Es lo que da sentido
  a `type: LoadBalancer` en bare metal.
- **Gateway API + Envoy Gateway, saltándose Ingress por completo.** Ingress está congelado e
  `ingress-nginx` llegó a fin de vida en marzo de 2026. Además Gateway API ya entró al temario del
  CKA, así que aprenderlo sirve dos veces. Los CRDs se instalan aparte del controlador.
- **Sealed Secrets para los secretos.** Se cifran con la llave pública del cluster y el resultado
  es seguro incluso en un repo público; solo el controlador puede descifrarlos.
  > **La llave maestra del controlador se respalda fuera del repo, en el gestor de contraseñas.**
  > Sin ella, si se pierde el cluster, ningún SealedSecret vuelve a descifrarse nunca. Este es el
  > punto de fallo irreversible del proyecto entero.
- **cert-manager con desafío DNS-01 sobre Cloudflare, no HTTP-01.** No hay puertos abiertos hacia
  el router, así que HTTP-01 no puede funcionar por diseño.
- **`local-path-provisioner` como almacenamiento — y es el destino, no el punto de partida.**
  Longhorn necesita ~500 MB por nodo solo para sus agentes, lo que se comería la mitad del
  cluster; Rook/Ceph está aún más lejos. La limitación asumida conscientemente: un pod queda
  atado al nodo donde se creó su volumen, así que los PV **no son de alta disponibilidad**. Si
  hiciera falta almacenamiento compartido, la salida barata en RAM es NFS desde el propio host de
  Proxmox con `csi-driver-nfs` (~50 MB): externalizar el problema en vez de resolverlo dentro del
  cluster.

**Verificación / checkpoint:** una aplicación de prueba responde por su hostname a través del
Gateway, sobre una IP de MetalLB, y todos los manifiestos están en Git.

**Incidencias:** —

---

## Fase 7 — Exposición pública con Cloudflare Tunnel ⬜

**Qué construye:** acceso desde internet a las aplicaciones del cluster, con TLS válido y sin
abrir un solo puerto en el router.

**Por qué existe:** el port-forwarding clásico expone la IP doméstica, obliga a lidiar con CGNAT
o IP dinámica, y deja el router como superficie de ataque. Un túnel saliente resuelve las tres
cosas a la vez.

**Decisiones tomadas:**

- **Todo el tráfico del túnel apunta a un único destino: el Gateway interno** (`*.dominio` →
  `envoy-gateway-service...:80`). El enrutamiento fino lo hace Gateway API dentro del cluster.
  Así la lógica de rutas vive en un solo sitio, versionada en Git, en vez de duplicarse entre
  Cloudflare y el cluster.
- **El token del túnel entra al repo como SealedSecret**, nunca en claro.
- **`replicas: 2` de cloudflared** con `livenessProbe` contra su endpoint de métricas: es el
  único camino de entrada, no puede ser un punto único de fallo.
- **Regla firme: nada sale a internet sin Cloudflare Access delante, salvo que sea
  deliberadamente público.** Grafana, ArgoCD y cualquier panel administrativo llevan login OIDC
  con una política de acceso. Es gratis hasta 50 usuarios y no requiere escribir código.

**Verificación / checkpoint:** la aplicación de prueba carga desde el móvil con datos móviles,
con certificado válido, y el router no tiene ni un puerto abierto.

**Incidencias:** —

---

## Fase 8 — Observabilidad y backups ⬜

**Qué construye:** métricas, dashboards, backups verificados y actualizaciones automáticas.

**Por qué existe:** cierra el loop operativo. Sin métricas, el modo de fallo característico de
este cluster (presión de memoria) es invisible hasta que algo muere; sin backups probados, el
laboratorio de destrucción de la Fase 9 sería una ruleta rusa.

**Decisiones tomadas:**

- **`metrics-server` primero, antes que cualquier otra cosa.** Son ~50 MB y habilita
  `kubectl top`, que va a ser la herramienta más usada del cluster, además del HPA (material de
  examen). En clusters kubeadm caseros necesita `--kubelet-insecure-tls` por los certificados
  autofirmados del kubelet.
- **VictoriaMetrics en vez de `kube-prometheus-stack`.** Prometheus solo pide 1-2 GB y cada
  worker tiene ~1 GB útil: instalarlo garantiza un bucle de `OOMKilled`. VictoriaMetrics es
  compatible con PromQL y con el formato de scrape de Prometheus, y `vmsingle` opera cómodo en
  200-300 MB con los mismos dashboards y reglas. **No es un downgrade**: es lo que se usaría
  igualmente en cualquier entorno con presión de memoria.
- **Retención de 7 días y `scrapeInterval` de 60s** (en vez de 30s), que reduce cardinalidad y
  por tanto RAM. Presupuesto total del stack: ~900 MB, prácticamente un worker completo. El otro
  queda libre para las aplicaciones.
- **Sin Loki, de momento.** En modo `SingleBinary` pide 300-500 MB que ya no hay. La opción
  honesta es empezar sin agregación de logs: `kubectl logs` y `stern` cubren el 90% de los casos
  en un cluster de tres nodos. Si hiciera falta historial, Grafana Alloy (~80 MB por nodo)
  enviando a Loki Cloud saca la ingesta fuera del cluster.
- **Alertmanager desactivado** inicialmente, por el mismo motivo.
- **Tres capas de backup, no una:** Velero para objetos de Kubernetes, snapshots de etcd (que
  además caen en el examen) y backups de Proxmox a nivel de VM.
- **Un backup no probado no es un backup:** la fase no se da por cerrada hasta haber restaurado
  uno de prueba.
- **Renovate cierra el círculo:** sale una versión nueva de un chart → abre un PR → merge → Argo
  despliega. El ciclo completo de actualización sin tocar la terminal.

**Verificación / checkpoint:** dashboards funcionando, backups automáticos con una restauración
verificada, y PRs automáticos de actualización llegando al repo.

**Incidencias:** —

---

## Fase 9 — Entrenamiento para el CKA ⬜

**Qué construye:** nada. Consume lo construido, rompiéndolo.

**Por qué existe:** es la razón por la que el cluster es kubeadm y no k3s, por la que hay
snapshots en la Fase 4 y por la que el CNI soporta NetworkPolicy. Todo lo anterior estaba
preparando este momento.

**Decisiones tomadas:**

- **Reparto del estudio según los pesos reales del temario:** Troubleshooting 30%, Cluster
  Architecture 25%, Services & Networking 20%, Workloads 15%, Storage 10%. Al menos un tercio del
  tiempo va a troubleshooting.
- **Un escenario de destrucción por sesión**, siempre entre `qm snapshot` y `qm rollback`: parar
  el kubelet, romper el cgroup driver, mover el manifiesto del apiserver, corromper el data-dir
  de etcd, aplicar una NetworkPolicy `deny-all`, llenar el disco de un nodo, adelantar el reloj
  un año para forzar certificados expirados, romper CoreDNS y hacer un `kubeadm upgrade`
  completo.
- **La velocidad se entrena aparte:** el examen son ~17 tareas en 2 horas. Alias, autocompletado
  y `--dry-run=client -o yaml` se configuran en los primeros 30 segundos del examen, y navegar
  `kubernetes.io/docs` rápido es una habilidad en sí misma — es la única documentación permitida.
- **killer.sh se reserva para las últimas 4 semanas**, y no se gastan las dos sesiones seguidas:
  una queda para la semana previa al examen.

**Verificación:** resolver cada escenario sin consultar notas, dentro del tiempo.

**Incidencias:** —

---

## Fase 10 — (Opcional) Cluster API y/o Talos ⬜

**Qué construye:** clusters que se crean y reconcilian a sí mismos desde dentro de Kubernetes.

**Por qué existe:** es el paso siguiente natural cuando OpenTofu + kubeadm ya resultan rutina:
pasar de "declaro VMs" a "declaro clusters", con un controlador que recrea una VM borrada sin que
nadie intervenga.

**Decisiones tomadas:**

- **Requiere apagar el cluster de laboratorio: no hay RAM para dos a la vez.** Lejos de ser un
  obstáculo, es la prueba final del proyecto — obliga a comprobar que el cluster se reconstruye
  desde Git cuando haga falta volver. Si apagarlo da miedo, significa que las Fases 3 a 5 no
  están realmente terminadas.
- **El management cluster de CAPI arranca en `kind`** y luego se hace `clusterctl move` a un
  cluster permanente (el *pivot*).
- **Talos, si se llega, queda como cluster de plataforma**, dejando el de kubeadm exclusivamente
  como laboratorio de destrucción. Talos no sirve para estudiar el CKA precisamente por lo que lo
  hace bueno: no hay SSH, no hay systemd, no hay nada que tocar.

**Verificación:** borrar una VM desde la UI de Proxmox y ver cómo CAPI la recrea sola.

**Incidencias:** —

---

## Línea de tiempo

| Fase | Fecha | Duración real | Notas |
|---|---|---|---|
| 0 — Hardware | ~2026-08 _(confirmar)_ | — | `fio` ejecutado el 2026-08-25: p99 de `fdatasync` = 1,34 ms |
| 1 — Proxmox VE | ~2026-08 _(confirmar)_ | — | ext4/LVM-thin, repos deb822, token `tofu@pve` creado. Rol ampliado el 2026-08-25 |
| 2 — Plantilla cloud-init | 2026-08-24 | ~1 h | Plantilla 9000 sobre `local-lvm`; clon de prueba listo en 16 s |
| 3 — OpenTofu | 2026-08-25 → 2026-08-28 | — | 3 VMs desde código; ciclo `destroy`+`apply` en 48 s; state cifrado verificado |
| 4 — kubeadm | 2026-08-28 | ~2 h | v1.35.8 + Cilium 1.20.1; 3 nodos `Ready`, snapshot `cluster-limpio`. Falta 4.10 (Ansible) |
| 5 — ArgoCD | — | — | |
| 6 — Plataforma | — | — | |
| 7 — Cloudflare Tunnel | — | — | |
| 8 — Observabilidad | — | — | |
| 9 — CKA | — | — | |
| 10 — CAPI / Talos | — | — | Opcional |

---

## Registro de incidencias transversales

Problemas que no pertenecen a una sola fase. El más probable, por diseño de la topología:

> **Cuando el cluster se comporte de forma extraña, sospecha de la memoria antes que de la red.**
> El OOM killer produce síntomas que parecen de conectividad: `kubectl` con timeouts
> intermitentes, nodos parpadeando entre `Ready` y `NotReady`, pods atascados en `Terminating`.
> Es fácil perder horas depurando Cilium por un problema de RAM.
>
> ```bash
> dmesg -T | grep -i "killed process"
> kubectl get pods -A | grep -i OOMKilled
> kubectl top nodes
> free -h
> ```

El segundo, descubierto al preparar la Fase 3 y con efecto directo sobre la Fase 9:

> **Los discos de las VMs son thin-provisioned: llenar uno llena el pool del host.**
> El escenario 7 de la Fase 9 ("llenar el disco de un nodo para provocar `DiskPressure`") parece
> local a una VM y no lo es. Los 65 GB repartidos entre los tres nodos salen de un único thin pool
> de 66,87 GB, y **un thin pool al 100% no devuelve `ENOSPC` limpio: devuelve errores de I/O y
> corrompe todas las VMs a la vez**, incluidas las otras dos y cualquier snapshot que viva ahí.
>
> Ese escenario se practica con un `fallocate` acotado (unos cientos de MB por encima del umbral
> de `evictionHard`), nunca llenando la raíz del invitado. Antes de empezar, mirar el margen:
>
> ```bash
> ssh pve 'lvs pve/data -o lv_name,lv_size,data_percent,metadata_percent --units g'
> ```
>
> Si `data_percent` pasa del 80%, parar y hacer `fstrim` en los invitados antes de seguir.

| Fecha | Síntoma | Causa real | Solución |
|---|---|---|---|
| 2026-08-25 | `fio` daba 1220 MiB/s y `fsync` en nanosegundos | El test escribía en `/tmp`, que es `tmpfs` en Debian 13 | Repetir sobre `/var/lib/vz`: p99 real de 1,34 ms |
| 2026-08-25 | `pveum role modify` → `invalid privilege 'VM.Monitor'` | PVE 9 eliminó `VM.Monitor`, sustituido por `VM.GuestAgent.*` | Usar `VM.GuestAgent.Audit` |
| 2026-08-25 | `install-opentofu.sh` → `The release is signed with the incorrect key: ` | Bug del instalador con GPG 2.4+ y `keyboxd`; la firma es válida | Instalación manual verificando firma y SHA256 aparte |
| 2026-08-28 | `tofu apply` → `dial tcp 192.168.1.20:8006: connect: no route to host`, con `ping` OK | Corte transitorio de red en la máquina de trabajo (túnel VPN activo). El `plan` no lo detecta: con state vacío no consulta la API | Reintentar. Comprobar antes con `curl -sk https://192.168.1.20:8006/`, no con `ping` |
| 2026-08-28 | `Host key verification failed` en `.51`-`.53` tras `destroy`+`apply` | VMs nuevas = host keys nuevas para IPs ya conocidas | `ssh-keygen -R <ip>`. En la Fase 4, Ansible necesitará `host_key_checking = False` |
| 2026-08-28 | El patch de `KubeletConfiguration` se ignoraba sin error | `nodeRegistration.patches` es de `v1beta3`; en `v1beta4` va a nivel raíz. kubeadm sólo emite un warning | Mover `patches:` a la raíz de `InitConfiguration` y comprobar el `--dry-run` |
| 2026-08-28 | CoreDNS en `ContainerCreating`: `failed to find plugin "loopback" in path [/usr/lib/cni]` | containerd de Debian usa `bin_dir=/usr/lib/cni` (vacío); Cilium instala en `/opt/cni/bin` | `bin_dir = "/opt/cni/bin"` en `/etc/containerd/config.toml` + `systemctl restart containerd` |
| 2026-08-28 | `sandbox_image` de containerd = `pause:3.8`, kubeadm espera `pause:3.10.1` | Valor por defecto del containerd de Debian, más antiguo que el que pide k8s 1.35 | Alinear con `kubeadm config images list \| grep pause` antes del `init` |
