# Deploying CVAT on Kubernetes

How CVAT runs on the platform's `femtum-rnd` cluster: upstream's chart (`helm-chart/`, unmodified), Femtum's values on top of it, the static volume that binds the backend's shared data to `cvat_data`, the EFS file system in [`infra/`](../infra/README.md), and the binding that puts Traefik behind the platform's shared ALB at `https://cvat.rnd.intranet.femtum.com`.

Run everything over the Client VPN, as `AdministratorAccess`, once `infra/` is applied and the cluster has its default StorageClass (see the platform README, "Storage"). The release is `cvat` in namespace `cvat`: the PersistentVolume is reserved for the claim `cvat/cvat-backend-data`, which the chart names `<release>-backend-data`.

## Install and upgrade

```sh
deploy/deploy.sh
kubectl get pvc -n cvat cvat-backend-data   # Bound to cvat-backend-data
```

The script is the same for a first install and every upgrade. It reads `backend_data_volume_handle`, `target_group_arn` and `url` from `infra/`, and stops before touching the cluster if any is empty. CVAT's and Grafana's host comes from `url`, never from a values file. Then it points kubectl at `femtum-rnd` and downloads the chart's dependencies (PostgreSQL, Redis, Traefik, …) into `helm-chart/charts/`, which git ignores along with `Chart.lock`. It applies the static volume, runs `helm upgrade --install` with upstream's values and then `deploy/cvat.values.yaml`, waiting up to 15 minutes for the pods, and finally applies the TargetGroupBinding. Rerun it after every rebase onto a new upstream tag, since the dependencies change too.

Its tests use stub tools and touch nothing: `deploy/tests/deploy_test.sh`.

`deploy/cvat.values.yaml` sets `storageClassName: cvat-efs`, which only the static volume carries: without it, the claim would fall to the default EBS class, which cannot be shared.

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

- `helm uninstall`: the chart keeps the claim (`helm.sh/resource-policy: keep`), so nothing changes. The binding stays and points at no pods until the next install; the target group belongs to `infra/` and is never deleted by the cluster.
- Deleting the claim: the volume is `Retain`, so the data stays, and the volume turns `Released`. Release it for the new claim before reinstalling: `kubectl patch pv cvat-backend-data --type=json -p '[{"op":"remove","path":"/spec/claimRef/uid"}]'`.
- `terraform destroy`: refused by `prevent_destroy`.
- Deleted files: restore from the vault, `aws backup list-recovery-points-by-backup-vault --backup-vault-name cvat-rnd`.
