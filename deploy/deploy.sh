#!/usr/bin/env bash
# Installs or upgrades CVAT on the platform's cluster, from any directory, over
# the Client VPN, as AdministratorAccess. Steps and checks: deploy/README.md.
set -euo pipefail

# backend-data.pv.yaml reserves its volume for cvat/cvat-backend-data, and
# namespace.yaml, database-user.external-secret.yaml and
# target-group-binding.yaml live in namespace cvat: all follow this release.
readonly release=cvat
readonly namespace=cvat
readonly cluster=femtum-rnd
readonly region=ca-central-1

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
readonly repo_root

fail() {
  echo "deploy.sh: $*" >&2
  exit 1
}

require_tools() {
  local tool
  for tool in "$@"; do
    command -v "$tool" >/dev/null || fail "$tool is not installed"
  done
}

infra_output() {
  local value
  value=$(terraform -chdir="$repo_root/infra" output -raw "$1") || fail "cannot read $1 from infra/: run terraform login and terraform init there"
  [[ -n $value ]] || fail "infra/ publishes no $1: apply infra/ first"
  printf '%s' "$value"
}

# Applies a manifest with its placeholder replaced by a Terraform output.
apply_manifest() {
  local manifest=$1 placeholder=$2 value=$3
  sed "s|$placeholder|$value|" "$repo_root/deploy/$manifest" | kubectl apply -f -
}

main() {
  [[ $# -eq 0 ]] || fail "takes no arguments"
  require_tools aws terraform helm kubectl

  local volume_handle target_group_arn url database_address
  volume_handle=$(infra_output backend_data_volume_handle)
  target_group_arn=$(infra_output target_group_arn)
  url=$(infra_output url)
  database_address=$(infra_output database_address)

  aws eks update-kubeconfig --region "$region" --name "$cluster"
  helm dependency update "$repo_root/helm-chart"
  kubectl apply -f "$repo_root/deploy/namespace.yaml"
  apply_manifest backend-data.pv.yaml VOLUME_HANDLE "$volume_handle"
  # The initializer and every backend pod read the database user from this
  # Secret: sync it before the release starts them.
  kubectl apply -f "$repo_root/deploy/database-user.external-secret.yaml"
  kubectl wait --for=condition=Ready externalsecret/cvat-database-user --namespace "$namespace" --timeout 2m
  # The shared ALB terminates TLS for the host infra/ registered on it and
  # forwards plain HTTP to Traefik, which splits it by path. Grafana builds
  # its links and redirects from its own root URL. --wait-for-jobs holds the
  # release until the initializer has run CVAT's migrations.
  helm upgrade --install "$release" "$repo_root/helm-chart" \
    --namespace "$namespace" \
    -f "$repo_root/helm-chart/cvat.values.yaml" \
    -f "$repo_root/deploy/cvat.values.yaml" \
    --set-string "ingress.hostname=${url#https://}" \
    --set-string "grafana.grafana\.ini.server.root_url=$url/analytics" \
    --set-string "postgresql.external.host=$database_address" \
    --wait --wait-for-jobs --timeout 15m
  apply_manifest target-group-binding.yaml TARGET_GROUP_ARN "$target_group_arn"
}

main "$@"
