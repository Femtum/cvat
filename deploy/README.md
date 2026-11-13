# Deploying CVAT on Kubernetes

How CVAT runs on the platform's `femtum-rnd` cluster: Argo CD deploys `deploy/cvat/`, a chart that wraps upstream's (`helm-chart/`, unmodified) with Femtum's values, the `ExternalSecret` that brings the database user in from Secrets Manager, the claim on the static volume that holds `cvat_data`, the platform Gateway's route, and the binding that keeps Traefik behind the shared ALB at `https://cvat.rnd.intranet.femtum.com`. The EFS file system, the `cvat-database` RDS instance and the shared ALB's target group are in [`infra/`](../infra/README.md).

Run every command here over the Client VPN, as `AdministratorAccess`:

```sh
export AWS_PROFILE=AdministratorAccess-038462763734 AWS_REGION=ca-central-1
aws eks update-kubeconfig --region ca-central-1 --name femtum-rnd
```

## How Argo CD deploys it

The platform's ApplicationSet `apps` (see the platform's [`kubernetes/README.md`](https://github.com/Femtum/Infrastructure/blob/main/infrastructure-aws/kubernetes/README.md), "Argo CD") finds this repository by its GitHub topic `argo-cd` and makes one Application per `deploy/<app>/values-<env>.yaml` on the default branch. `deploy/cvat/values-rnd.yaml` makes the Application `cvat-rnd`, project `apps`: Helm release `cvat`, namespace `cvat-rnd`, created by Argo CD, synced automatically with prune and self-heal. A merge to the default branch is a deploy; nothing runs by hand.

- **`values.yaml`** holds what every environment shares: upstream's `helm-chart/cvat.values.yaml` switches, resource requests, the database settings, and what makes upstream's chart fit the project (below). Upstream's values sit under `cvat:`, its name as a dependency, so its own `cvat:` key nests once more.
- **`values-rnd.yaml`** holds the environment: the host (`global.hostname`), the database host and the shared ALB's target group. Argo CD runs no Terraform, so the last two are copies of `infra/`'s outputs `database_address` and `target_group_arn`: re-copy them if `infra/` ever replaces either.
- **`charts/cvat-2.82.0.tgz`** is upstream's chart packaged with its own dependencies (Redis, Traefik, ClickHouse, …), which git ignores in `helm-chart/charts/`: Argo CD renders from git alone. It is generated, never edited.
- **`.argocd-source.yaml`** makes Argo CD skip CRDs and Helm tests for this path. Traefik's package ships its CRDs and the Gateway API's, and the project refuses every cluster-scoped kind but Namespace: one CRD would fail the whole sync.

Watch a sync:

```sh
kubectl get application -n argocd cvat-rnd     # Synced  Healthy
kubectl get externalsecret,pvc,jobs -n cvat-rnd
```

### What adapts upstream's chart to Argo CD

Argo CD renders with `helm template`, without the cluster, and applies the result itself:

- **Random values.** Upstream's own templates draw none, and its Redis, kvrocks and ClickHouse passwords are fixed values from its `values.yaml`. Grafana's chart draws its admin password at random whenever its `lookup` of the existing Secret finds nothing, which is every Argo CD render: the Secret and Grafana's pods would change on every refresh. Upstream disables Grafana's login form and lets anonymous users in, so `GF_SECURITY_DISABLE_INITIAL_ADMIN_CREATION` turns the admin off and the chart renders no Secret. Django's `SECRET_KEY` is generated once into `keys/` on `cvat_data`, and survives the move.
- **`lookup`.** Vector's chart reads its ConfigMap through `lookup` to roll its pod when the configuration changes; under Argo CD it finds nothing, so a new `vector.toml` (an upstream bump) needs `kubectl rollout restart statefulset -n cvat-rnd cvat-vector`.
- **The initializer.** Upstream's Job, which runs CVAT's migrations, is a plain Job named after the Helm revision, always `1` under Argo CD: its immutable pod template would fail every sync that changes it. It is an Argo CD `Sync` hook instead, deleted and recreated on every sync. The database user's `ExternalSecret` and the claim are in wave `-1`, so the Secret exists and the volume is bound before the hook and every pod start in wave `0`, with Redis and ClickHouse, which the initializer waits for. A `PreSync` hook would run before the Secret exists.
- **Cluster-scoped objects.** Traefik and Grafana use namespaced RBAC, and Traefik has no IngressClass: the annotation `kubernetes.io/ingress.class: traefik` claims upstream's two Ingresses, which also keeps the API server from writing another default class into them.
- **Health checks.** The Gateway's target group for `cvat-traefik` checks `/ping`, which the chart's healthcheck `IngressRoute` answers on any host.

### Changing a value

Edit `values.yaml` or `values-rnd.yaml`, run the tests, and merge: Argo CD syncs within three minutes. The pods read the database password at start only: after changing it in Postgres and in the secret, wait for the hourly refresh or force it with `kubectl annotate externalsecret -n cvat-rnd cvat-database-user force-sync=$(date +%s) --overwrite`, then `kubectl rollout restart deployment -n cvat-rnd`.

### Upgrading to a new upstream tag

After rebasing onto a new tag (see [FEMTUM.md](../FEMTUM.md)), rebuild the package from `helm-chart/`, then update the tag in `deploy/tests/chart_test.sh`:

```sh
helm dependency update helm-chart     # downloads upstream's dependencies into helm-chart/charts/
helm dependency update deploy/cvat    # packages helm-chart/ with them into deploy/cvat/charts/
git add deploy/cvat/Chart.lock deploy/cvat/charts
```

`chart_test.sh` fails while the package and `helm-chart/` differ.

## What a cluster admin owns

Argo CD's project only creates namespaced objects, and an app's namespace only reads its own Secrets Manager prefix, `k8s/<namespace>/`. Two things are made by hand, once:

- **The static volume**, `deploy/cluster/backend-data.pv.yaml`: `cvat_data` through its access point (`volumeHandle` is `infra/`'s `backend_data_volume_handle`), `Retain`, reserved for the claim `cvat-rnd/cvat-backend-data`. The chart's claim names it (`volumeName`) and its class `cvat-efs`, which no StorageClass carries, so nothing else can bind or provision for it. On a new cluster, `kubectl apply -f deploy/cluster/backend-data.pv.yaml` before the first sync; until then the sync waits on the claim, `Pending`, and starts nothing.
- **The secret `k8s/cvat-rnd/database`** (`infra/`'s `database_secret_name`), with the keys `username`, `database` and `password` of CVAT's database user (see `infra/README.md`).

## Database

CVAT uses `cvat-database`, the RDS Postgres 17 instance in `infra/`, as the user `cvat`; the chart's own PostgreSQL is off (`postgresql.enabled: false`).

- **Credentials.** `templates/database-user.external-secret.yaml` reads through the platform's `ClusterSecretStore` `aws-secrets-manager` from `k8s/<namespace>/database`, and copies its keys `username`, `database` and `password` into the Secret `cvat-database-user`, which the chart reads (`postgresql.secret.name`, with `postgresql.secret.create: false`).
- **The password reaches CVAT only as `CVAT_POSTGRES_PASSWORD`.** Never also set `CVAT_POSTGRES_PASSWORD_FILE`: CVAT refuses to start with both.
- **TLS.** `PGSSLMODE=require` on every backend pod, through `cvat.backend.additionalEnv`; the server's `rds.force_ssl` refuses plain connections anyway. The certificate is not verified: the connection stays inside the VPC.

Check that CVAT talks to RDS over TLS:

```sh
kubectl exec -n cvat-rnd deploy/cvat-backend-server -c cvat-backend -- python3 manage.py shell -c '
from django.db import connection
c = connection.cursor()
c.execute("select current_user, version(), ssl from pg_stat_ssl, version() where pid = pg_backend_pid()")
print(c.fetchone())'                      # ('cvat', 'PostgreSQL 17...', True)
```

## Reaching CVAT

The office and Client VPN users reach `https://cvat.rnd.intranet.femtum.com` through the shared ALB until the platform's DNS cutover: its rule forwards to `infra/`'s target group, which `templates/target-group-binding.yaml` fills with Traefik's pods. The route `templates/http-route.yaml` already puts the same host on the platform Gateway (`platform-gateway/platform`, listener `https`), which DNS reaches from the cutover on; the binding goes in the cutover's cleanup. Both ALBs terminate TLS and forward plain HTTP to Traefik, which splits requests by path between the frontend, the backend and `/analytics`, behind its forward-auth to CVAT.

```sh
target_group_arn=$(yq '.targetGroupBinding.targetGroupARN' deploy/cvat/values-rnd.yaml)
aws elbv2 describe-target-health --target-group-arn "$target_group_arn" \
  --query 'TargetHealthDescriptions[].TargetHealth.State'                    # healthy
curl -sS https://cvat.rnd.intranet.femtum.com/api/server/about               # shared ALB
curl -sS --resolve cvat.rnd.intranet.femtum.com:443:10.0.100.48 \
  https://cvat.rnd.intranet.femtum.com/api/server/about                      # Gateway
```

## What survives what

- Removing the topic or `values-rnd.yaml`: the ApplicationSet deletes the Application and leaves everything it deployed running (`preserveResourcesOnDeletion`).
- Removing an object from the chart: Argo CD prunes it, except the claim (`Prune=false`, `Delete=false`).
- Deleting the namespace: the database is on RDS and stays. The volume is `Retain`, so `cvat_data` stays and the volume turns `Released`; release it for the next claim with `kubectl patch pv cvat-backend-data --type=json -p '[{"op":"remove","path":"/spec/claimRef/uid"}]'`. ClickHouse's analytics, Redis's queue and kvrocks's cache are on EBS volumes that go with it. The target group belongs to `infra/` and is never deleted by the cluster.
- `terraform destroy`: refused by `prevent_destroy`.
- Deleted files: restore from the vault, `aws backup list-recovery-points-by-backup-vault --backup-vault-name cvat-rnd`.

## Migrating from the hand-run release

Until this migration, CVAT ran as the Helm release `cvat` in the namespace `cvat`, installed by hand with a script now removed. The move to `cvat-rnd` takes a short downtime: the static volume can only be bound to one claim, and nothing may write `cvat_data` from two namespaces. The database on RDS is shared and unchanged. ClickHouse's analytics start empty in `cvat-rnd`, as do Redis's queue and kvrocks's cache.

Each step says how to check it and how to undo it. Run them in order, in one shell, from the root of an up-to-date checkout of the default branch.

### Before the window

1. Merge this stack, without the topic: no Application exists yet. Check `kubectl get application -n argocd cvat-rnd` answers `NotFound`.

2. Copy the database user's secret under `cvat-rnd`'s prefix. The old one stays for the old release, and for a rollback, until the cleanup.

   ```sh
   aws secretsmanager create-secret --name k8s/cvat-rnd/database \
     --description "CVAT's database user, read by the ExternalSecret cvat-database-user in namespace cvat-rnd" \
     --secret-string "$(aws secretsmanager get-secret-value --secret-id k8s/cvat/database --query SecretString --output text)"
   aws secretsmanager get-secret-value --secret-id k8s/cvat-rnd/database \
     --query SecretString --output text | jq -r 'keys | join(",")'           # database,password,username
   ```

   Undo: `aws secretsmanager delete-secret --secret-id k8s/cvat-rnd/database --force-delete-without-recovery`.

3. Check what the move relies on:

   ```sh
   kubectl get pv cvat-backend-data -o jsonpath='{.spec.persistentVolumeReclaimPolicy} {.status.phase} {.spec.claimRef.namespace}/{.spec.claimRef.name}{"\n"}'
   # Retain Bound cvat/cvat-backend-data
   kubectl get crd ingressroutes.traefik.io middlewares.traefik.io              # both exist
   ```

   Stop if the volume is not `Retain`: deleting its claim below would delete `cvat_data`.

### During the window

4. Announce the downtime, then record what runs, for a rollback:

   ```sh
   kubectl get deployment,statefulset -n cvat \
     -o jsonpath='{range .items[*]}{.kind}/{.metadata.name} {.spec.replicas}{"\n"}{end}' > cvat-replicas.txt
   ```

5. Stop everything in `cvat`, so nothing writes `cvat_data`. The shared ALB answers 503 from here on.

   ```sh
   kubectl scale deployment,statefulset --all -n cvat --replicas=0
   kubectl wait --for=delete pod -n cvat -l 'component!=initializer' --timeout=5m   # or "no matching resources found"
   kubectl get pods -n cvat                                                     # only Completed initializer pods
   ```

   Undo: `while read -r workload replicas; do kubectl scale -n cvat "$workload" --replicas="$replicas"; done < cvat-replicas.txt`.

6. Move the volume to `cvat-rnd`'s claim. Delete the old claim (the volume is `Retain`, so it only turns `Released`), then replace its whole `claimRef`, which drops the old claim's `uid`. **Never delete the volume.**

   ```sh
   kubectl delete pvc -n cvat cvat-backend-data
   kubectl get pv cvat-backend-data -o jsonpath='{.status.phase}{"\n"}'        # Released
   kubectl patch pv cvat-backend-data --type=json -p '[{"op":"replace","path":"/spec/claimRef","value":{"apiVersion":"v1","kind":"PersistentVolumeClaim","namespace":"cvat-rnd","name":"cvat-backend-data"}}]'
   kubectl get pv cvat-backend-data -o jsonpath='{.status.phase} {.spec.claimRef.namespace}/{.spec.claimRef.name} uid={.spec.claimRef.uid}{"\n"}'
   # Available cvat-rnd/cvat-backend-data uid=
   ```

   Undo: point the volume back at the old claim, recreate it from the release, then step 5's undo.

   ```sh
   kubectl patch pv cvat-backend-data --type=json -p '[{"op":"replace","path":"/spec/claimRef","value":{"apiVersion":"v1","kind":"PersistentVolumeClaim","namespace":"cvat","name":"cvat-backend-data"}}]'
   helm get manifest -n cvat cvat | yq 'select(.kind == "PersistentVolumeClaim" and .metadata.name == "cvat-backend-data")' | kubectl apply -n cvat -f -
   kubectl get pvc -n cvat cvat-backend-data                                    # Bound cvat-backend-data
   ```

7. Let Argo CD deploy: add the topic, and the ApplicationSet makes `cvat-rnd` within three minutes.

   ```sh
   gh repo edit Femtum/cvat --add-topic argo-cd
   kubectl get application -n argocd cvat-rnd -w                               # Synced  Healthy, after a few minutes
   kubectl get externalsecret -n cvat-rnd                                       # cvat-database-user SecretSynced
   kubectl get pvc -n cvat-rnd cvat-backend-data                                # Bound cvat-backend-data
   kubectl get jobs -n cvat-rnd                                                 # cvat-backend-initializer-r1 Complete
   kubectl get pods -n cvat-rnd                                                 # every pod Running
   kubectl get pv cvat-backend-data -o jsonpath='{.spec.claimRef.namespace}/{.spec.claimRef.name}{"\n"}'   # cvat-rnd/cvat-backend-data
   ```

   If the sync stops on a refused object, `kubectl get application -n argocd cvat-rnd -o jsonpath='{.status.operationState.message}'` names it.

   Undo: remove the topic (the Application goes, what it deployed stays), delete the namespace (the volume turns `Released` again, `cvat_data` stays), then step 6's undo.

   ```sh
   gh repo edit Femtum/cvat --remove-topic argo-cd
   kubectl get application -n argocd cvat-rnd                                  # NotFound, within three minutes
   kubectl delete namespace cvat-rnd
   ```

8. Check both ways in. Through the Gateway, which DNS does not reach yet:

   ```sh
   curl -sS --resolve cvat.rnd.intranet.femtum.com:443:10.0.100.48 \
     https://cvat.rnd.intranet.femtum.com/api/server/about                    # {"name":"Computer Vision Annotation Tool",...,"version":"2.82.0"...}
   kubectl get httproute -n cvat-rnd cvat -o jsonpath='{range .status.parents[0].conditions[*]}{.type}={.status} {end}{"\n"}'   # Accepted=True ResolvedRefs=True
   ```

   Through the shared ALB, as users reach it today: the new binding registers the new Traefik pod.

   ```sh
   kubectl get pods -n cvat-rnd -l app.kubernetes.io/name=traefik -o jsonpath='{.items[*].status.podIP}{"\n"}'
   aws elbv2 describe-target-health --target-group-arn "$(yq '.targetGroupBinding.targetGroupARN' deploy/cvat/values-rnd.yaml)" \
     --query 'TargetHealthDescriptions[].[Target.Id,TargetHealth.State]'      # that IP, healthy
   curl -sS https://cvat.rnd.intranet.femtum.com/api/server/about
   ```

   Then in a browser: log in, open an existing task and step through a few frames (its files are on `cvat_data`), and open Analytics (Grafana loads, with no history before today). Run the TLS check in "Database".

   Undo: step 7's.

9. Announce the end of the downtime.

### Cleanup

Once CVAT has served from `cvat-rnd` for a while, remove the old release. Nothing from here on can be undone, so check first that the volume is still `Retain` and bound to the new claim:

10. ```sh
    kubectl get pv cvat-backend-data -o jsonpath='{.spec.persistentVolumeReclaimPolicy} {.status.phase} {.spec.claimRef.namespace}/{.spec.claimRef.name}{"\n"}'
    # Retain Bound cvat-rnd/cvat-backend-data
    ```

11. Uninstall the old release, which also removes its ClusterRoles and its default IngressClass `cvat-traefik`. Helm never removes CRDs: Traefik's stay, which `cvat-rnd`'s Traefik uses.

    ```sh
    helm uninstall cvat -n cvat
    kubectl get ingressclass                                                    # no cvat-traefik
    kubectl get crd ingressroutes.traefik.io                                    # still there
    curl -sS https://cvat.rnd.intranet.femtum.com/api/server/about              # still answers
    ```

12. Delete the namespace. It takes the old binding (which deregisters only its own, already stopped, targets), the old `ExternalSecret`, and the EBS volumes of the old ClickHouse, Redis and kvrocks, and of `data-cvat-postgresql-0`: the bundled Postgres's, unused since CVAT moved to RDS (its database held no user and no task when checked before the switch). Snapshot it first if in doubt: `aws ec2 create-snapshot --volume-id "$(kubectl get pv "$(kubectl get pvc -n cvat data-cvat-postgresql-0 -o jsonpath='{.spec.volumeName}')" -o jsonpath='{.spec.csi.volumeHandle}')" --description "cvat data-cvat-postgresql-0 before deleting namespace cvat"`.

    ```sh
    kubectl delete namespace cvat
    aws elbv2 describe-target-health --target-group-arn "$(yq '.targetGroupBinding.targetGroupARN' deploy/cvat/values-rnd.yaml)" \
      --query 'TargetHealthDescriptions[].TargetHealth.State'                 # healthy, only cvat-rnd's pod
    ```

13. Delete the old secret, which nothing reads any more. Secrets Manager keeps it recoverable for 30 days.

    ```sh
    aws secretsmanager delete-secret --secret-id k8s/cvat/database --recovery-window-in-days 30
    ```

## Tests

They render `deploy/cvat` as Argo CD does and touch nothing. Run them before pushing; they need `helm` 4 (Argo CD v3.6.1 renders with 4.3.1) and `yq`.

```sh
deploy/tests/chart_test.sh
deploy/tests/cluster_test.sh
```
