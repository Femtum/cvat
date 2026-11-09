# Deploying CVAT on Kubernetes

How CVAT runs on the platform's `femtum-rnd` cluster: upstream's chart (`helm-chart/`, unmodified), Femtum's values on top of it, and the static volume that binds the backend's shared data to `cvat_data`, the EFS file system in [`infra/`](../infra/README.md).

Run everything over the Client VPN, as `AdministratorAccess`, from the repository root, once `infra/` is applied and the cluster has its default StorageClass (see the platform README, "Storage"). The release is `cvat` in namespace `cvat`: the PersistentVolume is reserved for the claim `cvat/cvat-backend-data`, which the chart names `<release>-backend-data`.

```sh
aws eks update-kubeconfig --region ca-central-1 --name femtum-rnd
volume_handle=$(terraform -chdir=infra output -raw backend_data_volume_handle)
```

## Prove the volume is shared, once

Before installing CVAT, two pods on two nodes mount the access point: one writes its name, the other reads it.

```sh
kubectl create namespace rwx-proof
sed "s|VOLUME_HANDLE|${volume_handle:?read it from terraform first}|" deploy/rwx-proof.yaml | kubectl apply -f -
kubectl wait -n rwx-proof --for=condition=Ready pod --all --timeout=10m
kubectl exec -n rwx-proof rwx-proof-reader -- cat /data/rwx-proof   # the writer's pod name
kubectl get pods -n rwx-proof -o wide                                # two different nodes
kubectl exec -n rwx-proof rwx-proof-reader -- rm /data/rwx-proof
kubectl delete namespace rwx-proof && kubectl delete pv rwx-proof
```

## Install

```sh
sed "s|VOLUME_HANDLE|${volume_handle:?read it from terraform first}|" deploy/backend-data.pv.yaml | kubectl apply -f -
helm upgrade --install cvat helm-chart --namespace cvat --create-namespace \
  -f helm-chart/cvat.values.yaml -f deploy/cvat.values.yaml
kubectl get pvc -n cvat cvat-backend-data   # Bound to cvat-backend-data
```

`deploy/cvat.values.yaml` sets `storageClassName: cvat-efs`, which only the static volume carries: without it, the claim would fall to the default EBS class, which cannot be shared.

## What survives what

- `helm uninstall`: the chart keeps the claim (`helm.sh/resource-policy: keep`), so nothing changes.
- Deleting the claim: the volume is `Retain`, so the data stays, and the volume turns `Released`. Release it for the new claim before reinstalling: `kubectl patch pv cvat-backend-data --type=json -p '[{"op":"remove","path":"/spec/claimRef/uid"}]'`.
- `terraform destroy`: refused by `prevent_destroy`.
- Deleted files: restore from the vault, `aws backup list-recovery-points-by-backup-vault --backup-vault-name cvat-rnd`.
