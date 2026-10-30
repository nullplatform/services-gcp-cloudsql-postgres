#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICE_PATH="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/lib/assert.sh"

SID="9f8e7d6c-1234-4321-abcd-000000000000"
LID="eeeeeeee-1111-2222-3333-444444444444"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Region and network deliberately absent: a link action must not need them.
cat > "$TMP/values.yaml" <<'YAML'
project_id: "np-services-test"
tfstate_bucket: "np-services-tfstate"
YAML

# run_link <jq_patch> — runs build_context then build_permissions_context
# against link.json and echoes the resulting environment. Their own output
# goes to $TMP/bpc.out. The EXIT trap is what still observes the variables
# when build_permissions_context ends the subshell with "exit 0".
run_link() {
  local patch="${1:-.}"
  (
    unset SERVICES_GCP_PROJECT GOOGLE_CLOUD_PROJECT SERVICES_GCP_REGION SERVICES_GCP_NETWORK \
          SERVICES_TFSTATE_BUCKET NP_STUB_PROVIDER_JSON NP_SKIP_TOFU || true
    export PATH="$SCRIPT_DIR/stub-bin:$PATH" NP_STUB_LOG="$TMP/np.log"
    CONTEXT=$(jq -c ".notification | $patch" "$SCRIPT_DIR/link.json"); export CONTEXT
    LINK=$(echo "$CONTEXT" | jq '.link'); export LINK
    export SERVICE_PATH VALUES="$TMP/values.yaml" ACTION_SOURCE=link
    # shellcheck disable=SC2154  # v is the loop variable inside the trap string
    trap 'for v in OUTPUT_DIR TOFU_MODULE_DIR TOFU_INIT_VARIABLES TOFU_VARIABLES NP_SKIP_TOFU; do printf "%s=%s\n" "$v" "${!v:-}"; done' EXIT
    # shellcheck source=/dev/null
    source "$SERVICE_PATH/scripts/build_context" >"$TMP/bpc.out" 2>&1
    # shellcheck source=/dev/null
    source "$SERVICE_PATH/scripts/build_permissions_context" >>"$TMP/bpc.out" 2>&1
  )
}

get() { printf '%s' "$1" | grep "^$2=" | head -1 | cut -d= -f2-; }

echo "== link action =="
ENV_OUT=$(run_link) && RC=0 || RC=$?
assert_eq "0" "$RC" "build_context + build_permissions_context succeed with no region or network configured"
assert_contains "$(get "$ENV_OUT" TOFU_MODULE_DIR)" "/permissions" "module dir points at permissions/"
assert_contains "$(get "$ENV_OUT" OUTPUT_DIR)" "np-link-$LID" "output dir is per link"
assert_eq "" "$(get "$ENV_OUT" NP_SKIP_TOFU)" "NP_SKIP_TOFU is not set on a normal link"
assert_eq "" "$(get "$ENV_OUT" TOFU_INIT_VARIABLES)" "no flag string is exported"

echo "== link state prefix is nested under the service prefix =="
BACKEND="$(get "$ENV_OUT" OUTPUT_DIR)/backend.hcl"
assert_eq "yes" "$([ -f "$BACKEND" ] && echo yes || echo no)" "backend.hcl written into OUTPUT_DIR"
BH=$(cat "$BACKEND" 2>/dev/null || true)
assert_eq "bucket = \"np-services-tfstate\"
prefix = \"cloud-sql-postgresql/$SID/links/$LID\"" "$BH" "reuses the shared bucket under a per-link prefix"
if [[ "$BH" == *"/deployment"* ]]; then
  echo "  FAIL the link's backend points at the deployment state" >&2; FAILURES=$((FAILURES + 1))
else
  echo "  ok   the link's state never shares the deployment prefix"
fi

echo "== tfvars match the permissions module variables exactly =="
TFVARS=$(get "$ENV_OUT" TOFU_VARIABLES)
assert_eq "ok" "$(printf '%s' "$TFVARS" | jq -e . >/dev/null 2>&1 && echo ok || echo bad)" "TOFU_VARIABLES is valid JSON"
EXPECTED_KEYS="access_level deployment_state_prefix link_id tfstate_bucket username"
assert_eq "$EXPECTED_KEYS" "$(printf '%s' "$TFVARS" | jq -r 'keys | join(" ")')" "no extra or missing keys"
MODULE_VARS=$(grep -o '^variable "[a-z_]*"' "$SERVICE_PATH/permissions/variables.tf" | cut -d'"' -f2 | sort | tr '\n' ' ' | sed 's/ $//')
assert_eq "$MODULE_VARS" "$EXPECTED_KEYS" "keys match permissions/variables.tf"
assert_eq "$LID" "$(printf '%s' "$TFVARS" | jq -r '.link_id')" "link id passed through"
assert_eq "u_conciliation_api_eeeeeeee" "$(printf '%s' "$TFVARS" | jq -r '.username')" "role name derived by build_context"
assert_eq "admin" "$(printf '%s' "$TFVARS" | jq -r '.access_level')" "access level from link parameters"
assert_eq "cloud-sql-postgresql/$SID/deployment" "$(printf '%s' "$TFVARS" | jq -r '.deployment_state_prefix')" "points the module at the instance's own state"
assert_eq "np-services-tfstate" "$(printf '%s' "$TFVARS" | jq -r '.tfstate_bucket')" "state bucket passed through"

echo "== access level and a stored username reach the tfvars =="
RW=$(run_link '.type = "update" | .parameters = {"access_level":"read"} | .link.attributes = {"username":"u_legacy_name","access_level":"admin"}')
RWV=$(get "$RW" TOFU_VARIABLES)
assert_eq "read" "$(printf '%s' "$RWV" | jq -r '.access_level')" "a new access_level parameter wins over the stored one"
assert_eq "u_legacy_name" "$(printf '%s' "$RWV" | jq -r '.username')" "the stored username is kept on update"

echo "== no credential or address travels as a variable =="
for forbidden in admin_password admin_login password hostname port database_name; do
  assert_eq "null" "$(printf '%s' "$TFVARS" | jq -r --arg k "$forbidden" '.[$k]')" "$forbidden is not a tfvar"
done

echo "== missing hostname is a clear, actionable error =="
run_link '.service.attributes = {}' >/dev/null && RC=0 || RC=$?
assert_eq "1" "$RC" "link on a service with no hostname fails"
ERR=$(cat "$TMP/bpc.out")
assert_contains "$ERR" "hostname" "error names the missing attribute"
assert_contains "$ERR" "create" "error points at the incomplete create action"

echo "== preconditions exported by build_context are enforced =="
NO_LINK=$(
  export CONTEXT; CONTEXT=$(jq -c '.notification' "$SCRIPT_DIR/link.json")
  export SERVICE_PATH TFSTATE_BUCKET=b TFSTATE_PREFIX=p
  unset LINK_ID || true
  bash "$SERVICE_PATH/scripts/build_permissions_context" 2>&1
) && RC=0 || RC=$?
assert_eq "1" "$RC" "fails without LINK_ID"
assert_contains "$NO_LINK" "LINK_ID" "error names LINK_ID"
NO_BUCKET=$(
  export CONTEXT; CONTEXT=$(jq -c '.notification' "$SCRIPT_DIR/link.json")
  export SERVICE_PATH LINK_ID="$LID"
  unset TFSTATE_BUCKET TFSTATE_PREFIX || true
  bash "$SERVICE_PATH/scripts/build_permissions_context" 2>&1
) && RC=0 || RC=$?
assert_eq "1" "$RC" "fails without the tfstate coordinates"
assert_contains "$NO_BUCKET" "TFSTATE_BUCKET" "error names TFSTATE_BUCKET"
BAD_USER=$(
  export CONTEXT; CONTEXT=$(jq -c '.notification' "$SCRIPT_DIR/link.json")
  export SERVICE_PATH LINK_ID="$LID" TFSTATE_BUCKET=b TFSTATE_PREFIX=p LINK_USERNAME="x; DROP ROLE y"
  bash "$SERVICE_PATH/scripts/build_permissions_context" 2>&1
) && RC=0 || RC=$?
assert_eq "1" "$RC" "fails on an invalid username"
assert_contains "$BAD_USER" "invalid username" "error names the invalid username"
EMPTY_USER=$(
  export CONTEXT; CONTEXT=$(jq -c '.notification' "$SCRIPT_DIR/link.json")
  export SERVICE_PATH LINK_ID="$LID" TFSTATE_BUCKET=b TFSTATE_PREFIX=p
  unset LINK_USERNAME || true
  bash "$SERVICE_PATH/scripts/build_permissions_context" 2>&1
) && RC=0 || RC=$?
assert_eq "1" "$RC" "fails with no username"
assert_contains "$EMPTY_USER" "no username" "error explains the missing username"

echo "== unlink on a service that was never created exits cleanly =="
UNLINK_OUT=$(run_link '.type = "delete" | .parameters = {} | .service.attributes = {} | .link.attributes = {}') && UNLINK_RC=0 || UNLINK_RC=$?
assert_eq "0" "$UNLINK_RC" "unlink with no instance does not fail the workflow"
assert_contains "$(cat "$TMP/bpc.out")" "never fully created" "explains that there is nothing to destroy"
assert_eq "true" "$(get "$UNLINK_OUT" NP_SKIP_TOFU)" \
  "NP_SKIP_TOFU is set so do_tofu and write_link_outputs no-op instead of running tofu destroy"

UNLINK_MODULE_DIR="$(get "$UNLINK_OUT" TOFU_MODULE_DIR)"
case "$UNLINK_MODULE_DIR" in
  */deployment)
    echo "  FAIL TOFU_MODULE_DIR still points at deployment/ (got: '$UNLINK_MODULE_DIR') — the next" >&2
    echo "       step (do_tofu) would see this and could destroy the instance" >&2
    FAILURES=$((FAILURES + 1))
    ;;
  *)
    echo "  ok   TOFU_MODULE_DIR does not point at deployment/ (got: '$UNLINK_MODULE_DIR')"
    ;;
esac

finish_tests
