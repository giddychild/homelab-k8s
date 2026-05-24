# ADR 0001 — Replace 10/100 switch with a managed gigabit switch

- **Status:** Accepted
- **Date:** 2026-05-23

## Context

The R730XD's only active NIC (`vmnic0`) negotiated at **100 Mbps**. Investigation
found the server is cabled through a **Netgear ProSafe FS105**, a 10/100 (Fast
Ethernet) switch, before reaching the Netgear Orbi mesh. The FS105 caps all
traffic at 100 Mbps regardless of cabling.

All cluster nodes are VMs on a single ESXi host, so heavy east-west traffic stays
in the in-RAM vSwitch; the physical link only limits egress (image pulls, remote
access, backups). The project also lists VLAN segmentation as a goal.

## Decision

Replace the FS105 with an **8-port web-managed gigabit switch** (TP-Link TL-SG108E
or Netgear GS308E). This restores 1 GbE and adds 802.1Q VLAN capability and room
to bond the R730XD's 4 NICs later.

## Consequences

- Egress speed returns to gigabit; image pulls and remote access stop being slow.
- The Orbi is a consumer mesh and **cannot route between VLANs** (single subnet),
  so the network stays **flat (`192.168.216.0/24`)** for now.
- True VLAN segmentation is **deferred** to a future phase running pfSense/OPNsense
  as a router VM on this ESXi host; the managed switch is a prerequisite for that.

## Alternatives considered

- *Plug server directly into an Orbi gigabit port* — free, but no VLANs and consumes an Orbi port.
- *Unmanaged gigabit switch* — fixes speed but no VLAN path.
- *Stay on 100 Mbps* — functional but below the production-grade bar and blocks VLAN goal.
