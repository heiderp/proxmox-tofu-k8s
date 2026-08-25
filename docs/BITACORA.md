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

**Incidencias:**

- _Pendiente de confirmar:_ no consta si la prueba de `fio` llegó a ejecutarse. Si aparecen
  timeouts de etcd en la Fase 4, este es el primer sitio donde mirar.

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

## Fase 3 — OpenTofu 🔜

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

**Verificación / checkpoint:** `tofu destroy && tofu apply` devuelve tres VMs accesibles por SSH,
y todo el código está en Git salvo secretos.

**Incidencias:** —

---

## Fase 4 — Cluster Kubernetes con kubeadm ⬜

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

**Verificación / checkpoint:** `kubectl get nodes` muestra tres nodos `Ready`, y existe el
snapshot al que volver.

**Incidencias:** —

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
| 0 — Hardware | ~2026-08 _(confirmar)_ | — | Prueba de `fio` sin registrar |
| 1 — Proxmox VE | ~2026-08 _(confirmar)_ | — | ext4/LVM-thin, repos deb822, token `tofu@pve` creado |
| 2 — Plantilla cloud-init | 2026-08-24 | ~1 h | Plantilla 9000 sobre `local-lvm`; clon de prueba listo en 16 s |
| 3 — OpenTofu | — | — | Siguiente |
| 4 — kubeadm | — | — | |
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

| Fecha | Síntoma | Causa real | Solución |
|---|---|---|---|
| — | — | — | — |
