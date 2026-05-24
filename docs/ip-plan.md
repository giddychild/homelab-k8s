# IP addressing plan

**Subnet:** `192.168.216.0/24` (mask `255.255.255.0`) — flat network behind the Orbi mesh.

> ✅ **CONFIRMED (2026-05-23):** Orbi RBR850 gateway = `192.168.216.1`, mask `255.255.255.0`.
> Current DHCP pool = **`192.168.216.2 – .254` (entire range)** — collides with our static IPs.
> **Required change before provisioning:** narrow Orbi DHCP to `192.168.216.100 – .200`,
> freeing `.2–.99` and `.201–.254` for static infrastructure. No address reservations set yet.

## Reservations

| Purpose | IP / Range | Status |
|---|---|---|
| Gateway (Orbi router) | `192.168.216.1` | ✅ confirmed (RBR850) |
| Orbi Satellite-1 | `192.168.216.19` | existing (avoid) |
| Orbi Satellite-2 | `192.168.216.22` | existing (avoid) |
| ESXi host (vmk0) | `192.168.216.216` | existing — do not change |
| `mgmt-jump` VM | `192.168.216.30` | planned |
| **Talos API VIP** | `192.168.216.40` | planned — `kubectl` endpoint |
| `talos-cp-01` | `192.168.216.41` | planned |
| `talos-cp-02` | `192.168.216.42` | planned |
| `talos-cp-03` | `192.168.216.43` | planned |
| `talos-wk-01` | `192.168.216.51` | planned |
| `talos-wk-02` | `192.168.216.52` | planned |
| `talos-wk-03` | `192.168.216.53` | planned |
| **Cilium LoadBalancer pool** | `192.168.216.201–.220` | planned — Services/Ingress |
| Orbi DHCP (currently `.2–.254`) | narrow to `192.168.216.100–.200` | ⚠️ must shrink before build |

## Internal (Kubernetes-only) ranges

| Purpose | CIDR | Notes |
|---|---|---|
| Pod network | `10.244.0.0/16` | overlay — never on the LAN |
| Service network | `10.96.0.0/12` | cluster-internal only |

## Rules

- Cluster node IPs are **static** and **outside** the Orbi DHCP pool — a DHCP reassignment to a node would break the cluster.
- The LoadBalancer pool must also be outside DHCP; Cilium announces these via ARP.
