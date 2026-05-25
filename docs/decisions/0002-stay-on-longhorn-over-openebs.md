# ADR 0002 — Stay on Longhorn for persistent storage (vs OpenEBS)

- **Status:** Accepted
- **Date:** 2026-05-25

## Context

Longhorn provides the cluster's replicated block storage (3 replicas by default,
backing Vault, n8n, Grafana, etc.). A peer suggested evaluating **OpenEBS**,
based on past friction they'd had with Longhorn rather than a specific fit for
this environment.

Current storage reality: all three worker VMs (`talos-wk-01/02/03`) run on a
**single ESXi host** backed by a **single spinning HDD** (`datastore1`). In this
topology Longhorn's cross-node replication lands all replicas on the same
physical spindle — so it adds write amplification without delivering real
durability (the disk and host remain single points of failure). The performance
limiter is the HDD, not the CSI driver. An SSD upgrade is already planned.

## Decision

**Keep Longhorn. Do not migrate to OpenEBS.** Leave the replica count at **3**.

The bottleneck is physics (one spinning disk), which a driver swap does not fix.
Migrating live PVCs (Vault, n8n, Grafana) carries real risk for no functional
gain. Longhorn also offers more of the "platform storage" feature set we want to
demonstrate — snapshots, backup-to-S3/NFS, volume expansion, and a UI.

OpenEBS's flagship replicated engine (**Mayastor**) targets **NVMe + hugepages**
and would perform *worse* on an HDD; its **Local PV** engine is lighter but drops
the replication/snapshot/backup features — essentially "Longhorn minus what we'd
grow into." Neither is a compelling replacement on the current hardware.

## Consequences

- No migration; storage stack and GitOps definitions are unchanged.
- Replicas stay at 3 (accepted as redundant on a single disk for now; revisit when
  hardware provides real disk/host separation, at which point replication becomes
  genuinely useful).
- The real performance lever remains the **planned SSD** (ideally its own
  datastore) — it benefits Longhorn or any engine equally.
- Replicated storage (Longhorn, or Mayastor on NVMe) is re-evaluated only when a
  second/third host or per-node dedicated disks exist.

## Alternatives considered

- *Migrate to OpenEBS Mayastor* — built for NVMe; inappropriate on a spinning disk.
- *Migrate to OpenEBS Local PV* — lower overhead but loses snapshots/backups/UI; no real win over reducing Longhorn replicas.
- *Add OpenEBS Local PV as a second StorageClass* — viable later to showcase
  "right tool per workload," but adds an operational component for no current need.
- *Drop Longhorn replicas to 1 on the single disk* — would cut write amplification,
  but we chose to keep 3 and address the bottleneck via the SSD instead.
