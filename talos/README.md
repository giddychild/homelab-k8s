# talos/

Talos Linux machine configuration. Talos is an immutable, API-driven OS — there
is no SSH and no shell; everything is declarative config applied with `talosctl`.

```
patches/            Config patches (VIP, install disk, Longhorn disk, Cilium-ready)
controlplane.yaml   Generated control-plane config (secrets stripped/encrypted)
worker.yaml         Generated worker config
talosconfig         Cluster admin credential — GITIGNORED
secrets.yaml        Cluster secrets bundle — GITIGNORED
```

Built in Phase 4. Generated with `talosctl gen config`; the VIP and disk layout
come from patches so the base config stays clean and reusable.
