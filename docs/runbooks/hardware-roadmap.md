# Hardware roadmap — eliminating SPOFs

Current state: one R730XD, one HDD pool, one ESXi host.  Three independent
SPOFs stacked.  The platform recovers from software failures gracefully
(verified DR drill + chaos test) but a dead PSU / mobo / RAID controller =
total downtime until parts arrive.

This is the phased hardware plan that turns "highest-effort recovery" into
"transparent failover."

## Phase A — Storage performance + durability (~$300–500, low-risk)

**Problem:** Longhorn `replicas: 3` is logical-HA on top of a single
physical spindle.  All three replicas land on the same drive.  Drive failure
= total data loss between Velero snapshots (up to 24h RPO).  Performance is
also gated by HDD seek time — Postgres-heavy apps (money, learnquest) feel it.

**Fix:** add 2× consumer NVMe (1TB Samsung 990 Pro / Crucial T500) on
PCIe adapters → dedicated Longhorn replica pool.  Keep the HDD pool for
cold storage (Velero local cache, Loki long-term).

**Wins:**
- Disk failure no longer = data loss (replicas now span 2 distinct drives).
- 10-50× IOPS for Postgres.
- Frees the HDD for sequential-only workloads it's good at.

**Effort:** 1 evening.  Add an `nvme` Longhorn StorageClass, migrate the
money + learnquest PVCs (CNPG handles this gracefully via cluster recreate
with backup restore).

## Phase B — UPS + battery monitoring (~$200, low-risk)

**Problem:** brownout = unclean shutdown.  Talos handles abrupt poweroff
well; Postgres barman + Longhorn snapshots, less so.

**Fix:** APC SmartUPS 1500VA + NUT (Network UPS Tools).  Plumb shutdown
signal to ESXi which gracefully suspends VMs.

**Wins:** ~10 min of brownout ride-through, clean shutdown on extended outage.

**Effort:** half a day (rack the UPS, install NUT on ESXi).

## Phase C — Second ESXi host (~$1500-2500, high-leverage)

**Problem:** single host = single failure domain.  Software resilience can
only carry you so far.

**Options:**

| Path                                              | Pros                                                                | Cons                                              |
|---------------------------------------------------|---------------------------------------------------------------------|---------------------------------------------------|
| **Used R730XD twin** (~$800)                      | Matched HW = same Talos schematic, easy capacity planning            | Same vintage = same EOL                          |
| **R740XD** (~$1500)                               | Newer CPU (Cascade Lake), more PCIe lanes, supports NVMe natively   | Different schematic, dual-host config drift risk |
| **2× SFF builds** (Intel NUC i7 / Minisforum 745i) | Quiet, low power, fits next to the R730XD                            | NIC/PCI passthrough limited                      |

**Recommendation:** R740XD if budget allows; used R730XD if not.  Stand it
up with:
- ESXi licensed via VMware User World (free for non-prod homelab usage)
- Same Talos image (rebuild via schematic), 2 more workers + 1 more CP
  (cluster becomes 4 CP / 5 worker — odd CP count keeps etcd quorum on
  one-host failures)
- Move 1 worker VM to the new host
- Migrate Longhorn replicas to land 1 per host

**Wins:**
- Host-level HA: kill power on box 1, workloads reschedule.
- Real Longhorn replica distribution (1 per host, not 3 per drive).
- Maintenance windows without downtime (drain box 1, patch ESXi, return,
  drain box 2).

**Effort:** 1-2 weekends.

## Phase D — Network redundancy (~$200, low-risk)

**Problem:** single Orbi router = SPOF for internet + LAN.  Single switch
between ESXi and Orbi = SPOF for cluster.

**Fix:** the VLAN switchover (see `vlan-segmentation.md`) is the natural
moment for this — pick a router that does dual-WAN failover (UDM-SE, pfSense
with 2 ISPs) + run a second switch in MLAG.

**Wins:** ISP failover, switch failure transparent to nodes.

**Effort:** comes "for free" with Phase D of the VLAN migration if you
choose the gear right.

## Phase E — Off-site replica (~$0-50/mo, very low-risk)

**Problem:** Velero + etcd snapshots live in AWS S3 — good.  But what if
you stop paying AWS, or AWS S3 has a region-wide bad day during YOUR DR?

**Fix:** Velero supports multiple BackupStorageLocations.  Add a second BSL
pointing at:
- Backblaze B2 (~$6/TB/month, cheapest), OR
- A Raspberry Pi + USB-HDD at a family member's house (free, syncs nightly
  via Tailscale + restic)

**Wins:** survive both a R730XD fire AND an AWS outage during DR.

**Effort:** 1 evening for B2; 1 weekend for the off-site Pi.

## Phase order — recommended

1. **Phase A** (NVMe) — biggest day-to-day quality-of-life win, cheap.
2. **Phase B** (UPS) — protects everything else.
3. **Phase E** (off-site replica) — cheap insurance.
4. **Phase D** (network redundancy) — bundled with VLAN work.
5. **Phase C** (second host) — biggest cost, biggest resilience gain; do
   last because it requires sustained operational attention.

## Total target spend over 12 months

~$2500-3500 for the full picture.  $500 (Phase A + B) gets you 80% of the
resilience for ~15% of the cost.
