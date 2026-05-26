#!/usr/bin/env bash
#
# vault-apps-approle.sh — set up cross-cluster Vault access for apps-prod.
#
# apps-prod reads secrets from the homelab Vault. It can't use the homelab's
# Kubernetes auth (bound to the homelab cluster's identity), so we use an
# AppRole: this creates a read-only policy + AppRole in Vault, then writes the
# role_id/secret_id as a bootstrap Secret onto apps-prod. Secrets never leave
# your shell. Uses the Vault HTTP API (no vault CLI required).
#
# Run on mgmt-jump:
#   export VAULT_ADDR='https://vault.apps.giddyland.net'
#   export VAULT_TOKEN='<your-vault-root-or-admin-token>'
#   bash scripts/vault-apps-approle.sh
#
# Requires: curl, python3, kubectl, and ~/.kube/apps-prod.kubeconfig.
set -euo pipefail

: "${VAULT_ADDR:?set VAULT_ADDR, e.g. https://vault.apps.giddyland.net}"
: "${VAULT_TOKEN:?set VAULT_TOKEN (Vault root/admin token)}"
KUBECONFIG_APPS="${KUBECONFIG_APPS:-$HOME/.kube/apps-prod.kubeconfig}"
TH=(-sS -H "X-Vault-Token: ${VAULT_TOKEN}")

jget() { python3 -c "import json,sys; print(json.load(sys.stdin)['data']['$1'])"; }

echo "==> Vault: ${VAULT_ADDR}"
curl -sS --max-time 10 "${VAULT_ADDR}/v1/sys/health" >/dev/null || { echo "cannot reach Vault"; exit 1; }

echo "==> Enable AppRole auth (idempotent)"
curl "${TH[@]}" -X POST -d '{"type":"approle"}' "${VAULT_ADDR}/v1/sys/auth/approle" >/dev/null 2>&1 \
  && echo "   enabled" || echo "   (already enabled)"

echo "==> Write policy 'apps-prod-read'"
POLICY='path "secret/data/cloudflare-dns"  { capabilities = ["read"] }
path "secret/data/money/*"         { capabilities = ["read"] }
path "secret/metadata/money/*"     { capabilities = ["read", "list"] }'
python3 -c "import json,sys; print(json.dumps({'policy': sys.stdin.read()}))" <<<"${POLICY}" \
  | curl "${TH[@]}" -X PUT -d @- "${VAULT_ADDR}/v1/sys/policies/acl/apps-prod-read"

echo "==> Create/Update AppRole role 'apps-prod'"
curl "${TH[@]}" -X POST \
  -d '{"token_policies":"apps-prod-read","token_ttl":"1h","token_max_ttl":"4h","secret_id_ttl":0,"secret_id_num_uses":0}' \
  "${VAULT_ADDR}/v1/auth/approle/role/apps-prod"

ROLE_ID="$(curl "${TH[@]}" "${VAULT_ADDR}/v1/auth/approle/role/apps-prod/role-id" | jget role_id)"
SECRET_ID="$(curl "${TH[@]}" -X POST "${VAULT_ADDR}/v1/auth/approle/role/apps-prod/secret-id" | jget secret_id)"
[ -n "${ROLE_ID}" ] && [ -n "${SECRET_ID}" ] || { echo "failed to get role_id/secret_id"; exit 1; }

echo "==> Write bootstrap Secret 'vault-approle' to apps-prod (external-secrets ns)"
kubectl --kubeconfig "${KUBECONFIG_APPS}" create namespace external-secrets 2>/dev/null || true
kubectl --kubeconfig "${KUBECONFIG_APPS}" -n external-secrets create secret generic vault-approle \
  --from-literal=role_id="${ROLE_ID}" \
  --from-literal=secret_id="${SECRET_ID}" \
  --dry-run=client -o yaml | kubectl --kubeconfig "${KUBECONFIG_APPS}" apply -f -

echo "OK: AppRole 'apps-prod' ready; bootstrap Secret 'vault-approle' written to apps-prod."
