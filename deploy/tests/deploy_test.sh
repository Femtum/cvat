#!/usr/bin/env bash
# Tests deploy/deploy.sh against stub aws, terraform, helm and kubectl binaries
# that log their calls, so nothing reaches AWS or the cluster.
#
#   deploy/tests/deploy_test.sh
set -uo pipefail

script=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/deploy.sh
repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
failures=0

# Builds a directory of stub tools. Each appends its call to $CALLS; kubectl
# also appends the manifest it is given on stdin. terraform answers from
# $BACKEND_DATA_VOLUME_HANDLE, $TARGET_GROUP_ARN, $URL and $DATABASE_ADDRESS.
make_stubs() {
  local bin=$1
  mkdir -p "$bin"
  for tool in aws helm; do
    # shellcheck disable=SC2016 # $* and $CALLS belong to the stub, not to this script.
    printf '#!/usr/bin/env bash\necho "%s $*" >> "$CALLS"\n' "$tool" > "$bin/$tool"
  done
  cat > "$bin/kubectl" <<'EOF'
#!/usr/bin/env bash
echo "kubectl $*" >> "$CALLS"
[[ "$*" == "apply -f -" ]] && cat >> "$CALLS"
exit 0
EOF
  cat > "$bin/terraform" <<'EOF'
#!/usr/bin/env bash
echo "terraform $*" >> "$CALLS"
case "${*: -1}" in
  backend_data_volume_handle) printf '%s' "$BACKEND_DATA_VOLUME_HANDLE" ;;
  target_group_arn) printf '%s' "$TARGET_GROUP_ARN" ;;
  url) printf '%s' "$URL" ;;
  database_address) printf '%s' "$DATABASE_ADDRESS" ;;
esac
EOF
  chmod +x "$bin"/*
}

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

test_given_both_outputs_when_deploying_then_the_volume_the_release_and_the_binding_are_applied_in_order() {
  # given
  local work; work=$(mktemp -d)
  make_stubs "$work/bin"
  export CALLS="$work/calls" BACKEND_DATA_VOLUME_HANDLE="fs-0123456789abcdef0::fsap-0123456789abcdef0"
  export TARGET_GROUP_ARN="arn:aws:elasticloadbalancing:ca-central-1:111122223333:targetgroup/cvat-http/0123456789abcdef"
  export URL="https://cvat.rnd.intranet.femtum.com"
  export DATABASE_ADDRESS="cvat-database.abcdefghijkl.ca-central-1.rds.amazonaws.com"

  # when
  local status=0
  (cd "$work" && PATH="$work/bin:/usr/bin:/bin" "$script") >/dev/null 2>&1 || status=$?

  # then
  check "deploys successfully" "0" "$status"
  check "calls the tools in order with the rendered manifests" "terraform -chdir=$repo_root/infra output -raw backend_data_volume_handle
terraform -chdir=$repo_root/infra output -raw target_group_arn
terraform -chdir=$repo_root/infra output -raw url
terraform -chdir=$repo_root/infra output -raw database_address
aws eks update-kubeconfig --region ca-central-1 --name femtum-rnd
helm dependency update $repo_root/helm-chart
kubectl apply -f $repo_root/deploy/namespace.yaml
kubectl apply -f -
$(sed 's|VOLUME_HANDLE|fs-0123456789abcdef0::fsap-0123456789abcdef0|' "$repo_root/deploy/backend-data.pv.yaml")
kubectl apply -f $repo_root/deploy/database-user.external-secret.yaml
kubectl wait --for=condition=Ready externalsecret/cvat-database-user --namespace cvat --timeout 2m
helm upgrade --install cvat $repo_root/helm-chart --namespace cvat -f $repo_root/helm-chart/cvat.values.yaml -f $repo_root/deploy/cvat.values.yaml --set-string ingress.hostname=cvat.rnd.intranet.femtum.com --set-string grafana.grafana\\.ini.server.root_url=https://cvat.rnd.intranet.femtum.com/analytics --set-string postgresql.external.host=cvat-database.abcdefghijkl.ca-central-1.rds.amazonaws.com --wait --wait-for-jobs --timeout 15m
kubectl apply -f -
$(sed 's|TARGET_GROUP_ARN|arn:aws:elasticloadbalancing:ca-central-1:111122223333:targetgroup/cvat-http/0123456789abcdef|' "$repo_root/deploy/target-group-binding.yaml")
kubectl apply -f $repo_root/deploy/traefik.target-group-configuration.yaml
kubectl apply -f -
$(sed 's|HOSTNAME|cvat.rnd.intranet.femtum.com|' "$repo_root/deploy/http-route.yaml")" "$(cat "$CALLS")"
  rm -rf "$work"
}

test_given_both_outputs_when_deploying_then_the_manifests_carry_the_handle_the_arn_and_the_host() {
  # given
  local work; work=$(mktemp -d)
  make_stubs "$work/bin"
  export CALLS="$work/calls" BACKEND_DATA_VOLUME_HANDLE="fs-0123456789abcdef0::fsap-0123456789abcdef0"
  export TARGET_GROUP_ARN="arn:aws:elasticloadbalancing:ca-central-1:111122223333:targetgroup/cvat-http/0123456789abcdef"
  export URL="https://cvat.rnd.intranet.femtum.com"
  export DATABASE_ADDRESS="cvat-database.abcdefghijkl.ca-central-1.rds.amazonaws.com"

  # when
  (PATH="$work/bin:/usr/bin:/bin" "$script") >/dev/null 2>&1

  # then
  check "the volume handle is applied" "    volumeHandle: fs-0123456789abcdef0::fsap-0123456789abcdef0" "$(grep 'volumeHandle:' "$CALLS")"
  check "the target group ARN is applied" "  targetGroupARN: arn:aws:elasticloadbalancing:ca-central-1:111122223333:targetgroup/cvat-http/0123456789abcdef" "$(grep 'targetGroupARN:' "$CALLS")"
  check "no store or role of its own is applied" "" "$(grep -E 'kind: SecretStore|role:' "$CALLS")"
  check "the route carries the host, without its scheme" "    - cvat.rnd.intranet.femtum.com" "$(grep -A1 'hostnames:' "$CALLS" | tail -1)"
  check "no placeholder is left" "" "$(grep -E 'VOLUME_HANDLE|TARGET_GROUP_ARN|HOSTNAME' "$CALLS")"
  rm -rf "$work"
}

test_given_infra_not_applied_when_deploying_then_it_stops_before_touching_the_cluster() {
  # given
  local work; work=$(mktemp -d)
  make_stubs "$work/bin"
  export CALLS="$work/calls" BACKEND_DATA_VOLUME_HANDLE="" TARGET_GROUP_ARN="" URL=""

  # when
  local status=0 output
  output=$(PATH="$work/bin:/usr/bin:/bin" "$script" 2>&1) || status=$?

  # then
  check "fails" "1" "$status"
  check "says why" "deploy.sh: infra/ publishes no backend_data_volume_handle: apply infra/ first" "$output"
  check "never calls aws, helm or kubectl" "" "$(grep -E '^(aws|helm|kubectl) ' "$CALLS")"
  rm -rf "$work"
}

test_given_infra_without_a_url_when_deploying_then_it_stops_before_touching_the_cluster() {
  # given
  local work; work=$(mktemp -d)
  make_stubs "$work/bin"
  export CALLS="$work/calls" BACKEND_DATA_VOLUME_HANDLE="fs-0123456789abcdef0::fsap-0123456789abcdef0"
  export TARGET_GROUP_ARN="arn:aws:elasticloadbalancing:ca-central-1:111122223333:targetgroup/cvat-http/0123456789abcdef"
  export URL=""

  # when
  local status=0 output
  output=$(PATH="$work/bin:/usr/bin:/bin" "$script" 2>&1) || status=$?

  # then
  check "fails" "1" "$status"
  check "says why" "deploy.sh: infra/ publishes no url: apply infra/ first" "$output"
  check "never calls aws, helm or kubectl" "" "$(grep -E '^(aws|helm|kubectl) ' "$CALLS")"
  rm -rf "$work"
}

test_given_infra_without_a_database_address_when_deploying_then_it_stops_before_touching_the_cluster() {
  # given
  local work; work=$(mktemp -d)
  make_stubs "$work/bin"
  export CALLS="$work/calls" BACKEND_DATA_VOLUME_HANDLE="fs-0123456789abcdef0::fsap-0123456789abcdef0"
  export TARGET_GROUP_ARN="arn:aws:elasticloadbalancing:ca-central-1:111122223333:targetgroup/cvat-http/0123456789abcdef"
  export URL="https://cvat.rnd.intranet.femtum.com" DATABASE_ADDRESS=""

  # when
  local status=0 output
  output=$(PATH="$work/bin:/usr/bin:/bin" "$script" 2>&1) || status=$?

  # then
  check "fails" "1" "$status"
  check "says why" "deploy.sh: infra/ publishes no database_address: apply infra/ first" "$output"
  check "never calls aws, helm or kubectl" "" "$(grep -E '^(aws|helm|kubectl) ' "$CALLS")"
  rm -rf "$work"
}

test_given_helm_missing_when_deploying_then_it_stops_before_reading_anything() {
  # given
  local work; work=$(mktemp -d)
  make_stubs "$work/bin"
  rm "$work/bin/helm"
  export CALLS="$work/calls" BACKEND_DATA_VOLUME_HANDLE="fs-0123456789abcdef0::fsap-0123456789abcdef0"
  export TARGET_GROUP_ARN="arn:aws:elasticloadbalancing:ca-central-1:111122223333:targetgroup/cvat-http/0123456789abcdef"

  # when
  local status=0 output
  output=$(PATH="$work/bin:/usr/bin:/bin" "$script" 2>&1) || status=$?

  # then
  check "fails" "1" "$status"
  check "names the missing tool" "deploy.sh: helm is not installed" "$output"
  check "calls nothing" "" "$(cat "$CALLS" 2>/dev/null)"
  rm -rf "$work"
}

test_given_an_argument_when_deploying_then_it_is_refused() {
  # given
  local work; work=$(mktemp -d)
  make_stubs "$work/bin"
  export CALLS="$work/calls"

  # when
  local status=0 output
  output=$(PATH="$work/bin:/usr/bin:/bin" "$script" --dry-run 2>&1) || status=$?

  # then
  check "fails" "1" "$status"
  check "says it takes none" "deploy.sh: takes no arguments" "$output"
  check "calls nothing" "" "$(cat "$CALLS" 2>/dev/null)"
  rm -rf "$work"
}

test_given_both_outputs_when_deploying_then_the_volume_the_release_and_the_binding_are_applied_in_order
test_given_both_outputs_when_deploying_then_the_manifests_carry_the_handle_the_arn_and_the_host
test_given_infra_not_applied_when_deploying_then_it_stops_before_touching_the_cluster
test_given_infra_without_a_url_when_deploying_then_it_stops_before_touching_the_cluster
test_given_infra_without_a_database_address_when_deploying_then_it_stops_before_touching_the_cluster
test_given_helm_missing_when_deploying_then_it_stops_before_reading_anything
test_given_an_argument_when_deploying_then_it_is_refused

if [[ $failures -ne 0 ]]; then
  echo "$failures failed"
  exit 1
fi
echo "all passed"
