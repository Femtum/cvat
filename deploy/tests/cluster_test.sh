#!/usr/bin/env bash
# Tests deploy/cluster/, the cluster-scoped objects a cluster admin applies by
# hand because Argo CD's project apps refuses them. Needs helm and yq; touches
# no cluster.
#
#   deploy/tests/cluster_test.sh
set -uo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
volume=$repo_root/deploy/cluster/backend-data.pv.yaml
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

test_given_the_backend_data_volume_when_read_then_it_is_reserved_for_the_claim_in_cvat_rnd() {
  # given
  local manifest=$volume

  # when
  local claim_ref; claim_ref=$(yq '.spec.claimRef' "$manifest")

  # then
  check "claimRef" "apiVersion: v1
kind: PersistentVolumeClaim
namespace: cvat-rnd
name: cvat-backend-data" "$claim_ref"
}

test_given_the_backend_data_volume_when_read_then_it_outlives_its_claim_on_cvat_data() {
  # given
  local manifest=$volume

  # when
  local volume_spec; volume_spec=$(yq '.metadata.name + " " + .spec.persistentVolumeReclaimPolicy + " " + .spec.storageClassName + " " + (.spec.accessModes | join(",")) + " " + .spec.csi.driver + " " + .spec.csi.volumeHandle' "$manifest")

  # then
  check "name, reclaim policy, class, access, driver and infra/'s handle" "cvat-backend-data Retain cvat-efs ReadWriteMany efs.csi.aws.com fs-0d0fe580cb106a236::fsap-0160840e460cf5637" "$volume_spec"
}

test_given_values_rnd_when_the_chart_is_rendered_then_its_claim_names_this_volume() {
  # given
  local work; work=$(mktemp -d)

  # when
  helm template cvat "$chart" --namespace cvat-rnd --values "$chart/values-rnd.yaml" --skip-crds --skip-tests > "$work/rendered.yaml"

  # then
  check "the claim the volume reserves itself for, on the volume" "cvat-rnd/cvat-backend-data -> cvat-backend-data cvat-efs" "$(yq -N 'select(.kind == "PersistentVolumeClaim") | "cvat-rnd/" + .metadata.name + " -> " + .spec.volumeName + " " + .spec.storageClassName' "$work/rendered.yaml")"
  rm -rf "$work"
}

test_given_deploy_cluster_when_listed_then_the_application_set_makes_no_application_of_it() {
  # given
  local directory=$repo_root/deploy/cluster

  # when
  local values_files; values_files=$(find "$directory" -name 'values-*.yaml')

  # then
  check "no values-<env>.yaml, which the ApplicationSet would deploy" "" "$values_files"
}

test_given_the_backend_data_volume_when_read_then_it_is_reserved_for_the_claim_in_cvat_rnd
test_given_the_backend_data_volume_when_read_then_it_outlives_its_claim_on_cvat_data
test_given_values_rnd_when_the_chart_is_rendered_then_its_claim_names_this_volume
test_given_deploy_cluster_when_listed_then_the_application_set_makes_no_application_of_it

if [[ $failures -ne 0 ]]; then
  echo "$failures failed"
  exit 1
fi
echo "all passed"
