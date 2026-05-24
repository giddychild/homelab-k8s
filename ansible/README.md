# ansible/

Configures the `mgmt-jump` tooling host (installs talosctl, kubectl, helm,
terraform, etc.) and any helper automation that isn't a VM definition.

```
ansible.cfg     Defaults
inventory/      Hosts (mgmt-jump, optionally nodes for out-of-band tasks)
roles/          Reusable units (e.g. role: tooling)
playbooks/      Entry points (e.g. bootstrap-mgmt.yml)
```

Built in Phase 3.
