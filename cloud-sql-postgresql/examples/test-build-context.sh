#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICE_PATH="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/lib/assert.sh"

BC="$SERVICE_PATH/scripts/build_context"
SID="9f8e7d6c-1234-4321-abcd-000000000000"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# A values.yaml with placement filled in, so the test does not depend on the
# committed (intentionally empty) one.
cat > "$TMP/values.yaml" <<'YAML'
project_id: "np-services-test"
region: "us-east1"
network: "pg-vpc"
tfstate_bucket: "np-services-tfstate"
YAML

# Only the bucket: placement must then come from the provider or the env.
cat > "$TMP/bucket-only.yaml" <<'YAML'
project_id: ""
region: ""
network: ""
tfstate_bucket: "np-services-tfstate"
YAML

printf 'project_id: ""\nregion: ""\nnetwork: ""\ntfstate_bucket: ""\n' > "$TMP/empty.yaml"

# Every variable the resolvers consult. A value leaked from the developer's
# shell (GOOGLE_CLOUD_PROJECT is common) would make an assertion pass, or
# fail, for the wrong reason.
GCP_ENV_VARS="SERVICES_GCP_PROJECT GOOGLE_CLOUD_PROJECT SERVICES_GCP_REGION SERVICES_GCP_NETWORK SERVICES_TFSTATE_BUCKET NP_STUB_PROVIDER_JSON"

DUMP_VARS="SERVICE_ID SERVICE_NAME INSTANCE_NAME DATABASE_NAME PROJECT_ID REGION NETWORK
           TFSTATE_BUCKET TFSTATE_PREFIX OUTPUT_DIR TOFU_MODULE_DIR TOFU_INIT_VARIABLES TOFU_VARIABLES
           LINK_ID LINK_USERNAME LINK_ACCESS_LEVEL"

# run_bc <values_file> <context_json> [VAR=value ...]
# Sources build_context in a subshell, with stub np on PATH. Its own output
# goes to $TMP/bc.out; stdout carries the resulting environment as KEY=VALUE.
# Returns build_context's exit status.
run_bc() {
  local values="$1" ctx="$2"
  shift 2
  (
    # shellcheck disable=SC2086
    unset $GCP_ENV_VARS || true
    export PATH="$SCRIPT_DIR/stub-bin:$PATH"
    export NP_STUB_LOG="$TMP/np.log"
    export SERVICE_PATH VALUES="$values"
    export CONTEXT="$ctx"
    LINK=$(echo "$CONTEXT" | jq '.link'); export LINK
    ACTION_SOURCE=$([ "$LINK" = "null" ] && echo service || echo link); export ACTION_SOURCE
    local kv
    for kv in "$@"; do export "${kv?}"; done
    # shellcheck source=/dev/null
    source "$BC" >"$TMP/bc.out" 2>&1
    for v in $DUMP_VARS; do printf '%s=%s\n' "$v" "${!v:-}"; done
  )
}

# ctx <fixture> [jq_filter] — the fixture's notification, optionally patched.
ctx() { jq -c ".notification | ${2:-.}" "$SCRIPT_DIR/$1"; }

get() { printf '%s' "$1" | grep "^$2=" | head -1 | cut -d= -f2-; }

# expect_reject <label> <values_file> <context_json> [VAR=value ...]
expect_reject() {
  local label="$1"
  shift
  if run_bc "$@" >/dev/null; then
    echo "  FAIL $label (build_context succeeded)" >&2
    FAILURES=$((FAILURES + 1))
  else
    echo "  ok   $label"
  fi
}

# expect_ok <label> <values_file> <context_json> [VAR=value ...]
expect_ok() {
  local label="$1"
  shift
  if run_bc "$@" >/dev/null; then
    echo "  ok   $label"
  else
    echo "  FAIL $label (build_context failed: $(tail -2 "$TMP/bc.out" | tr '\n' ' '))" >&2
    FAILURES=$((FAILURES + 1))
  fi
}

# reject <jq_param_patch> <label> — a create with these parameters must fail.
reject() {
  expect_reject "$2" "$TMP/values.yaml" "$(ctx create.json ".parameters = (.parameters + $1)")"
}

echo "== create action =="
ENV_OUT=$(run_bc "$TMP/values.yaml" "$(ctx create.json)")

assert_eq "$SID" "$(get "$ENV_OUT" SERVICE_ID)" "SERVICE_ID parsed"
assert_eq "conciliation-db-9f8e7d6c" "$(get "$ENV_OUT" INSTANCE_NAME)" "instance name derived from service name"
assert_eq "conciliation" "$(get "$ENV_OUT" DATABASE_NAME)" "database name from parameters"
assert_eq "np-services-test" "$(get "$ENV_OUT" PROJECT_ID)" "project from values.yaml"
assert_eq "us-east1" "$(get "$ENV_OUT" REGION)" "region from values.yaml"
assert_eq "np-services-tfstate" "$(get "$ENV_OUT" TFSTATE_BUCKET)" "uses the shared bucket, never creates one"
assert_eq "cloud-sql-postgresql/$SID/deployment" "$(get "$ENV_OUT" TFSTATE_PREFIX)" "per-service state prefix exported for the link steps"
assert_contains "$(get "$ENV_OUT" TOFU_MODULE_DIR)" "/deployment" "module dir points at deployment/"
assert_contains "$(get "$ENV_OUT" OUTPUT_DIR)" "np-service-$SID" "output dir is per service instance"

echo "== a bare network name becomes a self link in the target project =="
assert_eq "projects/np-services-test/global/networks/pg-vpc" "$(get "$ENV_OUT" NETWORK)" "pg-vpc normalized"

echo "== backend settings are written as a FILE, never as a flag string =="
BACKEND="$(get "$ENV_OUT" OUTPUT_DIR)/backend.hcl"
assert_eq "yes" "$([ -f "$BACKEND" ] && echo yes || echo no)" "backend.hcl written into OUTPUT_DIR"
BH=$(cat "$BACKEND" 2>/dev/null || true)
assert_eq "bucket = \"np-services-tfstate\"
prefix = \"cloud-sql-postgresql/$SID/deployment\"" "$BH" "backend.hcl holds exactly the bucket and the per-service prefix"
assert_eq "" "$(get "$ENV_OUT" TOFU_INIT_VARIABLES)" "no flag string is exported"

echo "== TOFU_VARIABLES is a JSON object matching the module's variables =="
TFVARS=$(get "$ENV_OUT" TOFU_VARIABLES)
tv() { printf '%s' "$TFVARS" | jq -r "$1"; }
assert_eq "ok" "$(printf '%s' "$TFVARS" | jq -e . >/dev/null 2>&1 && echo ok || echo bad)" "TOFU_VARIABLES is valid JSON"
assert_eq "conciliation-db-9f8e7d6c" "$(tv '.instance_name')" "tfvars instance_name"
assert_eq "$SID" "$(tv '.service_id')" "tfvars service_id"
assert_eq "np-services-test" "$(tv '.project_id')" "tfvars project_id"
assert_eq "us-east1" "$(tv '.region')" "tfvars region"
assert_eq "projects/np-services-test/global/networks/pg-vpc" "$(tv '.network')" "tfvars network is the self link"
assert_eq "conciliation" "$(tv '.database_name')" "tfvars database_name"
assert_eq "17" "$(tv '.postgres_version')" "postgres_version from parameters"
assert_eq "string" "$(tv '.postgres_version | type')" "postgres_version typed as string"
assert_eq "db-custom-1-3840" "$(tv '.tier')" "tier from parameters"
assert_eq "20" "$(tv '.disk_size_gb')" "disk_size_gb from parameters"
assert_eq "number" "$(tv '.disk_size_gb | type')" "disk_size_gb typed as number"
assert_eq "14" "$(tv '.backup_retention_days')" "parameters override defaults"
assert_eq "number" "$(tv '.backup_retention_days | type')" "backup_retention_days typed as number"
assert_eq "boolean" "$(tv '.high_availability | type')" "high_availability typed as boolean"
assert_eq "object" "$(tv '.labels | type')" "labels typed as object"

echo "== tfvars keys are exactly the module's variables =="
EXPECTED_KEYS="backup_retention_days database_name disk_size_gb high_availability instance_name labels network postgres_version project_id region service_id tier"
assert_eq "$EXPECTED_KEYS" "$(tv 'keys | join(" ")')" "no extra or missing tfvars keys"
MODULE_VARS=$(grep -o '^variable "[a-z_]*"' "$SERVICE_PATH/deployment/variables.tf" | cut -d'"' -f2 | sort | tr '\n' ' ' | sed 's/ $//')
assert_eq "$MODULE_VARS" "$(tv 'keys | sort | join(" ")')" "tfvars keys match deployment/variables.tf"

echo "== defaults apply when neither attributes nor parameters set a value =="
DEFAULTS=$(run_bc "$TMP/values.yaml" "$(ctx create.json '.parameters = {"database_name":"conciliation"}')")
DTV=$(get "$DEFAULTS" TOFU_VARIABLES)
assert_eq "16|db-g1-small|10|7|false" \
  "$(printf '%s' "$DTV" | jq -r '[.postgres_version, .tier, .disk_size_gb, .backup_retention_days, .high_availability] | map(tostring) | join("|")')" \
  "defaults match the spec defaults"

echo "== nothing shells out to a cloud CLI =="
CODE_ONLY=$(grep -v '^[[:space:]]*#' "$BC")
for cli in gcloud gsutil bq; do
  if printf '%s' "$CODE_ONLY" | grep -qw -- "$cli"; then
    echo "  FAIL build_context calls $cli" >&2; FAILURES=$((FAILURES + 1))
  else
    echo "  ok   build_context does not depend on $cli"
  fi
done
assert_eq "np provider list" "$(cut -d' ' -f1-3 "$TMP/np.log" | sort -u | tr '\n' ' ' | sed 's/ $//')" "the only np call is the provider lookup"

echo "== the provider lookup uses the service NRN and the cloud-providers category =="
NP_CALL=$(grep 'provider list' "$TMP/np.log" | tail -1)
assert_contains "$NP_CALL" "--nrn organization=11111111:account=2097086864:namespace=55555555" "looks up the service NRN"
assert_contains "$NP_CALL" "--categories cloud-providers" "asks for cloud-providers"
if [[ "$NP_CALL" == *"--limit"* ]]; then
  echo "  FAIL --limit passed with --categories (np rejects the combination)" >&2; FAILURES=$((FAILURES + 1))
else
  echo "  ok   no --limit alongside --categories"
fi

echo "== attributes are merged with parameters, parameters winning =="
MERGED=$(run_bc "$TMP/values.yaml" "$(ctx create.json '.type = "update"
  | .service.attributes = {"database_name":"conciliation","tier":"db-custom-2-7680","backup_retention_days":35}
  | .parameters = {"tier":"db-g1-small"}')")
MTV=$(get "$MERGED" TOFU_VARIABLES)
assert_eq "db-g1-small" "$(printf '%s' "$MTV" | jq -r '.tier')" "parameter beats stored attribute"
assert_eq "35" "$(printf '%s' "$MTV" | jq -r '.backup_retention_days')" "stored attribute used when no parameter"

echo "== a stored instance_name is stable and wins over a changed .service.name =="
# "name" forces replacement on google_sql_database_instance: recomputing it
# from .service.name on every action would destroy the instance and its data
# the moment someone renames the service instance in nullplatform.
STABLE=$(run_bc "$TMP/values.yaml" "$(ctx create.json '.type = "update"
  | .service.name = "Totally Renamed Service"
  | .service.attributes = {"instance_name":"conciliation-db-9f8e7d6c","database_name":"conciliation"}')")
assert_eq "conciliation-db-9f8e7d6c" "$(get "$STABLE" INSTANCE_NAME)" \
  "stored instance_name wins over a freshly-computed name from the changed service name"

echo "== a corrupted stored instance_name is rejected, not passed to tofu =="
expect_reject "stored instance_name starting with a digit rejected" "$TMP/values.yaml" \
  "$(ctx create.json '.service.attributes = {"instance_name":"9bad-name"}')"
expect_reject "stored instance_name with uppercase rejected" "$TMP/values.yaml" \
  "$(ctx create.json '.service.attributes = {"instance_name":"Bad-Name"}')"
expect_reject "stored instance_name with a trailing hyphen rejected" "$TMP/values.yaml" \
  "$(ctx create.json '.service.attributes = {"instance_name":"bad-name-"}')"

echo "== a service name starting with a digit still yields a name starting with a letter =="
DIGIT=$(run_bc "$TMP/values.yaml" "$(ctx create.json '.service.name = "2024 Ledger"')")
assert_eq "nppg-2024-ledger-9f8e7d6c" "$(get "$DIGIT" INSTANCE_NAME)" "instance name starts with a letter"

echo "== invalid parameters are rejected =="
reject '{"database_name":"Conciliation"}'          "uppercase database_name rejected"
reject '{"database_name":"1db"}'                   "database_name starting with a digit rejected"
reject '{"database_name":"db; drop table x"}'      "database_name with SQL rejected"
reject '{"database_name":"db-name"}'               "database_name with a hyphen rejected"
reject '{"postgres_version":"9.6"}'                "unsupported postgres_version rejected"
reject '{"postgres_version":"14"}'                 "postgres_version 14 rejected (spec offers 15-17)"
reject '{"tier":"Deluxe"}'                         "unknown tier rejected"
reject '{"tier":"db-n1-standard-1"}'               "legacy tier family rejected"
reject '{"tier":"db-custom-1-3840; rm -rf /"}'     "tier with shell metacharacters rejected"
reject '{"disk_size_gb":"; rm -rf /"}'             "non-numeric disk_size_gb rejected"
reject '{"disk_size_gb":5}'                        "disk_size_gb below the Cloud SQL minimum rejected"
reject '{"disk_size_gb":10.5}'                     "fractional disk_size_gb rejected"
reject '{"backup_retention_days":0}'               "backup_retention_days of 0 rejected"
reject '{"backup_retention_days":366}'             "backup_retention_days above 365 rejected"
reject '{"backup_retention_days":"abc"}'           "non-numeric backup_retention_days rejected"
reject '{"high_availability":"maybe"}'             "non-boolean high_availability rejected"

echo "== boundary values are accepted =="
expect_ok "disk_size_gb of 10 accepted" "$TMP/values.yaml" "$(ctx create.json '.parameters.disk_size_gb = 10')"
expect_ok "backup_retention_days of 1 accepted" "$TMP/values.yaml" "$(ctx create.json '.parameters.backup_retention_days = 1')"
expect_ok "backup_retention_days of 365 accepted" "$TMP/values.yaml" "$(ctx create.json '.parameters.backup_retention_days = 365')"
for t in db-f1-micro db-g1-small db-custom-4-16384; do
  expect_ok "tier $t accepted" "$TMP/values.yaml" "$(ctx create.json ".parameters.tier = \"$t\"")"
done

echo "== database_name is required on create and update only =="
reject '{"database_name":""}' "empty database_name rejected on create"
expect_reject "empty database_name rejected on update" "$TMP/values.yaml" \
  "$(ctx create.json '.type = "update" | .parameters = {}')"
expect_ok "empty database_name accepted on delete (a create that never ran)" "$TMP/values.yaml" \
  "$(ctx create.json '.type = "delete" | .parameters = {}')"
expect_ok "empty database_name accepted on read" "$TMP/values.yaml" \
  "$(ctx create.json '.type = "custom" | .slug = "read" | .parameters = {}')"

echo "== project comes from the provider's project.id when values.yaml is empty =="
PROVIDER="$TMP/provider.json"
cat > "$PROVIDER" <<'JSON'
{"results":[{"attributes":{
  "project": {"id": "provider-project"},
  "services": {
    "region": "southamerica-east1",
    "network": "projects/host-project/global/networks/shared-vpc",
    "tfstate": {"bucket": "provider-tfstate"}
  }
}}]}
JSON
FROM_PROVIDER=$(run_bc "$TMP/empty.yaml" "$(ctx create.json)" NP_STUB_PROVIDER_JSON="$PROVIDER")
assert_eq "provider-project" "$(get "$FROM_PROVIDER" PROJECT_ID)" "project.id read from the provider"
assert_eq "southamerica-east1" "$(get "$FROM_PROVIDER" REGION)" "services.region read from the provider"
assert_eq "projects/host-project/global/networks/shared-vpc" "$(get "$FROM_PROVIDER" NETWORK)" "services.network kept as given (a shared VPC in a host project)"
assert_eq "provider-tfstate" "$(get "$FROM_PROVIDER" TFSTATE_BUCKET)" "services.tfstate.bucket read from the provider"
assert_contains "$(cat "$TMP/bc.out")" "project: provider" "logs the provider as the source of the project"

echo "== values.yaml outranks the provider =="
VALUES_WIN=$(run_bc "$TMP/values.yaml" "$(ctx create.json)" NP_STUB_PROVIDER_JSON="$PROVIDER")
assert_eq "np-services-test" "$(get "$VALUES_WIN" PROJECT_ID)" "values project beats provider"
assert_eq "us-east1" "$(get "$VALUES_WIN" REGION)" "values region beats provider"
assert_eq "np-services-tfstate" "$(get "$VALUES_WIN" TFSTATE_BUCKET)" "values bucket beats provider"
assert_contains "$(cat "$TMP/bc.out")" "project: values.yaml" "logs values.yaml as the source"

echo "== a stock provider (project.id only) leaves the rest to the environment =="
STOCK="$TMP/stock-provider.json"
echo '{"results":[{"attributes":{"project":{"id":"stock-project"}}}]}' > "$STOCK"
FROM_ENV=$(run_bc "$TMP/empty.yaml" "$(ctx create.json)" NP_STUB_PROVIDER_JSON="$STOCK" \
  SERVICES_GCP_REGION=us-central1 SERVICES_GCP_NETWORK=env-vpc SERVICES_TFSTATE_BUCKET=env-tfstate)
assert_eq "stock-project" "$(get "$FROM_ENV" PROJECT_ID)" "project from the provider"
assert_eq "us-central1" "$(get "$FROM_ENV" REGION)" "region from SERVICES_GCP_REGION"
assert_eq "projects/stock-project/global/networks/env-vpc" "$(get "$FROM_ENV" NETWORK)" "bare env network lands in the resolved project"
assert_eq "env-tfstate" "$(get "$FROM_ENV" TFSTATE_BUCKET)" "bucket from SERVICES_TFSTATE_BUCKET"

echo "== project falls back to SERVICES_GCP_PROJECT, then GOOGLE_CLOUD_PROJECT =="
P_ENV=$(run_bc "$TMP/bucket-only.yaml" "$(ctx create.json)" SERVICES_GCP_REGION=us-east1 SERVICES_GCP_NETWORK=v \
  SERVICES_GCP_PROJECT=svc-project GOOGLE_CLOUD_PROJECT=gcloud-project)
assert_eq "svc-project" "$(get "$P_ENV" PROJECT_ID)" "SERVICES_GCP_PROJECT beats GOOGLE_CLOUD_PROJECT"
P_GC=$(run_bc "$TMP/bucket-only.yaml" "$(ctx create.json)" SERVICES_GCP_REGION=us-east1 SERVICES_GCP_NETWORK=v \
  GOOGLE_CLOUD_PROJECT=gcloud-project)
assert_eq "gcloud-project" "$(get "$P_GC" PROJECT_ID)" "GOOGLE_CLOUD_PROJECT is the last resort"

echo "== missing project fails with a clear message =="
run_bc "$TMP/bucket-only.yaml" "$(ctx create.json)" SERVICES_GCP_REGION=us-east1 SERVICES_GCP_NETWORK=v >/dev/null && RC=0 || RC=$?
assert_eq "1" "$RC" "build_context fails without a project"
assert_contains "$(cat "$TMP/bc.out")" "project_id is not set" "error names the missing setting"
assert_contains "$(cat "$TMP/bc.out")" "GOOGLE_CLOUD_PROJECT" "error lists where it looked"
expect_reject "invalid project_id rejected" "$TMP/bucket-only.yaml" "$(ctx create.json)" \
  SERVICES_GCP_PROJECT="Bad_Project" SERVICES_GCP_REGION=us-east1 SERVICES_GCP_NETWORK=v

echo "== the tfstate bucket is required on every action, read and delete included =="
for patch in '.' '.type = "delete"' '.type = "custom" | .slug = "read"'; do
  run_bc "$TMP/empty.yaml" "$(ctx create.json "$patch")" SERVICES_GCP_PROJECT=np-services-test \
    SERVICES_GCP_REGION=us-east1 SERVICES_GCP_NETWORK=v >/dev/null && RC=0 || RC=$?
  assert_eq "1" "$RC" "no bucket fails ($patch)"
  assert_contains "$(cat "$TMP/bc.out")" "tfstate_bucket is not set" "error names tfstate_bucket ($patch)"
done
assert_contains "$(cat "$TMP/bc.out")" "EXISTING GCS bucket" "error says the bucket is never created"
expect_reject "invalid tfstate_bucket rejected" "$TMP/empty.yaml" "$(ctx create.json)" \
  SERVICES_GCP_PROJECT=np-services-test SERVICES_GCP_REGION=us-east1 SERVICES_GCP_NETWORK=v \
  SERVICES_TFSTATE_BUCKET="Bad Bucket"

echo "== region and network are required on create and update only =="
NO_RN="$TMP/no-region-network.yaml"
printf 'project_id: "np-services-test"\ntfstate_bucket: "np-services-tfstate"\n' > "$NO_RN"
run_bc "$NO_RN" "$(ctx create.json)" SERVICES_GCP_NETWORK=v >/dev/null && RC=0 || RC=$?
assert_eq "1" "$RC" "create without a region fails"
assert_contains "$(cat "$TMP/bc.out")" "region is not set" "error names region"
run_bc "$NO_RN" "$(ctx create.json)" SERVICES_GCP_REGION=us-east1 >/dev/null && RC=0 || RC=$?
assert_eq "1" "$RC" "create without a network fails"
assert_contains "$(cat "$TMP/bc.out")" "network is not set" "error names network"
expect_reject "update without region or network fails" "$NO_RN" \
  "$(ctx create.json '.type = "update" | .service.attributes = {"database_name":"conciliation"}')"
NO_RN_DEL=$(run_bc "$NO_RN" "$(ctx create.json '.type = "delete"')") && RC=0 || RC=$?
assert_eq "0" "$RC" "delete needs neither region nor network"
assert_eq "" "$(get "$NO_RN_DEL" NETWORK)" "no network on delete stays empty, not a half-built self link"
expect_ok "read needs neither region nor network" "$NO_RN" "$(ctx create.json '.type = "custom" | .slug = "read"')"
expect_ok "a link action needs neither region nor network" "$NO_RN" "$(ctx link.json)"

echo "== delete after a failed create: placeholders keep tofu destroy past the variable validations =="
# The create failed before writing any attribute, and no placement is set:
# tofu destroy evaluates every validation, and "" fails database_name, region
# and network alike.
BARE_DEL=$(run_bc "$NO_RN" "$(ctx create.json '.type = "delete" | .parameters = {} | .service.attributes = {}')") && RC=0 || RC=$?
assert_eq "0" "$RC" "delete with no database_name, region or network succeeds"
BARE_TF=$(get "$BARE_DEL" TOFU_VARIABLES)
VARS_TF="$SERVICE_PATH/deployment/variables.tf"
# module_regex <variable>: the regex in that variable's validation block.
module_regex() {
  sed -n "/variable \"$1\"/,/^}/p" "$VARS_TF" | sed -n 's/.*regex("\(.*\)", var.*/\1/p' | sed 's/\\\\/\\/g' | head -1
}
for v in database_name region network; do
  val=$(printf '%s' "$BARE_TF" | jq -r ".$v")
  assert_eq "yes" "$([ -n "$val" ] && echo yes || echo no)" "tfvars $v is not empty on delete"
  assert_eq "match" "$(printf '%s' "$val" | grep -Eq "$(module_regex "$v")" && echo match || echo "no match: $val")" "tfvars $v passes the module's validation"
done
assert_eq "" "$(get "$BARE_DEL" DATABASE_NAME)" "the exported DATABASE_NAME stays empty: placeholders live in the tfvars only"
assert_eq "" "$(get "$BARE_DEL" REGION)" "the exported REGION stays empty"
STORED_DEL=$(run_bc "$NO_RN" "$(ctx create.json '.type = "delete" | .parameters = {} | .service.attributes = {"database_name":"conciliation"}')" SERVICES_GCP_REGION=us-east1 SERVICES_GCP_NETWORK=v)
assert_eq "conciliation" "$(get "$STORED_DEL" TOFU_VARIABLES | jq -r .database_name)" "a stored database_name wins over the placeholder"
assert_eq "us-east1" "$(get "$STORED_DEL" TOFU_VARIABLES | jq -r .region)" "a configured region wins over the placeholder"
expect_reject "create still refuses an empty database_name" "$TMP/values.yaml" "$(ctx create.json '.parameters = {} | .service.attributes = {}')"

echo "== region and network formats are checked =="
expect_reject "malformed region rejected" "$NO_RN" "$(ctx create.json)" SERVICES_GCP_REGION="US East" SERVICES_GCP_NETWORK=v
expect_reject "zone given as region rejected" "$NO_RN" "$(ctx create.json)" SERVICES_GCP_REGION="us-east1-b" SERVICES_GCP_NETWORK=v
expect_reject "network with an invalid name rejected" "$NO_RN" "$(ctx create.json)" SERVICES_GCP_REGION=us-east1 SERVICES_GCP_NETWORK="Bad_VPC"
expect_reject "network self link of the wrong kind rejected" "$NO_RN" "$(ctx create.json)" \
  SERVICES_GCP_REGION=us-east1 SERVICES_GCP_NETWORK="projects/np-services-test/regions/us-east1/subnetworks/s"

echo "== a full network URL is normalized to the projects/... form =="
URL_NET=$(run_bc "$NO_RN" "$(ctx create.json)" SERVICES_GCP_REGION=us-east1 \
  SERVICES_GCP_NETWORK="https://www.googleapis.com/compute/v1/projects/host-project/global/networks/shared-vpc")
assert_eq "projects/host-project/global/networks/shared-vpc" "$(get "$URL_NET" NETWORK)" "compute API URL normalized"

echo "== labels are sanitized to what GCP accepts =="
LABELS_OUT=$(run_bc "$TMP/values.yaml" "$(ctx create.json '.tags = {
  "Organization": "Implementations Inc",
  "app.name": "Foo/Bar",
  "1starts-with-digit": "x",
  "_underscore": "y",
  "numeric": 42,
  "long": "'"$(printf 'v%.0s' $(seq 1 80))"'"
}')")
LBL=$(printf '%s' "$(get "$LABELS_OUT" TOFU_VARIABLES)" | jq -c '.labels')
assert_eq "implementations_inc" "$(printf '%s' "$LBL" | jq -r '.organization')" "key and value lowercased, space replaced"
assert_eq "foo_bar" "$(printf '%s' "$LBL" | jq -r '.app_name')" "dots and slashes replaced"
assert_eq "42" "$(printf '%s' "$LBL" | jq -r '.numeric')" "a number becomes a string"
assert_eq "string" "$(printf '%s' "$LBL" | jq -r '.numeric | type')" "label values typed as strings"
assert_eq "63" "$(printf '%s' "$LBL" | jq -r '.long | length')" "values capped at 63 characters"
assert_eq "false" "$(printf '%s' "$LBL" | jq -r 'has("1starts-with-digit")')" "a key not starting with a letter is dropped"
assert_eq "false" "$(printf '%s' "$LBL" | jq -r 'has("_underscore")')" "a key starting with an underscore is dropped"
# Kept in a variable: bash 3.2 misparses '$"' inside "$( ... )".
LABEL_RULES='all(to_entries[]; (.key | test("^[a-z][a-z0-9_-]{0,62}$")) and (.value | test("^[a-z0-9_-]{0,63}$")))'
assert_eq "true" "$(printf '%s' "$LBL" | jq -r "$LABEL_RULES")" "every remaining label satisfies the GCP label rules"

echo "== link action derives a stable role name =="
LINK_ENV=$(run_bc "$TMP/values.yaml" "$(ctx link.json)")
assert_eq "eeeeeeee-1111-2222-3333-444444444444" "$(get "$LINK_ENV" LINK_ID)" "LINK_ID parsed"
assert_eq "u_conciliation_api_eeeeeeee" "$(get "$LINK_ENV" LINK_USERNAME)" "username derived from the app slug and the link id"
assert_eq "admin" "$(get "$LINK_ENV" LINK_ACCESS_LEVEL)" "access level from link parameters"
assert_eq "conciliation-db-9f8e7d6c" "$(get "$LINK_ENV" INSTANCE_NAME)" "link reuses the stored instance name"
assert_eq "cloud-sql-postgresql/$SID/deployment" "$(get "$LINK_ENV" TFSTATE_PREFIX)" "link sees the service's deployment prefix"
assert_contains "$(grep 'provider list' "$TMP/np.log" | tail -1)" "--nrn organization=11111111:account=2097086864:namespace=55555555" \
  "link resolves placement from the service NRN"

echo "== a stored username wins over a recomputed one =="
STORED_USER=$(run_bc "$TMP/values.yaml" "$(ctx link.json '.type = "update" | .link.attributes = {"username":"u_legacy_name"} | .link.entity.slug = "renamed-app"')")
assert_eq "u_legacy_name" "$(get "$STORED_USER" LINK_USERNAME)" "stored username is kept: a rename would drop the role"

echo "== a username is derived even without an application slug =="
NO_APP=$(run_bc "$TMP/values.yaml" "$(ctx link.json 'del(.link.entity.slug) | del(.tags.application)')")
assert_eq "u_app_eeeeeeee" "$(get "$NO_APP" LINK_USERNAME)" "falls back to u_app_<link>"

echo "== an invalid access_level or stored username is rejected =="
expect_reject "unknown access_level rejected" "$TMP/values.yaml" "$(ctx link.json '.parameters.access_level = "superuser"')"
expect_reject "stored username with uppercase rejected" "$TMP/values.yaml" "$(ctx link.json '.link.attributes = {"username":"Admin"}')"
for level in read read-write admin; do
  LVL=$(run_bc "$TMP/values.yaml" "$(ctx link.json ".parameters.access_level = \"$level\"")")
  assert_eq "$level" "$(get "$LVL" LINK_ACCESS_LEVEL)" "access_level $level accepted"
done

finish_tests
