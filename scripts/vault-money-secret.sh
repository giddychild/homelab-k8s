#!/usr/bin/env bash
#
# vault-money-secret.sh — seed the 'money' app secrets.
#
# Generates a Postgres password + RS256 JWT keypair, writes them to the homelab
# Vault at secret/money/app (which apps-prod's ESO syncs into the money-secrets
# k8s Secret), and PRE-SEEDS the CloudNativePG app secret 'money-pg-app' with
# the SAME password so the cluster's DATABASE_URL matches what CNPG uses.
# All secrets stay on this host — nothing is printed.
#
# Run on mgmt-jump:
#   export VAULT_ADDR='https://vault.apps.giddyland.net'
#   export VAULT_TOKEN='<your-vault-root/admin-token>'
#   bash scripts/vault-money-secret.sh
#
# Requires: curl, python3, openssl, kubectl, ~/.kube/apps-prod.kubeconfig.
set -euo pipefail

: "${VAULT_ADDR:?set VAULT_ADDR, e.g. https://vault.apps.giddyland.net}"
: "${VAULT_TOKEN:?set VAULT_TOKEN (Vault root/admin token)}"
KUBECONFIG_APPS="${KUBECONFIG_APPS:-$HOME/.kube/apps-prod.kubeconfig}"

PG_USER="money"; PG_DB="money"
PG_HOST="money-pg-rw.money.svc.cluster.local"
PG_PASS="$(openssl rand -hex 24)"   # hex -> URL-safe (no escaping needed)

DATABASE_URL="postgresql+asyncpg://${PG_USER}:${PG_PASS}@${PG_HOST}:5432/${PG_DB}"
REDIS_URL="redis://money-redis.money.svc.cluster.local:6379/0"
JWT_PRIV="$(openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 2>/dev/null)"
JWT_PUB="$(printf '%s' "$JWT_PRIV" | openssl pkey -pubout 2>/dev/null)"

echo "==> Write secret/money/app to Vault (KV v2)"
PAYLOAD="$(DATABASE_URL="$DATABASE_URL" REDIS_URL="$REDIS_URL" JWT_PRIV="$JWT_PRIV" JWT_PUB="$JWT_PUB" \
  python3 -c 'import json,os; print(json.dumps({"data":{
    "database_url": os.environ["DATABASE_URL"],
    "redis_url":    os.environ["REDIS_URL"],
    "jwt_private_key": os.environ["JWT_PRIV"],
    "jwt_public_key":  os.environ["JWT_PUB"],
  }}))')"
HTTP="$(printf '%s' "$PAYLOAD" | curl -sS -o /tmp/vault_money_resp.json -w '%{http_code}' \
  -H "X-Vault-Token: ${VAULT_TOKEN}" -H "Content-Type: application/json" \
  -X POST --data-binary @- "${VAULT_ADDR}/v1/secret/data/money/app")"
if [ "$HTTP" != "200" ] && [ "$HTTP" != "204" ]; then
  echo "   !! Vault write FAILED (HTTP $HTTP). Response (no app secrets, just Vault error):"
  cat /tmp/vault_money_resp.json; echo; rm -f /tmp/vault_money_resp.json
  echo "   Check VAULT_ADDR/VAULT_TOKEN and that the KV v2 mount is 'secret'. Aborting (money-pg-app NOT changed)."
  exit 1
fi
rm -f /tmp/vault_money_resp.json
echo "   Vault write OK (HTTP $HTTP)."

echo "==> Pre-seed CNPG app secret 'money-pg-app' on apps-prod (so DATABASE_URL matches)"
kubectl --kubeconfig "${KUBECONFIG_APPS}" create namespace money 2>/dev/null || true
kubectl --kubeconfig "${KUBECONFIG_APPS}" -n money delete secret money-pg-app --ignore-not-found >/dev/null 2>&1 || true
kubectl --kubeconfig "${KUBECONFIG_APPS}" -n money create secret generic money-pg-app \
  --type=kubernetes.io/basic-auth \
  --from-literal=username="${PG_USER}" \
  --from-literal=password="${PG_PASS}"

echo "OK: Vault secret/money/app written + money-pg-app pre-seeded. (No secrets printed.)"
