🇬🇧 **English** · 🇪🇸 [Español](README.es.md)

# proxmox-tofu-k8s

A reproducible Kubernetes cluster on Proxmox VE, governed by GitOps.

**Definition of done:** destroy the entire cluster and rebuild it from this repository in under
30 minutes, with applications reachable from the internet through a Cloudflare Tunnel and not a
single port open on the router.

Secondary goal, just as important: use the cluster as a demolition lab to prepare for the **CKA**.

---

## Status

| Phase | What it builds | Status |
|---|---|---|
| 0 | Hardware verification | ✅ |
| 1 | Proxmox VE installed and hardened | ✅ |
| 2 | Reusable cloud-init template | ✅ |
| 3 | OpenTofu creating the VMs | ✅ |
| 4 | Working kubeadm cluster | ✅ |
| 5 | ArgoCD and the GitOps loop | 🔜 in progress |
| 6 | Platform: networking, TLS, secrets | ⬜ |
| 7 | Public exposure via Cloudflare | ⬜ |
| 8 | Observability and backups | ⬜ |
| 9 | CKA training | ⬜ |
| 10 | (Optional) Cluster API / Talos | ⬜ |

Today: 3 nodes `Ready` with Cilium, rebuildable from nothing in **4 min 41 s** — `tofu destroy` +
`apply` (53 s) plus a single Ansible playbook run (3 min 48 s). The GitOps loop is closed: ArgoCD
manages itself from this repository, and a commit reaches the cluster without touching a terminal.
What is missing is the first application deployed that way.

The **why** behind each phase, what was decided and what broke along the way lives in
[`docs/BITACORA.md`](docs/BITACORA.md) (Spanish). The step-by-step procedure, with commands, is in
[`docs/roadmap-homelab-k8s.md`](docs/roadmap-homelab-k8s.md) (Spanish).

---

## What went wrong

A homelab teaches more through what it breaks than through what it installs. Three from the full
log:

- **CoreDNS stuck in `ContainerCreating`:** `failed to find plugin "loopback" in path
  [/usr/lib/cni]`. Debian's containerd looks for CNI binaries in `/usr/lib/cni`, which is empty;
  Cilium installs them into `/opt/cni/bin`. Looks like a CNI failure, is a distro default.
- **A kubelet patch silently ignored:** in kubeadm's `v1beta4` API, `patches:` belongs at the root
  of `InitConfiguration`. Under `nodeRegistration` — where it lived in `v1beta3` — it is dropped
  with nothing but a warning, and the memory reservations simply never apply.
- **`fio` reporting 1220 MiB/s and `fsync` in nanoseconds:** the test was writing to `/tmp`, which
  is `tmpfs` on Debian 13. Invalid measurement. Re-run against the real disk: `fdatasync` p99 =
  1.34 ms.

Full log, with root cause and fix for each:
[incident table](docs/BITACORA.md#registro-de-incidencias-transversales).

---

## Stack

| Layer | Tool | Version | Note |
|---|---|---|---|
| Hypervisor | Proxmox VE (Debian trixie) | 9 | ext4 + LVM-thin, no ZFS |
| Base image | Debian genericcloud + cloud-init | 13 | template VMID 9000 |
| IaC | OpenTofu + `bpg/proxmox` provider | 1.12.6 / 0.111.1 | state encrypted with PBKDF2 |
| OS config | Ansible | 14.3.1 | prerequisites and kubeadm bootstrap |
| Kubernetes | kubeadm | 1.35.8 | 1 control plane + 2 workers |
| Runtime | containerd | 1.7.24 | `systemd` cgroup driver |
| CNI | Cilium, slim mode | 1.20.1 | no Hubble; NetworkPolicy enabled |
| GitOps | ArgoCD (app-of-apps) | chart 10.7.0 · v3.5.2 | `selfHeal` + `prune` |
| LoadBalancer | MetalLB (L2) | — | pool `192.168.1.200-220` |
| HTTP ingress | Gateway API + Envoy Gateway | — | not Ingress |
| TLS | cert-manager (Cloudflare DNS-01) | — | no open ports |
| Secrets | Sealed Secrets | — | encrypted inside the repo |
| Exposure | Cloudflare Tunnel + Access | — | zero trust in front of private panels |
| Metrics | VictoriaMetrics (`vm-k8s-stack`) | — | not Prometheus, for RAM reasons |
| Storage | `local-path-provisioner` | — | not Longhorn, for RAM reasons |
| Backups | Velero + etcd snapshots | — | plus Proxmox backups |
| Updates | Renovate | — | automated PR → merge → Argo deploys |

No version = not installed yet. Everything pinned lives in
[`ansible/group_vars/all.yml`](ansible/group_vars/all.yml) and the `values.yaml` files under
[`gitops/infrastructure/`](gitops/infrastructure/) — never in loose commands.

---

## Topology

| Node | Role | vCPU | RAM | Disk | IP |
|---|---|---|---|---|---|
| `k8s-cp-1` | control plane | 2 | 4096 MB | 25 GB | 192.168.1.51 |
| `k8s-wk-1` | worker | 2 | 2048 MB | 20 GB | 192.168.1.52 |
| `k8s-wk-2` | worker | 2 | 2048 MB | 20 GB | 192.168.1.53 |

Ranges reserved outside DHCP: `.50-.59` for the VMs, `.200-.220` for MetalLB.

Host: 15.7 GB RAM, 4 cores, 119 GB SSD. The 65 GB of disk come out of a 66.87 GB thin pool —
nearly 1:1 on purpose: a full thin pool corrupts all three VMs at once, not just one.

---

## The constraint that governs everything

**8 GB allocated to VMs. ~1 GB usable per worker after kubelet reservations.**

That number is not a footnote: it is the reason behind almost every technical decision in this
repository. Direct consequence:

| Fits | Does not fit without more RAM |
|---|---|
| Full kubeadm cluster with NetworkPolicies | `kube-prometheus-stack` |
| ArgoCD with tuned limits | Loki |
| MetalLB, cert-manager, Gateway API | Longhorn / Rook-Ceph |
| Cloudflare Tunnel + small apps | A second concurrent cluster |
| Every CKA scenario | Elasticsearch, Keycloak, GitLab |

**Operating rule #1:** when something behaves strangely — `kubectl` timing out, nodes flapping
between `Ready`/`NotReady`, pods stuck in `Terminating` — the symptom looks like networking but
it is almost always memory. Before touching Cilium:

```bash
dmesg -T | grep -i "killed process"
kubectl get pods -A | grep -i OOMKilled
kubectl top nodes
```

---

## Repository map

```
proxmox-tofu-k8s/
├── infra/          OpenTofu: the VMs, defined on Proxmox
├── ansible/        OS configuration and kubeadm bootstrap
│   ├── roles/
│   └── playbooks/
├── gitops/         Everything that lives INSIDE Kubernetes
│   ├── bootstrap/        Root Application (app-of-apps pattern)
│   ├── infrastructure/   MetalLB, cert-manager, Envoy, Sealed Secrets, cloudflared
│   └── apps/             Applications
├── scripts/        Utilities that run on the Proxmox host, outside Kubernetes
└── docs/
    ├── BITACORA.md              Phases, decisions and the trail of what was executed
    └── roadmap-homelab-k8s.md   Full procedure with commands
```

`TODO.md` (root) is the working list. It is local: deliberately in `.gitignore`.

---

## Rebuild from scratch

The day this works without consulting notes, the project is done:

```bash
cd infra/ && tofu destroy -auto-approve
tofu apply -auto-approve
ansible-playbook -i ../ansible/inventory.yml ../ansible/playbooks/cluster.yml
kubectl apply -f ../gitops/bootstrap/root-app.yaml
```

---

## Working rules

1. **Snapshot before every experiment.** It costs 10 seconds.
2. **Nothing enters the cluster without going through Git** (from Phase 5 on). If you catch
   yourself running `kubectl apply`, stop.
3. **One change at a time.** When something breaks, you want a single suspect.
4. **Every workload carries memory `limits`.** No exceptions.
5. **Measure a chart's footprint before installing it:**
   `kubectl top pods -A --sort-by=memory`.
6. **Pin versions.** No `latest`.
7. **Verify backups by restoring them.** An untested backup is not a backup.
8. **Document the decision, not the command.** The command is in the roadmap; the *why* goes to
   `docs/BITACORA.md`.
