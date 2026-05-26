#!/usr/bin/env bash
#
# argocd-register-apps.sh — register apps-prod as a managed cluster in the
# homelab-prod ArgoCD (hub-and-spoke). Creates an argocd-manager ServiceAccount
# (cluster-admin) + long-lived token on apps-prod, then writes the ArgoCD
# cluster Secret into the homelab argocd namespace. Token/CA never printed.
#
# Run on mgmt-jump (has both kubeconfigs):
#   bash scripts/argocd-register-apps.sh
set -euo pipefail

APPS_KUBECONFIG="${APPS_KUBECONFIG:-$HOME/.kube/apps-prod.kubeconfig}"
HUB_KUBECONFIG="${HUB_KUBECONFIG:-$HOME/.kube/config}"
APPS_API="https://192.168.216.204:6443"

echo "==> apps-prod: argocd-manager SA + cluster-admin + token"
export KUBECONFIG="$APPS_KUBECONFIG"
kubectl create sa argocd-manager -n kube-system 2>/dev/null || true
kubectl create clusterrolebinding argocd-manager \
  --clusterrole=cluster-admin --serviceaccount=kube-system:argocd-manager 2>/dev/null || true
kubectl apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: argocd-manager-token
  namespace: kube-system
  annotations:
    kubernetes.io/service-account.name: argocd-manager
type: kubernetes.io/service-account-token
EOF
sleep 5
TOKEN="$(kubectl -n kube-system get secret argocd-manager-token -o jsonpath='{.data.token}' | base64 -d)"
CA="$(kubectl config view --raw --minify -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')"
[ -n "$TOKEN" ] && [ -n "$CA" ] || { echo "failed to read SA token/CA"; exit 1; }

echo "==> homelab ArgoCD: write cluster Secret 'apps-prod'"
export KUBECONFIG="$HUB_KUBECONFIG"
kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: apps-prod
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: cluster
type: Opaque
stringData:
  name: apps-prod
  server: ${APPS_API}
  config: |
    {"bearerToken":"${TOKEN}","tlsClientConfig":{"insecure":false,"caData":"${CA}"}}
EOF

echo "OK: apps-prod registered. ArgoCD clusters:"
kubectl -n argocd get secret -l argocd.argoproj.io/secret-type=cluster
