# IP addressing plan

**Subnet:** `192.168.216.0/24` (mask `255.255.255.0`) — flat network behind the Orbi mesh.

> ✅ **CONFIRMED:** Orbi RBR850 gateway `192.168.216.1`. Original DHCP pool was `.2–.254`.
> **Strategy:** existing home devices and the Orbi satellites sit in the *low* range, so
> rather than disturb them, we **cap the DHCP pool at `.199`** and place all cluster
> static IPs in the freed *high* range `.200+`. Only the rarely-used top of the pool
> changes, so existing devices keep their addresses — minimal disruption.

## Reservations

| Purpose | IP / Range | Status |
|---|---|---|
| Gateway (Orbi router) | `192.168.216.1` | ✅ confirmed (RBR850) |
| Orbi Satellite-1 / -2 | `192.168.216.19` / `.22` | existing |
| ESXi host (vmk0) | `192.168.216.216` | existing — do not change |
| `mgmt-jump` VM | `192.168.216.30` | ✅ Orbi reservation (inside pool — fine) |
| **Orbi DHCP pool** | `192.168.216.2 – .199` | ✅ END capped at `.199` |
| **Talos API VIP** | `192.168.216.200` | floating `kubectl` endpoint |
| `talos-cp-01 / 02 / 03` | `192.168.216.201 / .202 / .203` | static (Talos config) |
| `talos-wk-01 / 02 / 03` | `192.168.216.211 / .212 / .213` | static (Talos config) |
| **Cilium LoadBalancer pool** | `192.168.216.230 – .250` | Services / Ingress |

> **Public DNS (as-built):** a Cloudflare wildcard `A *.apps.giddyland.net → 192.168.216.230` (DNS-only, never proxied) resolves all service hostnames to the ingress LB. Public DNS → private IP, so certs are publicly-trusted (Let's Encrypt via DNS-01) but the services are reachable only on the LAN/Tailscale.

## Internal (Kubernetes-only) ranges

| Purpose | CIDR | Notes |
|---|---|---|
| Pod network | `10.244.0.0/16` | overlay — never on the LAN |
| Service network | `10.96.0.0/12` | cluster-internal only |

## Rules

- Cluster node IPs and the VIP are **static and above the DHCP ceiling (`.199`)**, so Orbi can never hand them to another device.
- The **VIP (`.200`) floats** between control-plane nodes (Talos manages it via ARP); it must be outside DHCP — hence the `.199` cap.
- `mgmt-jump` keeps its `.30` reservation (a reservation inside the pool is normal and fine).
