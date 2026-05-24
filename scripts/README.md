# scripts/

Helper scripts (bootstrap helpers, backups, convenience wrappers). Kept minimal —
prefer Terraform/Ansible/GitOps over imperative scripts.

## Contents
- **`bootstrap-mgmt.sh`** — one-time provisioning of the `mgmt-jump` host. Installs the
  platform toolchain (kubectl, helm, talosctl, terraform, ansible) + base utilities on
  Ubuntu 22.04/24.04. Run once after the VM is created:
  ```bash
  chmod +x scripts/bootstrap-mgmt.sh && ./scripts/bootstrap-mgmt.sh
  ```
