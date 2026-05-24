# Architecture

## Target topology

```
                          HOME NETWORK (Orbi mesh)
                                   │
                    ┌──────────────┴───────────────┐
                    │   Netgear Orbi RBS850 (router) │  192.168.216.1
                    │   2 satellites @ .19 / .22     │  (DHCP + gateway)
                    └──────────────┬───────────────┘
                                   │
                    ┌──────────────┴───────────────┐
                    │  Managed gigabit switch (NEW)  │  (replaces FS105 10/100)
                    │  TL-SG108E / GS308E, 802.1Q    │
                    └──────────────┬───────────────┘
                                   │ 1 GbE uplink (vmnic0)
        ╔══════════════════════════╧══════════════════════════════╗
        ║         DELL R730XD  —  ESXi 7.0 U3 (Ent. Plus)          ║
        ║         vmk0 mgmt = 192.168.216.216                      ║
        ║                                                          ║
        ║   vSwitch0 → "VM Network" port group (flat, untagged)    ║
        ║   ┌────────────────────────────────────────────────┐    ║
        ║   │  CONTROL PLANE (HA — etcd quorum of 3)          │    ║
        ║   │   talos-cp-01/02/03  4 vCPU / 16 GB / 60 GB     │    ║
        ║   │        ▲ Talos VIP 192.168.216.40 = API endpoint│    ║
        ║   ├────────────────────────────────────────────────┤    ║
        ║   │  WORKERS                                        │    ║
        ║   │   talos-wk-01/02/03  8 vCPU / 48 GB             │    ║
        ║   │        60 GB OS + 100 GB Longhorn disk          │    ║
        ║   ├────────────────────────────────────────────────┤    ║
        ║   │  mgmt-jump  2 vCPU / 4 GB / 40 GB  (tooling)    │    ║
        ║   └────────────────────────────────────────────────┘    ║
        ║   datastore1: 2.6 TB VMFS6 (PERC H730, HDD), ~1.1 TB free║
        ║   (shared with 17 pre-existing VMs — DO NOT DISTURB)     ║
        ╚══════════════════════════════════════════════════════════╝
```

## Key design decisions & rationale

- **3 control-plane nodes** — etcd needs an odd number for quorum; 3 tolerates 1 failure. This is what makes the control plane Highly Available.
- **Talos VIP for the API** — a floating IP shared by the 3 control-plane nodes; `kubectl` keeps working if one node dies. Simpler than a separate load balancer for a single-host homelab.
- **3 workers** — enough for Longhorn 3-way replication and to drain one node for maintenance.
- **All nodes are VMs on one host** — east-west traffic (etcd, Longhorn, pod-to-pod) stays in the in-RAM vSwitch and is NOT limited by the physical NIC. The uplink only matters for egress (image pulls, remote access).
- **Cilium replaces kube-proxy** — eBPF dataplane, network policy, and LB-IPAM (announces LoadBalancer IPs to the LAN via ARP) so apps get reachable IPs with no port-forwarding.
- **Longhorn on a dedicated disk per worker** — isolates replicated storage I/O and failure domain from the OS disk.

## Known constraints

- **Storage is all HDD** on a single datastore shared with 17 existing VMs. etcd is fsync-sensitive; an SSD for the control plane is a recommended future upgrade. Topology is right-sized to fit ~1.1 TB free (thin-provisioned).
- **Flat network only.** The Orbi (consumer mesh) routes a single subnet and cannot do inter-VLAN routing. True VLAN segmentation is deferred to a future pfSense/OPNsense-VM-as-router phase. See `decisions/0001-use-managed-gigabit-switch.md`.

## Internal (cluster-only) networks

- Pod CIDR: `10.244.0.0/16`
- Service CIDR: `10.96.0.0/12`

These are overlay networks internal to Kubernetes and never appear on the LAN.
