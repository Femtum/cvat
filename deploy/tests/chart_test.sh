#!/usr/bin/env bash
# Tests deploy/cvat as Argo CD renders it for Application cvat-rnd: helm
# template, release cvat, namespace cvat-rnd, values-rnd.yaml, CRDs and tests
# skipped as .argocd-source.yaml asks. Needs helm and yq; touches no cluster.
#
#   deploy/tests/chart_test.sh
set -uo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
chart=$repo_root/deploy/cvat
failures=0

check() {
  local name=$1 expected=$2 actual=$3
  if [[ "$expected" == "$actual" ]]; then
    echo "pass: $name"
  else
    echo "FAIL: $name"
    diff <(printf '%s\n' "$expected") <(printf '%s\n' "$actual") | sed 's/^/  /'
    failures=$((failures + 1))
  fi
}

test_given_values_rnd_when_rendered_then_only_namespaced_kinds_are_rendered() {
  # given
  local work; work=$(mktemp -d)

  # when
  helm template cvat "$chart" --namespace cvat-rnd --values "$chart/values-rnd.yaml" --skip-crds --skip-tests > "$work/rendered.yaml"

  # then
  check "every kind is namespaced: the project apps refuses all cluster-scoped kinds but Namespace" "ConfigMap
Deployment
ExternalSecret
HTTPRoute
Ingress
IngressRoute
Job
Middleware
NetworkPolicy
PersistentVolumeClaim
PodDisruptionBudget
Role
RoleBinding
Secret
Service
ServiceAccount
StatefulSet
TargetGroupBinding
TargetGroupConfiguration" "$(yq -N '.kind' "$work/rendered.yaml" | sort -u)"
  rm -rf "$work"
}

test_given_values_rnd_when_rendered_twice_then_both_renders_are_identical() {
  # given
  local work; work=$(mktemp -d)

  # when
  helm template cvat "$chart" --namespace cvat-rnd --values "$chart/values-rnd.yaml" --skip-crds --skip-tests > "$work/first.yaml"
  helm template cvat "$chart" --namespace cvat-rnd --values "$chart/values-rnd.yaml" --skip-crds --skip-tests > "$work/second.yaml"

  # then
  check "no random value: Argo CD would see drift and restart pods on every refresh" "" "$(diff "$work/first.yaml" "$work/second.yaml")"
  rm -rf "$work"
}

test_given_values_rnd_when_rendered_then_the_http_route_sends_cvat_s_host_on_the_platform_gateway_to_traefik() {
  # given
  local work; work=$(mktemp -d)

  # when
  helm template cvat "$chart" --namespace cvat-rnd --values "$chart/values-rnd.yaml" --skip-crds --skip-tests > "$work/rendered.yaml"

  # then
  check "the route" "apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: cvat
spec:
  parentRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      namespace: platform-gateway
      name: platform
      sectionName: https
  hostnames:
    - \"cvat.rnd.intranet.femtum.com\"
  rules:
    - backendRefs:
        - name: cvat-traefik
          port: 80" "$(yq 'select(.kind == "HTTPRoute") | ... comments=""' "$work/rendered.yaml")"
  rm -rf "$work"
}

test_given_values_rnd_when_rendered_then_traefik_s_target_groups_check_ping() {
  # given
  local work; work=$(mktemp -d)

  # when
  helm template cvat "$chart" --namespace cvat-rnd --values "$chart/values-rnd.yaml" --skip-crds --skip-tests > "$work/rendered.yaml"

  # then
  check "the Gateway's target group for cvat-traefik registers pods and checks /ping" "targetReference:
  name: cvat-traefik
defaultConfiguration:
  targetType: ip
  healthCheckConfig:
    healthCheckPath: /ping" "$(yq 'select(.kind == "TargetGroupConfiguration") | .spec' "$work/rendered.yaml")"
  rm -rf "$work"
}

test_given_values_rnd_when_rendered_then_the_database_user_is_read_from_k8s_cvat_rnd_database_before_wave_0() {
  # given
  local work; work=$(mktemp -d)

  # when
  helm template cvat "$chart" --namespace cvat-rnd --values "$chart/values-rnd.yaml" --skip-crds --skip-tests > "$work/rendered.yaml"

  # then
  check "the ExternalSecret's target, store and keys" "cvat-database-user ClusterSecretStore/aws-secrets-manager
username <- k8s/cvat-rnd/database.username
database <- k8s/cvat-rnd/database.database
password <- k8s/cvat-rnd/database.password" "$(yq -N 'select(.kind == "ExternalSecret") | .spec | [.target.name + " " + .secretStoreRef.kind + "/" + .secretStoreRef.name] + [.data[] | .secretKey + " <- " + .remoteRef.key + "." + .remoteRef.property] | .[]' "$work/rendered.yaml")"
  check "synced in wave -1" "-1" "$(yq -N 'select(.kind == "ExternalSecret") | .metadata.annotations["argocd.argoproj.io/sync-wave"]' "$work/rendered.yaml")"
  check "the chart reads the Secret it syncs" "cvat-database-user" "$(yq -N 'select(.kind == "Deployment" and .metadata.name == "cvat-backend-server") | .spec.template.spec.containers[0].env[] | select(.name == "CVAT_POSTGRES_PASSWORD") | .valueFrom.secretKeyRef.name' "$work/rendered.yaml")"
  rm -rf "$work"
}

test_given_values_rnd_when_rendered_then_the_initializer_is_a_sync_hook_recreated_on_every_sync() {
  # given
  local work; work=$(mktemp -d)

  # when
  helm template cvat "$chart" --namespace cvat-rnd --values "$chart/values-rnd.yaml" --skip-crds --skip-tests > "$work/rendered.yaml"

  # then
  check "the Job's Argo CD annotations, in wave 0 after the Secret" "cvat-backend-initializer-r1
argocd.argoproj.io/hook: Sync
argocd.argoproj.io/hook-delete-policy: BeforeHookCreation" "$(yq -N 'select(.kind == "Job") | [.metadata.name] + [.metadata.annotations | to_entries | .[] | .key + ": " + .value] | .[]' "$work/rendered.yaml")"
  check "no Helm hook left, which Argo CD would map to PreSync" "" "$(yq -N 'select(.metadata.annotations["helm.sh/hook"] != null) | .kind + "/" + .metadata.name' "$work/rendered.yaml")"
  rm -rf "$work"
}

test_given_values_rnd_when_rendered_then_the_target_group_binding_registers_traefik_into_the_shared_alb_group() {
  # given
  local work; work=$(mktemp -d)

  # when
  helm template cvat "$chart" --namespace cvat-rnd --values "$chart/values-rnd.yaml" --skip-crds --skip-tests > "$work/rendered.yaml"

  # then
  check "the binding" "name: cvat
spec:
  serviceRef:
    name: cvat-traefik
    port: web
  targetGroupARN: arn:aws:elasticloadbalancing:ca-central-1:148761635720:targetgroup/cvat-http/3584356a63c16cbc
  targetType: ip
  multiClusterTargetGroup: true" "$(yq 'select(.kind == "TargetGroupBinding") | {"name": .metadata.name, "spec": .spec}' "$work/rendered.yaml")"
  rm -rf "$work"
}

test_given_values_rnd_when_rendered_then_the_backend_data_claim_is_pinned_to_the_static_volume_and_never_pruned() {
  # given
  local work; work=$(mktemp -d)

  # when
  helm template cvat "$chart" --namespace cvat-rnd --values "$chart/values-rnd.yaml" --skip-crds --skip-tests > "$work/rendered.yaml"

  # then
  check "the only claim" "metadata:
  name: cvat-backend-data
  annotations:
    argocd.argoproj.io/sync-wave: \"-1\"
    argocd.argoproj.io/sync-options: Delete=false,Prune=false
    helm.sh/resource-policy: keep
spec:
  accessModes:
    - ReadWriteMany
  storageClassName: cvat-efs
  volumeName: cvat-backend-data
  resources:
    requests:
      storage: 1Ti" "$(yq 'select(.kind == "PersistentVolumeClaim") | {"metadata": .metadata, "spec": .spec} | ... comments=""' "$work/rendered.yaml")"
  rm -rf "$work"
}

test_given_values_rnd_when_rendered_then_every_backend_pod_mounts_the_pinned_claim() {
  # given
  local work; work=$(mktemp -d)

  # when
  helm template cvat "$chart" --namespace cvat-rnd --values "$chart/values-rnd.yaml" --skip-crds --skip-tests > "$work/rendered.yaml"

  # then
  check "one cvat-backend-data volume per backend pod, on the claim" "Deployment/cvat-backend-server cvat-backend-data
Deployment/cvat-backend-worker-annotation cvat-backend-data
Deployment/cvat-backend-worker-chunks cvat-backend-data
Deployment/cvat-backend-worker-consensus cvat-backend-data
Deployment/cvat-backend-worker-export cvat-backend-data
Deployment/cvat-backend-worker-import cvat-backend-data
Deployment/cvat-backend-worker-qualityreports cvat-backend-data
Deployment/cvat-backend-worker-utils cvat-backend-data
Deployment/cvat-backend-worker-webhooks cvat-backend-data
Job/cvat-backend-initializer-r1 cvat-backend-data" "$(yq -N 'select(.spec.template.spec.volumes[]?.name == "cvat-backend-data") | .kind + "/" + .metadata.name + " " + ([.spec.template.spec.volumes[] | select(.name == "cvat-backend-data") | .persistentVolumeClaim.claimName] | join(","))' "$work/rendered.yaml" | sort)"
  rm -rf "$work"
}

test_given_values_rnd_when_rendered_then_traefik_claims_the_ingresses_by_annotation_without_a_class() {
  # given
  local work; work=$(mktemp -d)

  # when
  helm template cvat "$chart" --namespace cvat-rnd --values "$chart/values-rnd.yaml" --skip-crds --skip-tests > "$work/rendered.yaml"

  # then
  check "both Ingresses" "cvat-analytics cvat.rnd.intranet.femtum.com class=null annotation=traefik
cvat cvat.rnd.intranet.femtum.com class=null annotation=traefik" "$(yq -N 'select(.kind == "Ingress") | .metadata.name + " " + .spec.rules[0].host + " class=" + (.spec.ingressClassName // "null") + " annotation=" + .metadata.annotations["kubernetes.io/ingress.class"]' "$work/rendered.yaml")"
  check "Traefik watches its own namespace only" "--providers.kubernetescrd.namespaces=cvat-rnd
--providers.kubernetesingress.namespaces=cvat-rnd" "$(yq -N 'select(.kind == "Deployment" and .metadata.name == "cvat-traefik") | .spec.template.spec.containers[0].args[] | select(test("namespaces="))' "$work/rendered.yaml")"
  rm -rf "$work"
}

test_given_values_rnd_when_rendered_then_grafana_creates_no_admin_and_answers_under_analytics() {
  # given
  local work; work=$(mktemp -d)

  # when
  helm template cvat "$chart" --namespace cvat-rnd --values "$chart/values-rnd.yaml" --skip-crds --skip-tests > "$work/rendered.yaml"

  # then
  check "no admin Secret, whose password the chart would draw at random" "" "$(yq -N 'select(.kind == "Secret" and .metadata.name == "cvat-grafana") | .metadata.name' "$work/rendered.yaml")"
  check "initial admin creation disabled" "true" "$(yq -N 'select(.kind == "Deployment" and .metadata.name == "cvat-grafana") | .spec.template.spec.containers[0].env[] | select(.name == "GF_SECURITY_DISABLE_INITIAL_ADMIN_CREATION") | .value' "$work/rendered.yaml")"
  check "root URL on the host" "root_url = https://cvat.rnd.intranet.femtum.com/analytics" "$(yq -N 'select(.kind == "ConfigMap" and .metadata.name == "cvat-grafana") | .data["grafana.ini"]' "$work/rendered.yaml" | grep 'root_url')"
  rm -rf "$work"
}

test_given_values_rnd_when_rendered_then_the_database_host_is_cvat_database_over_tls() {
  # given
  local work; work=$(mktemp -d)

  # when
  helm template cvat "$chart" --namespace cvat-rnd --values "$chart/values-rnd.yaml" --skip-crds --skip-tests > "$work/rendered.yaml"

  # then
  check "the server's database host and TLS mode" "CVAT_POSTGRES_HOST=cvat-database.ct0oy4oug14q.ca-central-1.rds.amazonaws.com
PGSSLMODE=require" "$(yq -N 'select(.kind == "Deployment" and .metadata.name == "cvat-backend-server") | .spec.template.spec.containers[0].env[] | select(.name == "CVAT_POSTGRES_HOST" or .name == "PGSSLMODE") | .name + "=" + .value' "$work/rendered.yaml")"
  check "no bundled Postgres" "" "$(yq -N 'select(.metadata.name == "cvat-postgresql") | .kind' "$work/rendered.yaml")"
  rm -rf "$work"
}

test_given_no_target_group_when_rendering_then_it_fails_naming_infra_s_output() {
  # given
  local work; work=$(mktemp -d)

  # when
  local status=0
  helm template cvat "$chart" --namespace cvat-rnd --values "$chart/values-rnd.yaml" --set targetGroupBinding.targetGroupARN= --skip-crds --skip-tests > /dev/null 2> "$work/error" || status=$?

  # then
  check "fails" "1" "$status"
  check "says what is missing" "1" "$(grep -c "targetGroupBinding.targetGroupARN is required: infra/'s target_group_arn" "$work/error")"
  rm -rf "$work"
}

test_given_no_hostname_when_rendering_then_it_fails() {
  # given
  local work; work=$(mktemp -d)

  # when
  local status=0
  helm template cvat "$chart" --namespace cvat-rnd --values "$chart/values-rnd.yaml" --set global.hostname= --skip-crds --skip-tests > /dev/null 2> "$work/error" || status=$?

  # then
  check "fails" "1" "$status"
  check "says what is missing" "1" "$(grep -c 'global.hostname is required' "$work/error")"
  rm -rf "$work"
}

test_given_the_source_overrides_when_read_then_argo_cd_skips_crds_and_tests() {
  # given
  local overrides=$chart/.argocd-source.yaml

  # when
  local helm_options; helm_options=$(yq '.helm' "$overrides")

  # then
  check "the options the renders above assume" "skipCrds: true
skipTests: true" "$helm_options"
}

test_given_only_the_files_git_carries_when_rendered_then_the_vendored_package_renders_without_dependency_build() {
  # given
  local work; work=$(mktemp -d)
  (cd "$repo_root" && git ls-files --cached --others --exclude-standard deploy/cvat) | while read -r file; do
    mkdir -p "$work/$(dirname "$file")" && cp "$repo_root/$file" "$work/$file"
  done

  # when
  local status=0
  helm template cvat "$work/deploy/cvat" --namespace cvat-rnd --values "$work/deploy/cvat/values-rnd.yaml" --skip-crds --skip-tests > "$work/rendered.yaml" 2>&1 || status=$?

  # then
  check "renders" "0" "$status"
  check "with upstream's subcharts" "StatefulSet/cvat-clickhouse-shard0
StatefulSet/cvat-kvrocks
StatefulSet/cvat-redis-master
StatefulSet/cvat-vector" "$(yq -N 'select(.kind == "StatefulSet") | .kind + "/" + .metadata.name' "$work/rendered.yaml" | sort)"
  rm -rf "$work"
}

test_given_the_vendored_package_when_unpacked_then_it_is_upstream_s_chart_with_its_dependencies() {
  # given
  local work; work=$(mktemp -d)

  # when
  tar -xzf "$chart/charts/cvat-2.82.0.tgz" -C "$work"

  # then
  check "is upstream's chart at this branch's tag" "cvat 2.82.0" "$(yq '.name + " " + .version' "$work/cvat/Chart.yaml")"
  check "values.yaml, templates/ and analytics/ match helm-chart/: rebuild the package after a rebase" "" "$(for path in values.yaml templates analytics; do diff -r "$repo_root/helm-chart/$path" "$work/cvat/$path"; done)"
  check "carries the dependencies git ignores in helm-chart/charts/" "clickhouse
grafana
nuclio
postgresql
redis
traefik
vector" "$(ls "$work/cvat/charts")"
  rm -rf "$work"
}

test_given_values_rnd_when_rendered_then_only_namespaced_kinds_are_rendered
test_given_values_rnd_when_rendered_twice_then_both_renders_are_identical
test_given_values_rnd_when_rendered_then_the_http_route_sends_cvat_s_host_on_the_platform_gateway_to_traefik
test_given_values_rnd_when_rendered_then_traefik_s_target_groups_check_ping
test_given_values_rnd_when_rendered_then_the_database_user_is_read_from_k8s_cvat_rnd_database_before_wave_0
test_given_values_rnd_when_rendered_then_the_initializer_is_a_sync_hook_recreated_on_every_sync
test_given_values_rnd_when_rendered_then_the_target_group_binding_registers_traefik_into_the_shared_alb_group
test_given_values_rnd_when_rendered_then_the_backend_data_claim_is_pinned_to_the_static_volume_and_never_pruned
test_given_values_rnd_when_rendered_then_every_backend_pod_mounts_the_pinned_claim
test_given_values_rnd_when_rendered_then_traefik_claims_the_ingresses_by_annotation_without_a_class
test_given_values_rnd_when_rendered_then_grafana_creates_no_admin_and_answers_under_analytics
test_given_values_rnd_when_rendered_then_the_database_host_is_cvat_database_over_tls
test_given_no_target_group_when_rendering_then_it_fails_naming_infra_s_output
test_given_no_hostname_when_rendering_then_it_fails
test_given_the_source_overrides_when_read_then_argo_cd_skips_crds_and_tests
test_given_only_the_files_git_carries_when_rendered_then_the_vendored_package_renders_without_dependency_build
test_given_the_vendored_package_when_unpacked_then_it_is_upstream_s_chart_with_its_dependencies

if [[ $failures -ne 0 ]]; then
  echo "$failures failed"
  exit 1
fi
echo "all passed"
