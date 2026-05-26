#!/usr/bin/env bash
#
# talos-gen-apps.sh — (re)generate Talos machine configs for the apps-prod cluster.
#
# Mirrors scripts/talos-gen.sh (homelab-prod) but for the second cluster:
#   - separate secrets bundle (talos-apps/secrets.yaml) => distinct cluster PKI
#   - cluster name apps-prod, endpoint = the apps VIP 192.168.216.204
#   - output to talos-apps/{controlplane,worker}.yaml + talosconfig
#
# Talos 1.13 quirk (same as homelab): strip `auto: stable` from the generated
# HostnameConfig so per-node hostname patches merge cleanly.
#
# Usage (from repo root):  bash scripts/talos-gen-apps.sh
set -euo pipefail
cd "$(dirname "$0")/.."

CLUSTER_NAME="apps-prod"
ENDPOINT="https://192.168.216.204:6443"

# Persistent secrets bundle (cluster PKI) — create once, reuse forever.
[ -f talos-apps/secrets.yaml ] || talosctl gen secrets -o talos-apps/secrets.yaml

talosctl gen config "${CLUSTER_NAME}" "${ENDPOINT}" \
  --with-secrets talos-apps/secrets.yaml \
  --output-dir talos-apps --force \
  --with-docs=false --with-examples=false \
  --config-patch @talos-apps/patches/all.yaml \
  --config-patch-control-plane @talos-apps/patches/controlplane.yaml

# Strip `auto: stable` from the HostnameConfig doc so per-node hostname patches apply.
sed -i '/^kind: HostnameConfig$/{n;/^auto: stable$/d;}' talos-apps/controlplane.yaml talos-apps/worker.yaml

echo "OK: regenerated talos-apps/{controlplane,worker}.yaml (HostnameConfig auto stripped)."
