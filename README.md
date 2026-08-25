# proxmox-tofu-k8s

Cluster de Kubernetes reproducible sobre Proxmox VE, gobernado por GitOps.

**Criterio de éxito:** poder destruir el cluster entero y reconstruirlo desde este repositorio
en menos de 30 minutos, con las aplicaciones expuestas a internet vía Cloudflare Tunnel y sin
un solo puerto abierto en el router.

Objetivo secundario, igual de importante: usar el cluster como laboratorio de destrucción para
preparar el **CKA**.

---

## Estado

| Fase | Qué construye | Estado |
|---|---|---|
| 0 | Verificación de hardware | ✅ |
| 1 | Proxmox VE instalado y endurecido | ✅ |
| 2 | Plantilla cloud-init reutilizable | ✅ |
| 3 | OpenTofu creando las VMs | 🔜 siguiente |
| 4 | Cluster kubeadm funcionando | ⬜ |
| 5 | ArgoCD y el loop de GitOps | ⬜ |
| 6 | Plataforma: red, TLS, secretos | ⬜ |
| 7 | Exposición pública con Cloudflare | ⬜ |
| 8 | Observabilidad y backups | ⬜ |
| 9 | Entrenamiento CKA | ⬜ |
| 10 | (Opcional) Cluster API / Talos | ⬜ |

El detalle de **por qué** existe cada fase, qué se decidió en ella y qué falló por el camino está
en [`docs/BITACORA.md`](docs/BITACORA.md). El procedimiento paso a paso, con comandos, está en
[`docs/roadmap-homelab-k8s.md`](docs/roadmap-homelab-k8s.md).

---

## Stack

| Capa | Herramienta | Nota |
|---|---|---|
| Hipervisor | Proxmox VE 9 (Debian trixie) | ext4 + LVM-thin, no ZFS |
| Imagen base | Debian 13 genericcloud + cloud-init | plantilla VMID 9000 |
| IaC | OpenTofu + provider `bpg/proxmox` | state cifrado con PBKDF2 |
| Config del SO | Ansible | prerequisitos y bootstrap de kubeadm |
| Kubernetes | kubeadm 1.34 | 1 control plane + 2 workers |
| Runtime | containerd | cgroup driver `systemd` |
| CNI | Cilium en modo slim | sin Hubble; con NetworkPolicy |
| GitOps | ArgoCD (app-of-apps) | `selfHeal` + `prune` |
| LoadBalancer | MetalLB (L2) | pool `192.168.1.200-220` |
| Entrada HTTP | Gateway API + Envoy Gateway | no Ingress |
| TLS | cert-manager (DNS-01 Cloudflare) | sin puertos abiertos |
| Secretos | Sealed Secrets | cifrados dentro del repo |
| Exposición | Cloudflare Tunnel + Access | zero trust delante de lo privado |
| Métricas | VictoriaMetrics (`vm-k8s-stack`) | no Prometheus, por RAM |
| Almacenamiento | `local-path-provisioner` | no Longhorn, por RAM |
| Backups | Velero + snapshots de etcd | y backups de Proxmox |
| Actualizaciones | Renovate | PR automático → merge → Argo despliega |

---

## Topología

| Nodo | Rol | vCPU | RAM | Disco | IP |
|---|---|---|---|---|---|
| `k8s-cp-1` | control plane | 2 | 4096 MB | 25 GB | 192.168.1.51 |
| `k8s-wk-1` | worker | 2 | 2048 MB | 20 GB | 192.168.1.52 |
| `k8s-wk-2` | worker | 2 | 2048 MB | 20 GB | 192.168.1.53 |

Rangos reservados fuera del DHCP: `.50-.59` para las VMs, `.200-.220` para MetalLB.

Host: 15,7 GB de RAM, 4 cores, SSD de 119 GB. Los 65 GB de disco salen de un thin pool de
66,87 GB — casi 1:1 a propósito: un thin pool lleno corrompe las tres VMs a la vez, no una.

---

## La restricción que gobierna todo

**8 GB asignados a VMs. ~1 GB útil por worker después de las reservas del kubelet.**

Esa cifra no es un detalle: es la razón detrás de casi todas las decisiones técnicas de este
repositorio. Consecuencia directa:

| Sí cabe | No cabe sin ampliar RAM |
|---|---|
| Cluster kubeadm completo con NetworkPolicies | `kube-prometheus-stack` |
| ArgoCD con límites ajustados | Loki |
| MetalLB, cert-manager, Gateway API | Longhorn / Rook-Ceph |
| Cloudflare Tunnel + apps pequeñas | Segundo cluster simultáneo |
| Todos los escenarios del CKA | Elasticsearch, Keycloak, GitLab |

**Regla operativa nº 1:** cuando algo se comporte raro — `kubectl` con timeouts, nodos
parpadeando entre `Ready`/`NotReady`, pods en `Terminating` — el síntoma parece de red pero
casi siempre es memoria. Antes de tocar Cilium:

```bash
dmesg -T | grep -i "killed process"
kubectl get pods -A | grep -i OOMKilled
kubectl top nodes
```

---

## Mapa del repositorio

```
proxmox-tofu-k8s/
├── infra/          OpenTofu: definición de las VMs sobre Proxmox
├── ansible/        Configuración del SO y bootstrap de kubeadm
│   ├── roles/
│   └── playbooks/
├── gitops/         Todo lo que vive DENTRO de Kubernetes
│   ├── bootstrap/        Application raíz (patrón app-of-apps)
│   ├── infrastructure/   MetalLB, cert-manager, Envoy, Sealed Secrets, cloudflared
│   └── apps/             Aplicaciones
├── scripts/        Utilidades que corren en el host Proxmox, fuera de Kubernetes
└── docs/
    ├── BITACORA.md              Fases, decisiones y trayectoria de lo ejecutado
    └── roadmap-homelab-k8s.md   Procedimiento completo con comandos
```

`TODO.md` (raíz) es la lista de trabajo pendiente. Es local: está en `.gitignore` a propósito.

---

## Reconstrucción desde cero

El día que esto funcione sin consultar notas, el proyecto está terminado:

```bash
cd infra/ && tofu destroy -auto-approve
tofu apply -auto-approve
ansible-playbook -i ../ansible/inventory.yml ../ansible/playbooks/cluster.yml
kubectl apply -f ../gitops/bootstrap/root-app.yaml
```

---

## Reglas de trabajo

1. **Snapshot antes de cada experimento.** Cuesta 10 segundos.
2. **Nada entra al cluster sin pasar por Git** (desde la Fase 5). Si te descubres haciendo
   `kubectl apply`, párate.
3. **Un cambio a la vez.** Cuando algo falle, quieres una sola variable sospechosa.
4. **Toda carga lleva `limits` de memoria.** Sin excepciones.
5. **Antes de instalar cualquier chart, mide su consumo:**
   `kubectl top pods -A --sort-by=memory`.
6. **Fija versiones.** Nada de `latest`.
7. **Verifica los backups restaurando.** Un backup no probado no es un backup.
8. **Documenta la decisión, no el comando.** El comando está en el roadmap; el *porqué* va a
   `docs/BITACORA.md`.
