#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICE_PATH="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/lib/assert.sh"
# shellcheck source=/dev/null
source "$SERVICE_PATH/scripts/resolve_placement_lib"

# A cloud-providers config as tofu-modules publishes it (project.id), plus
# the optional `services` block.
PROVIDER_JSON='{
  "project": {"id": "project-from-provider"},
  "services": {
    "region": "us-west1",
    "network": "projects/host-project/global/networks/shared-vpc",
    "tfstate": {"bucket": "bucket-from-provider"}
  }
}'

# Every test runs with a clean slate: these are exactly the variables the
# resolvers consult, and a leaked one would make an assertion pass for the
# wrong reason.
clear_env() {
  unset SERVICES_GCP_PROJECT GOOGLE_CLOUD_PROJECT SERVICES_GCP_REGION \
        SERVICES_GCP_NETWORK SERVICES_TFSTATE_BUCKET || true
}

echo "== sourcing the library has no side effects =="
SIDE=$(bash -c "source '$SERVICE_PATH/scripts/resolve_placement_lib'" 2>&1)
assert_eq "" "$SIDE" "sourcing prints nothing"
CODE_ONLY=$(grep -v '^[[:space:]]*#' "$SERVICE_PATH/scripts/resolve_placement_lib")
for cli in np gcloud gsutil curl; do
  if printf '%s' "$CODE_ONLY" | grep -qw -- "$cli"; then
    echo "  FAIL the library calls $cli" >&2; FAILURES=$((FAILURES + 1))
  else
    echo "  ok   the library calls no $cli"
  fi
done

echo "== first_non_empty is the precedence primitive =="
assert_eq "a"  "$(first_non_empty "a" "b" "c")" "first wins"
assert_eq "b"  "$(first_non_empty ""  "b" "c")" "skips a leading empty"
assert_eq "c"  "$(first_non_empty ""  ""  "c")" "skips two leading empties"
assert_eq ""   "$(first_non_empty ""  ""  "")"  "all empty yields empty"
assert_eq ""   "$(first_non_empty)"             "no arguments yields empty"
# A value that is only whitespace is a value, not an absence — matching how
# the shell's own ${x:-y} behaves, so the two never disagree.
assert_eq " "  "$(first_non_empty " " "b")"     "whitespace counts as present"

echo "== provider_field reads nested paths and never crashes =="
assert_eq "project-from-provider" "$(provider_field "$PROVIDER_JSON" "project.id")"          "project.id"
assert_eq "us-west1"              "$(provider_field "$PROVIDER_JSON" "services.region")"     "one level deep"
assert_eq "bucket-from-provider"  "$(provider_field "$PROVIDER_JSON" "services.tfstate.bucket")" "two levels deep"
assert_eq "" "$(provider_field "$PROVIDER_JSON" "services.nope")"      "absent field is empty"
assert_eq "" "$(provider_field "$PROVIDER_JSON" "a.b.c.d.e")"          "absent deep path is empty"
assert_eq "" "$(provider_field '' 'services.region')"                 "empty json is empty"
assert_eq "" "$(provider_field '{}' 'services.region')"               "empty object is empty"
assert_eq "" "$(provider_field 'not json at all' 'services.region')"  "malformed json does not crash"
assert_eq "" "$(provider_field "$PROVIDER_JSON" '')"                  "empty path is empty"
# A non-string must not leak jq's rendering of an object into a shell variable
# that is about to become a bucket name.
assert_eq "" "$(provider_field "$PROVIDER_JSON" 'services.tfstate')"  "an object reads as empty, not as JSON"
assert_eq "" "$(provider_field '{"project":{"id":123}}' 'project.id')" "a number reads as empty"
assert_eq "" "$(provider_field '{"project":{"id":null}}' 'project.id')" "null reads as empty, not as the string null"

echo "== project: values.yaml, then provider project.id, then SERVICES_GCP_PROJECT, then GOOGLE_CLOUD_PROJECT =="
(
  clear_env
  export SERVICES_GCP_PROJECT="project-from-services-env" GOOGLE_CLOUD_PROJECT="project-from-gcloud-env"
  assert_eq "project-from-values"       "$(placement_project "$PROVIDER_JSON" "project-from-values")" "values wins"
  assert_eq "project-from-provider"     "$(placement_project "$PROVIDER_JSON" "")"                    "provider beats env"
  assert_eq "project-from-services-env" "$(placement_project '{}' "")"                                "SERVICES_GCP_PROJECT beats GOOGLE_CLOUD_PROJECT"
  unset SERVICES_GCP_PROJECT
  assert_eq "project-from-gcloud-env"   "$(placement_project '{}' "")"                                "GOOGLE_CLOUD_PROJECT is the last resort"
  unset GOOGLE_CLOUD_PROJECT
  assert_eq ""                          "$(placement_project '{}' "")"                                "unset everywhere is empty"
  finish_tests
) || FAILURES=$((FAILURES + 1))

echo "== a stock provider (project.id only) still supplies the project =="
(
  clear_env
  STOCK='{"project":{"id":"stock-project"},"networking":{"domain_name":"d"}}'
  export SERVICES_GCP_REGION="us-central1" SERVICES_GCP_NETWORK="env-vpc" SERVICES_TFSTATE_BUCKET="env-bucket"
  assert_eq "stock-project" "$(placement_project "$STOCK" "")"        "project from project.id"
  assert_eq "us-central1"   "$(placement_region "$STOCK" "")"         "no services block: region from env"
  assert_eq "env-vpc"       "$(placement_network "$STOCK" "")"        "no services block: network from env"
  assert_eq "env-bucket"    "$(placement_tfstate_bucket "$STOCK" "")" "no services block: bucket from env"
  finish_tests
) || FAILURES=$((FAILURES + 1))

echo "== region, network and bucket resolve independently, values > provider > env =="
(
  clear_env
  export SERVICES_GCP_REGION="region-env" SERVICES_GCP_NETWORK="network-env" SERVICES_TFSTATE_BUCKET="bucket-env"
  assert_eq "region-values"  "$(placement_region "$PROVIDER_JSON" "region-values")"  "region: values wins"
  assert_eq "us-west1"       "$(placement_region "$PROVIDER_JSON" "")"               "region: provider beats env"
  assert_eq "region-env"     "$(placement_region '{}' "")"                           "region: env last"
  assert_eq "network-values" "$(placement_network "$PROVIDER_JSON" "network-values")" "network: values wins"
  assert_eq "projects/host-project/global/networks/shared-vpc" "$(placement_network "$PROVIDER_JSON" "")" "network: provider beats env"
  assert_eq "network-env"    "$(placement_network '{}' "")"                          "network: env last"
  assert_eq "bucket-values"  "$(placement_tfstate_bucket "$PROVIDER_JSON" "bucket-values")" "bucket: values wins"
  assert_eq "bucket-from-provider" "$(placement_tfstate_bucket "$PROVIDER_JSON" "")"  "bucket: provider beats env"
  assert_eq "bucket-env"     "$(placement_tfstate_bucket '{}' "")"                   "bucket: env last"
  finish_tests
) || FAILURES=$((FAILURES + 1))

echo "== region, network and bucket may legitimately resolve to empty =="
(
  clear_env
  assert_eq "" "$(placement_region '{}' "")"         "region unset everywhere is empty, not an error"
  assert_eq "" "$(placement_network '{}' "")"        "network unset everywhere is empty"
  assert_eq "" "$(placement_tfstate_bucket '{}' "")" "bucket unset everywhere is empty (build_context decides)"
  finish_tests
) || FAILURES=$((FAILURES + 1))

echo "== network_self_link normalizes every accepted shape =="
assert_eq "projects/p-1/global/networks/my-vpc" "$(network_self_link p-1 my-vpc)" \
  "a bare name lives in the target project"
assert_eq "projects/host/global/networks/shared" "$(network_self_link p-1 projects/host/global/networks/shared)" \
  "a projects/... path is kept, so a shared VPC in a host project works"
assert_eq "projects/host/global/networks/shared" \
  "$(network_self_link p-1 https://www.googleapis.com/compute/v1/projects/host/global/networks/shared)" \
  "a compute API URL is trimmed to projects/..."
assert_eq "projects/host/global/networks/shared" \
  "$(network_self_link p-1 //compute.googleapis.com/projects/host/global/networks/shared)" \
  "a full resource name is trimmed to projects/..."
assert_eq "" "$(network_self_link p-1 "")" "an empty network stays empty, not a half-built path"
assert_eq "" "$(network_self_link "" "")"  "no arguments yields empty"

echo "== placement_source labels the winning tier without echoing the value =="
assert_eq "values.yaml"        "$(placement_source "v" "p" "e")" "values"
assert_eq "provider"           "$(placement_source ""  "p" "e")" "provider"
assert_eq "worker-environment" "$(placement_source ""  ""  "e")" "environment"
assert_eq "unset"              "$(placement_source ""  ""  "")"  "nothing"
assert_eq "values.yaml"        "$(placement_source "secret-value" "" "")" "the value itself is never printed"

finish_tests
