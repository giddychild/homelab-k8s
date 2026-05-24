# terraform/

Provisions the ESXi VMs via the vSphere provider (enabled by the Enterprise Plus
license, which exposes a read-write vSphere API).

```
modules/talos-vm/      Reusable VM definition — write once, stamp many VMs
environments/prod/     The actual cluster: control plane + workers + mgmt-jump
  main.tf              Calls the module for each node
  variables.tf         Inputs (vSphere endpoint, datastore, network, counts)
  terraform.tfvars     Credentials/values (GITIGNORED — never commit)
  backend.tf           Where Terraform state is stored
```

Built in Phase 2–3. Module-per-resource keeps the code DRY and reusable.
