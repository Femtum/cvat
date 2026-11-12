# CVAT infrastructure

What CVAT owns on the platform: `cvat_data`, the EFS file system its server and workers share (`<release>-backend-data`, `ReadWriteMany`), with its mount targets, NFS security group, access point and backups; `cvat-database`, the Postgres instance CVAT's server connects to, with its security group; and `cvat.<env>.intranet.femtum.com` on the shared HTTPS listener, at priority `30`, forwarding to the target group Traefik's pods are bound to (`/ping` health check). The platform ([Femtum/Infrastructure](https://github.com/Femtum/Infrastructure), `infrastructure-aws`) runs the Kubernetes cluster, its EFS CSI driver and External Secrets Operator, and knows nothing about this app.

The `platform_contract` and `app_ingress` modules come from `Femtum/Infrastructure` over SSH, pinned to one commit in `platform.tf`. Downloading them needs read access to that repository: your own GitHub SSH key locally, the workspace's SSH key in Terraform Cloud. It reads the platform workspace's outputs through `terraform_remote_state`, and the plan is refused while the platform runs no Kubernetes cluster. Apply the platform before bumping the ref.

## cvat_data

- Regional, so it survives the loss of a zone, with a mount target in each Kubernetes subnet.
- Elastic throughput: billed per GB read ($0.03) and written ($0.06), where Bursting would hold a 20 GiB file system to about 1 MiB/s. About $22 a month at 20 GiB with daily use, backups included.
- Encrypted at rest with the AWS-managed key. The file system policy refuses any request without TLS, and only grants mounting through a mount target, never as root.
- NFS (2049) admitted from the cluster's security group only, never from a network.
- Every mount goes through the access point: files are written as CVAT's `django` user (`1000:1000`) under `/cvat_data`, mode `0750`.
- Files untouched for 30 days move to Infrequent Access ($0.02 per GB-month against Standard's $0.33, plus $0.011 per GB read), and back to Standard on their first read. Reopening an old task costs a few cents and slows its first frames only.
- Backed up every night by AWS Backup into the `cvat-<environment>` vault, kept 35 days.

`prevent_destroy` makes Terraform refuse any plan that deletes the file system, and AWS refuses to delete the vault while it holds recovery points. `terraform test` cannot check `prevent_destroy`: keep it when editing `file_system.tf`.

## cvat-database

CVAT's own RDS instance, separate from `lit-database`, so it is restored on its own and shares none of lit's maintenance. About $25–30 a month.

- Postgres 17, `engine_version = "17"`: major only, so minor upgrades apply themselves in the maintenance window and never show as a diff. A major upgrade is a deliberate change of that line, `allow_major_version_upgrade` stays off. Upstream only tests 15: if CVAT's migrations fail on 17 on the first install, replace the instance with 16 while it is still empty; once it holds data, that becomes a dump and restore.
- `db.t4g.small` (about 200 `max_connections`; CVAT opens one per request), single-AZ: a zone outage means downtime until AWS recovers it.
- gp3, 20 GB, growing by itself up to 100 GB. Encrypted at rest with the AWS-managed key.
- Parameter group `default.postgres17`, whose `rds.force_ssl` is `1` (checked with `aws rds describe-db-parameters --db-parameter-group-name default.postgres17`): the server refuses any connection without TLS, and the chart sets `PGSSLMODE=require`.
- Backups kept 7 days, in lit's windows: backups `03:00-04:00`, maintenance `sun:05:00-sun:06:00` (UTC). Performance Insights on its free tier, no enhanced monitoring.
- In the platform's private subnets, where the Client VPN is attached, and not publicly accessible.
- Postgres (5432) admitted from two security groups, never from a network: the cluster's, which Auto Mode's nodes and **every pod on the cluster** carry, an accepted risk while CVAT is the cluster's only app; and the Client VPN's. The group has no egress rule: replies need none, and RDS opens no connection here. Never add one, nor a CIDR rule: the tests only see the keyed `postgres` rules and the group itself.
- The master user, `femtum`, has its password managed by RDS in Secrets Manager, rotated every 7 days. It is for humans only: CVAT connects as `cvat`, below.

`deletion_protection` makes AWS refuse to delete the instance, `prevent_destroy` makes Terraform refuse to plan it, and a deletion that gets past both leaves the snapshot `cvat-database-final`. `terraform test` cannot check `prevent_destroy`: keep it when editing `database.tf`.

## CVAT's database user and secret

CVAT connects as `cvat`, owner of the database `cvat`, with the credentials in the Secrets Manager secret `k8s/cvat/database` (keys `username`, `database`, `password`, on the default `aws/secretsmanager` key). Both were made by hand: Terraform manages neither the user, nor the secret, nor its value, so the password never enters Terraform state.

CVAT runs in the Kubernetes namespace `cvat` (see [`deploy/`](../deploy/README.md)), and the platform's External Secrets store lets a namespace read the secrets under `k8s/<namespace>/` and nothing else: this root holds no IAM for it. Renaming the namespace means moving the secret under the new prefix.

## Terraform Cloud workspace

`cvat-rnd` in the `Femtum` organization, which the `cloud` block selects by name:

- Project `RnD`: `tfc-role` only trusts workspaces in that project, any other gets `AccessDenied` on `sts:AssumeRoleWithWebIdentity`
- Terraform 1.10 or later
- No working directory: only this folder is uploaded
- SSH key with read access to `Femtum/Infrastructure`, for the module sources
- Variable set `AWS OIDC RnD`: the platform's dynamic credentials and `environment_name = rnd`
- Listed in `infrastructure-aws-rnd`'s remote state sharing (Settings → General), so `platform_contract` can read the platform's outputs

`tfc-role` needs `elasticfilesystem:*`, `backup:*`, `backup-storage:MountCapsule` and `iam:PassRole` to `backup.amazonaws.com` for this root, plus `rds:*` and role creation and inline policies on `role/*`, which `tfc-policy` already grants. `cvat-database` passes no role: it has no enhanced monitoring.

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
