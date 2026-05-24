#!/usr/bin/env bash
#
# bootstrap-mgmt.sh — provision the homelab-k8s management host ("mgmt-jump").
#
# Installs the platform toolchain on Ubuntu 22.04/24.04 (amd64):
#   kubectl, helm, talosctl, terraform, ansible  (+ base CLI utilities)
#
# Usage (on mgmt-jump, as a sudo-capable user):
#   chmod +x scripts/bootstrap-mgmt.sh
#   ./scripts/bootstrap-mgmt.sh
#
# Safe to re-run. Requires internet egress (slow on 100 Mbps is fine).
set -euo pipefail

log() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

# ---------- sanity checks ----------
if [[ "$(uname -m)" != "x86_64" ]]; then
  echo "ERROR: this script targets x86_64/amd64; detected $(uname -m)." >&2
  exit 1
fi
log "Checking sudo access (you may be prompted for your password)"
sudo -v

# ---------- base packages ----------
log "Installing base packages"
sudo apt-get update -y
sudo apt-get install -y \
  curl wget git unzip jq gnupg lsb-release ca-certificates \
  apt-transport-https software-properties-common \
  vim tmux htop bash-completion

# ---------- kubectl (latest stable, official binary) ----------
log "Installing kubectl"
KUBECTL_VERSION="$(curl -fsSL https://dl.k8s.io/release/stable.txt)"
curl -fsSLo /tmp/kubectl "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl"
sudo install -m 0755 /tmp/kubectl /usr/local/bin/kubectl
rm -f /tmp/kubectl

# ---------- helm (official installer) ----------
log "Installing helm"
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# ---------- talosctl (latest release binary) ----------
log "Installing talosctl"
TALOSCTL_VERSION="$(curl -fsSL https://api.github.com/repos/siderolabs/talos/releases/latest | jq -r .tag_name)"
curl -fsSLo /tmp/talosctl "https://github.com/siderolabs/talos/releases/download/${TALOSCTL_VERSION}/talosctl-linux-amd64"
sudo install -m 0755 /tmp/talosctl /usr/local/bin/talosctl
rm -f /tmp/talosctl

# ---------- terraform (HashiCorp apt repo) ----------
log "Installing terraform"
wget -qO- https://apt.releases.hashicorp.com/gpg \
  | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" \
  | sudo tee /etc/apt/sources.list.d/hashicorp.list >/dev/null
sudo apt-get update -y
sudo apt-get install -y terraform

# ---------- ansible (apt) ----------
log "Installing ansible"
sudo apt-get install -y ansible

# ---------- shell niceties ----------
log "Configuring completions + aliases in ~/.bashrc"
BRC="${HOME}/.bashrc"
add_line() { grep -qxF "$1" "$BRC" 2>/dev/null || echo "$1" >> "$BRC"; }
add_line 'source <(kubectl completion bash)'
add_line 'alias k=kubectl'
add_line 'complete -o default -F __start_kubectl k'
add_line 'source <(talosctl completion bash 2>/dev/null)'
add_line 'source <(helm completion bash)'
mkdir -p "${HOME}/.kube" "${HOME}/.talos"

# ---------- verify ----------
log "Installed versions"
echo "kubectl  : $(kubectl version --client 2>/dev/null | head -n1)"
echo "talosctl : $(talosctl version --client 2>/dev/null | head -n1)"
echo "helm     : $(helm version --short 2>/dev/null)"
echo "terraform: $(terraform version 2>/dev/null | head -n1)"
echo "ansible  : $(ansible --version 2>/dev/null | head -n1)"

log "Done. Run 'exec bash' (or log out/in) to load the new completions and the 'k' alias."
