# terraform-lab

Builds lab VMs in Lab-Cluster by cloning the `ubuntu-2604-tmpl` template through vCenter (10.10.10.22). Full walkthrough, including the least-privilege `svc-terraform` vCenter role and the template build: [docs/12-terraform-vsphere.md](../docs/12-terraform-vsphere.md).

```bash
cp terraform.tfvars.example terraform.tfvars   # then put the real password in it (git-ignored)
terraform init
terraform fmt && terraform validate
terraform plan
terraform apply
terraform destroy
```

| File | Purpose |
|---|---|
| `versions.tf` | Terraform version and the `vmware/vsphere` provider |
| `provider.tf` | How to reach vCenter |
| `variables.tf` | Inputs, including the `vms` map (the whole inventory) |
| `main.tf` | Look up Lab-DC, Lab-Cluster, nfs-vm-shared, VM-NET and the template; clone the VMs |
| `outputs.tf` | Each VM's IP after apply |
| `terraform.tfvars.example` | Template for your credentials file |

`terraform.tfvars`, `*.tfstate` and `.terraform/` are git-ignored: the first holds the vCenter password and state can hold sensitive values. Commit `.terraform.lock.hcl` after your first `terraform init` so every run uses the same provider version.
