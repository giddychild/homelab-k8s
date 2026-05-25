#!/usr/bin/env bash
#
# talos-gen.sh — (re)generate the Talos machine configs for homelab-prod.
#
# Produces talos/{controlplane,worker}.yaml + talosconfig, reusing the persistent
# secrets bundle so the cluster identity (PKI) stays stable across regenerations.
#
# Talos 1.13 quirk: the generated `HostnameConfig` document defaults to
# `auto: stable`, and Talos forbids setting both `auto` and `hostname`. Config
# patches can't strip `auto` (they're decoded as typed docs, so `$patch: replace`
# is rejected). So we remove the `auto: stable` line here; the per-node patches
# then set `hostname` via a clean HostnameConfig merge.
#
# Usage (from repo root):  bash scripts/talos-gen.sh
set -euo pipefail
cd "$(dirname "$0")/.."

CLUSTER_NAME="homelab-prod"
ENDPOINT="https://192.168.216.200:6443"

# Persistent secrets bundle (cluster PKI) — create once, reuse forever.
[ -f talos/secrets.yaml ] || talosctl gen secrets -o talos/secrets.yaml

talosctl gen config "${CLUSTER_NAME}" "${ENDPOINT}" \
  --with-secrets talos/secrets.yaml \
  --output-dir talos --force \
  --with-docs=false --with-examples=false \
  --config-patch @talos/patches/all.yaml

# Strip `auto: stable` from the HostnameConfig doc so per-node hostname patches apply.
sed -i '/^kind: HostnameConfig$/{n;/^auto: stable$/d;}' talos/controlplane.yaml talos/worker.yaml

echo "OK: regenerated talos/{controlplane,worker}.yaml (HostnameConfig auto stripped)."
