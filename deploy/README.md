# Deploying CVAT on Kubernetes

How CVAT runs on the platform's `femtum-rnd` cluster: upstream's chart (`helm-chart/`, unmodified), Femtum's values on top of it, the static volume that binds the backend's shared data to `cvat_data`, the EFS file system and the `cvat-database` RDS instance in [`infra/`](../infra/README.md), the External Secrets objects that bring the database user in from Secrets Manager, and the binding that puts Traefik behind the platform's shared ALB at `https://cvat.rnd.intranet.femtum.com`.

Run everything over the Client VPN, as `AdministratorAccess`, once `infra/` is applied, the cluster has its default StorageClass and External Secrets Operator (see the platform's [`kubernetes/README.md`](https://github.com/Femtum/Infrastructure/blob/main/infrastructure-aws/kubernetes/README.md), "Storage" and "Secrets from Secrets Manager"), and the database user and its secret exist (see `infra/README.md`). The release is `cvat` in namespace `cvat`: the PersistentVolume is reserved for the claim `cvat/cvat-backend-data`, which the chart names `<release>-backend-data`.

## Install and upgrade

```sh
deploy/deploy.sh
kubectl get pvc -n cvat cvat-backend-data   # Bound to cvat-backend-data
kubectl get externalsecret -n cvat            # SecretSynced
kubectl get jobs -n cvat                      # cvat-backend-initializer-r<revision> Complete
```

The script is the same for a first install and every upgrade. It reads `backend_data_volume_handle`, `target_group_arn`, `url` and `database_address` from `infra/`, and stops before touching the cluster if any is empty. CVAT's and Grafana's host comes from `url`, and the database host from `database_address`, never from a values file. Then it points kubectl at `femtum-rnd` and downloads the chart's dependencies (Redis, Traefik, …) into `helm-chart/charts/`, which git ignores along with `Chart.lock`. It applies the namespace, the static volume and the `ExternalSecret`, and waits up to 2 minutes for the database user's Secret to sync. It then runs `helm upgrade --install` with upstream's values and then `deploy/cvat.values.yaml`, waiting up to 15 minutes for the pods and for the initializer Job, which runs CVAT's migrations, and finally applies the TargetGroupBinding. Rerun it after every rebase onto a new upstream tag, since the dependencies change too.

Its tests use stub tools and touch nothing: `deploy/tests/deploy_test.sh`.

`deploy/cvat.values.yaml` sets `storageClassName: cvat-efs`, which only the static volume carries: without it, the claim would fall to the default EBS class, which cannot be shared.

## Database

CVAT uses `cvat-database`, the RDS Postgres 17 instance in `infra/`, as the user `cvat`; the chart's own PostgreSQL is off (`postgresql.enabled: false`).

- **Credentials.** `database-user.external-secret.yaml` reads through the platform's `ClusterSecretStore` `aws-secrets-manager`, which reaches `k8s/cvat/*` from namespace `cvat` and nothing else. It copies the keys `username`, `database` and `password` of the Secrets Manager secret `k8s/cvat/database` into the Secret `cvat-database-user`, which the chart reads (`postgresql.secret.name`, with `postgresql.secret.create: false`).
- **The password reaches CVAT only as `CVAT_POSTGRES_PASSWORD`.** Never also set `CVAT_POSTGRES_PASSWORD_FILE`: CVAT refuses to start with both.
- **TLS.** `PGSSLMODE=require` on every backend pod, through `cvat.backend.additionalEnv`; the server's `rds.force_ssl` refuses plain connections anyway. The certificate is not verified: the connection stays inside the VPC.
- **Changing the password.** Change it in Postgres and in the secret, then wait for the hourly refresh or force it with `kubectl annotate externalsecret -n cvat cvat-database-user force-sync=$(date +%s) --overwrite`. The pods read it at start only: `kubectl rollout restart deployment -n cvat`.

Check that CVAT talks to RDS over TLS:

```sh
kubectl exec -n cvat deploy/cvat-backend-server -c cvat-backend -- python3 manage.py shell -c '
from django.db import connection
c = connection.cursor()
c.execute("select current_user, version(), ssl from pg_stat_ssl, version() where pid = pg_backend_pid()")
print(c.fetchone())'                      # ('cvat', 'PostgreSQL 17...', True)
```

## Reaching CVAT

The office and Client VPN users reach `https://cvat.rnd.intranet.femtum.com` through the shared ALB, like every other app: no DNS record or certificate to add. The ALB terminates TLS and forwards to Traefik's pods, registered into `infra/`'s target group by `deploy/target-group-binding.yaml`. Traefik splits requests by path between the frontend, the backend and `/analytics`.

Traefik's Service is `ClusterIP`, so the cluster runs no load balancer of its own. Check after an install:

```sh
target_group_arn=$(terraform -chdir=infra output -raw target_group_arn)
kubectl get svc -n cvat cvat-traefik                          # TYPE ClusterIP, no EXTERNAL-IP
aws elbv2 describe-target-health --target-group-arn "$target_group_arn" \
  --query 'TargetHealthDescriptions[].TargetHealth.State'    # healthy
curl -sI https://cvat.rnd.intranet.femtum.com | head -1      # HTTP/2 200
```

## What survives what

- `helm uninstall`: the database is on RDS and stays. The `ExternalSecret` and its Secret are not part of the release and stay too. The chart keeps the claim (`helm.sh/resource-policy: keep`), so nothing changes. The binding stays and points at no pods until the next install; the target group belongs to `infra/` and is never deleted by the cluster.
- Deleting the claim: the volume is `Retain`, so the data stays, and the volume turns `Released`. Release it for the new claim before reinstalling: `kubectl patch pv cvat-backend-data --type=json -p '[{"op":"remove","path":"/spec/claimRef/uid"}]'`.
- `terraform destroy`: refused by `prevent_destroy`.
- Deleted files: restore from the vault, `aws backup list-recovery-points-by-backup-vault --backup-vault-name cvat-rnd`.
