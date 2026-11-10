# CVAT infrastructure

What CVAT owns on the platform: `cvat_data`, the EFS file system its server and workers share (`<release>-backend-data`, `ReadWriteMany`), with its mount targets, NFS security group, access point and backups; and `cvat.<env>.intranet.femtum.com` on the shared HTTPS listener, at priority `30`, forwarding to the target group Traefik's pods are bound to (`/ping` health check). The platform ([Femtum/Infrastructure](https://github.com/Femtum/Infrastructure), `infrastructure-aws`) runs the Kubernetes cluster and its EFS CSI driver, and knows nothing about this app.

The `platform_contract` and `app_ingress` modules come from `Femtum/Infrastructure` over SSH, pinned to one commit in `platform.tf`. Downloading them needs read access to that repository: your own GitHub SSH key locally, the workspace's SSH key in Terraform Cloud. It reads the platform workspace's outputs through `terraform_remote_state`, and the plan is refused while the platform runs no Kubernetes cluster.

## cvat_data

- Regional, so it survives the loss of a zone, with a mount target in each Kubernetes subnet.
- Elastic throughput: billed per GB read ($0.03) and written ($0.06), where Bursting would hold a 20 GiB file system to about 1 MiB/s. About $22 a month at 20 GiB with daily use, backups included.
- Encrypted at rest with the AWS-managed key. The file system policy refuses any request without TLS, and only grants mounting through a mount target, never as root.
- NFS (2049) admitted from the cluster's security group only, never from a network.
- Every mount goes through the access point: files are written as CVAT's `django` user (`1000:1000`) under `/cvat_data`, mode `0750`.
- Standard storage only: chunks are read back at random, and Infrequent Access bills every read.
- Backed up every night by AWS Backup into the `cvat-<environment>` vault, kept 35 days.

`prevent_destroy` makes Terraform refuse any plan that deletes the file system, and AWS refuses to delete the vault while it holds recovery points. `terraform test` cannot check `prevent_destroy`: keep it when editing `file_system.tf`.

## Terraform Cloud workspace

`cvat-rnd` in the `Femtum` organization, which the `cloud` block selects by name:

- Project `RnD`: `tfc-role` only trusts workspaces in that project, any other gets `AccessDenied` on `sts:AssumeRoleWithWebIdentity`
- Terraform 1.10 or later
- No working directory: only this folder is uploaded
- SSH key with read access to `Femtum/Infrastructure`, for the module sources
- Variable set `AWS OIDC RnD`: the platform's dynamic credentials and `environment_name = rnd`
- Listed in `infrastructure-aws-rnd`'s remote state sharing (Settings → General), so `platform_contract` can read the platform's outputs

`tfc-role` needs `elasticfilesystem:*`, `backup:*`, `backup-storage:MountCapsule` and `iam:PassRole` to `backup.amazonaws.com` for this root.

## Plan and apply

Manual for now: no pipeline runs Terraform. You run `terraform plan` and `terraform apply` from your machine, in this folder, on the newest `Femtum-*` branch only: an older one silently reverts what the newer one applied (see [FEMTUM.md](../FEMTUM.md)). The run executes in Terraform Cloud, workspace `cvat-rnd`, which gets its AWS credentials through `tfc-role`. You need:

- Terraform Cloud: `terraform login`, with an account allowed to plan and apply on `cvat-rnd` (organization `Femtum`, project `RnD`).
- GitHub: an SSH key with read access to `Femtum/Infrastructure`, for `terraform init` to download the modules.

```sh
cd infra
terraform init
terraform plan
terraform apply
```

## Deploy on Kubernetes

The chart, its values, the volume bound to `cvat_data` and the binding to the target group are in [`deploy/`](../deploy/README.md).

## Tests

CI only checks formatting: it cannot download `platform_contract` from the private `Femtum/Infrastructure`. Run the suite before pushing:

```sh
cd infra
terraform init -backend=false && terraform test
```
