# Home network VLAN segmentation plan

Current state: flat L2 network on `192.168.216.0/24`.  The R730XD (Kubernetes
nodes, ESXi mgmt, iDRAC), family laptops/phones, Apple TV, IoT devices, and
guest Wi-Fi all share the same broadcast domain.  A compromised TV firmware
can ARP-spoof the Talos API, port-scan iDRAC, or talk to Vault's LoadBalancer
IP directly.

Goal: split the LAN into VLANs so the cluster sits on its own segment with
firewall rules between zones.

## Target topology

| VLAN ID | Subnet              | Purpose                                   | Trust |
|---------|---------------------|-------------------------------------------|-------|
| 10      | 192.168.10.0/24     | **Management** — iDRAC, ESXi mgmt, mgmt-jump | high  |
| 20      | 192.168.20.0/24     | **Cluster** — Talos VMs, LB-IPAM range, Longhorn | high  |
| 30      | 192.168.30.0/24     | **Trusted** — your laptop, work devices   | med   |
| 40      | 192.168.40.0/24     | **Family** — phones, family laptops       | low   |
| 50      | 192.168.50.0/24     | **IoT** — TVs, smart bulbs, Echo, printer | untrusted |
| 60      | 192.168.60.0/24     | **Guest** — visitor Wi-Fi                 | untrusted |

## Inter-VLAN firewall rules (default-deny between VLANs)

| From → To           | Allow                                                              |
|---------------------|--------------------------------------------------------------------|
| Mgmt (10) → Cluster (20) | all                                                           |
| Mgmt (10) → Trusted (30) | all                                                           |
| Cluster (20) → Mgmt (10) | NTP, DNS — that's it                                          |
| Cluster (20) → Internet  | 443, 80 (image pulls, Let's Encrypt webhooks)                 |
| Trusted (30) → Cluster (20) | 443, 6443, 22 (Talos API, kube API, ssh to mgmt-jump)      |
| Trusted (30) → Mgmt (10) | 443 (iDRAC, ESXi), 22                                         |
| Family (40) → anywhere    | Internet only                                                |
| IoT (50) → anywhere       | Internet only, NO local subnets                              |
| Guest (60) → anywhere     | Internet only, NO local subnets                              |

Tailscale exits override all of this when you connect from the Tailnet —
that path bypasses VLAN ACLs because each device is its own peer.

## Hardware checklist

| Item                                                | Have? | Notes                                            |
|-----------------------------------------------------|-------|--------------------------------------------------|
| 8-port managed gigabit switch (VLAN-aware)          | ✅    | The TP-Link/Netgear you just installed.           |
| Router that supports VLAN trunks + per-VLAN firewall| ⚠     | Orbi consumer router does **NOT** support this well. |
| Wi-Fi APs with per-SSID VLAN tagging                | ⚠     | Orbi supports limited guest SSID isolation, not arbitrary VLAN tagging |

**Recommendation:** the Orbi is the blocker.  Options:

1. **Replace Orbi with a UniFi Dream Machine SE** (~$500) — full per-VLAN
   firewall + IDS/IPS + per-SSID VLAN.  Best UX for this scale.
2. **Keep Orbi for Wi-Fi, add a pfSense/OPNsense mini-PC** ($200) as the
   gateway.  Orbi becomes a dumb AP behind it.  Best $/feature.
3. **Mikrotik hAP ax3** ($170) — RouterOS handles VLANs + firewall; tighter
   learning curve than pfSense.

## Migration plan (when you're ready)

1. Pick option 1, 2, or 3.  Document the switchover window (likely 2-4 hr).
2. Stand up the new gateway with VLAN definitions ABOVE but no clients yet.
3. Move the R730XD VLAN (ESXi mgmt port, iDRAC port) to VLAN 10 / VLAN 20.
4. Update Talos `machine.network` if interface name changes (it won't if
   you tag at the switch port, not on the VM).
5. Move mgmt-jump to VLAN 10.
6. Update Cilium LB-IPAM range to the new cluster CIDR.  Update DNS in
   Cloudflare (`*.apps.giddyland.net` A record).
7. Move family/IoT/guest Wi-Fi to new SSIDs on tagged VLANs.

**Estimated downtime for the homelab:** ~1 hour during the gateway swap +
~30 min for the Cilium LB-IPAM CIDR change (need to re-announce ARP).

## Until you do this

The cluster is reachable from every device on `192.168.216.0/24`.  The
mitigation today is:

- No port-forwards on the Orbi (verified).
- Vault is the only sensitive service on a LoadBalancer; it requires the
  unseal key + a token, so LAN reachability alone isn't a takeover.
- Cilium NetworkPolicies (after the rollout in
  `network-policy-rollout.md`) shrink east-west blast radius even though
  north-south is flat.
- Tailscale is on a separate auth plane.

So you're not naked — but a compromised IoT device today CAN port-scan iDRAC,
which on default creds is a full server takeover.  Confirm iDRAC creds are
NOT default:

```sh
# From mgmt-jump:
curl -k -u root:calvin https://<idrac-ip>/redfish/v1/
# If this returns 200, fix iDRAC creds TODAY.
```
