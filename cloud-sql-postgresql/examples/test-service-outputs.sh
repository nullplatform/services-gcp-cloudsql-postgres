#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICE_PATH="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/lib/assert.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

CONTEXT_JSON='{"service":{"id":"svc-42"}}'

run_write_outputs() {
  (
    export PATH="$SCRIPT_DIR/stub-bin:$PATH"
    export NP_STUB_LOG="$TMP/np.log"
    export TOFU_STUB_LOG="$TMP/tofu.log"
    export OUTPUT_DIR="$TMP/out"; mkdir -p "$OUTPUT_DIR"
    export CONTEXT="$CONTEXT_JSON"
    export TOFU_STUB_OUTPUT_hostname="${1-}"
    export TOFU_STUB_OUTPUT_port="${2-}"
    export TOFU_STUB_OUTPUT_database_name="${3-}"
    export TOFU_STUB_OUTPUT_instance_name="${4-}"
    export TOFU_STUB_OUTPUT_connection_name="${5-}"
    export TOFU_STUB_OUTPUT_project_id="${6-}"
    # The state carries these too; the step must never forward them.
    export TOFU_STUB_OUTPUT_admin_login="npadmin"
    export TOFU_STUB_OUTPUT_admin_password="SUPERSECRETADMINPASSWORD"
    bash "$SERVICE_PATH/scripts/write_service_outputs" 2>&1
  )
}

echo "== happy path patches every attribute =="
: > "$TMP/np.log"
OUT=$(run_write_outputs "10.20.0.5" "5432" "conciliation" "conciliation-db-9f8e7d6c" "np-services-test:us-east1:conciliation-db-9f8e7d6c" "np-services-test")
NP_CALL=$(grep 'service patch' "$TMP/np.log" | head -1)
assert_contains "$NP_CALL" "--id svc-42" "patches the right service"
BODY=$(printf '%s' "$NP_CALL" | sed 's/.*--body //')
assert_eq "10.20.0.5" "$(printf '%s' "$BODY" | jq -r '.attributes.hostname')" "hostname patched"
assert_eq "5432" "$(printf '%s' "$BODY" | jq -r '.attributes.port')" "port patched"
assert_eq "number" "$(printf '%s' "$BODY" | jq -r '.attributes.port | type')" "port patched as a number, matching the schema"
assert_eq "conciliation" "$(printf '%s' "$BODY" | jq -r '.attributes.database_name')" "database_name patched"
assert_eq "conciliation-db-9f8e7d6c" "$(printf '%s' "$BODY" | jq -r '.attributes.instance_name')" "instance_name patched (build_context reads it back)"
assert_eq "np-services-test:us-east1:conciliation-db-9f8e7d6c" "$(printf '%s' "$BODY" | jq -r '.attributes.connection_name')" "connection_name patched"
assert_eq "np-services-test" "$(printf '%s' "$BODY" | jq -r '.attributes.project_id')" "project_id patched"
assert_eq "connection_name database_name hostname instance_name port project_id" \
  "$(printf '%s' "$BODY" | jq -r '.attributes | keys | join(" ")')" "exactly the six service attributes, nothing else"

echo "== every patched attribute is declared in the service spec =="
SPEC="$SERVICE_PATH/specs/service-spec.json.tpl"
for a in $(printf '%s' "$BODY" | jq -r '.attributes | keys[]'); do
  assert_eq "present" "$(jq -e --arg a "$a" '.attributes.schema.properties[$a]' "$SPEC" >/dev/null 2>&1 && echo present || echo missing)" "$a is in the spec"
done

echo "== the administrator credentials are never patched nor printed =="
for forbidden in admin_login admin_password npadmin SUPERSECRETADMINPASSWORD; do
  if grep -q "$forbidden" "$TMP/np.log" || printf '%s' "$OUT" | grep -q "$forbidden"; then
    echo "  FAIL $forbidden appeared in a service patch or in the log" >&2
    FAILURES=$((FAILURES + 1))
  else
    echo "  ok   $forbidden never patched nor printed"
  fi
done

echo "== no hostname means no patch at all =="
: > "$TMP/np.log"
OUT=$(run_write_outputs "" "" "" "" "" "")
assert_contains "$OUT" "Skipping" "warns and skips"
if grep -q 'service patch' "$TMP/np.log"; then
  echo "  FAIL patched with no outputs available" >&2
  FAILURES=$((FAILURES + 1))
else
  echo "  ok   did not patch when tofu produced no outputs"
fi

echo "== partial outputs: present values are patched, empty ones are not overwritten =="
: > "$TMP/np.log"
OUT=$(run_write_outputs "10.20.0.5" "" "" "conciliation-db-9f8e7d6c" "" "")
NP_CALL=$(grep 'service patch' "$TMP/np.log" | head -1)
BODY=$(printf '%s' "$NP_CALL" | sed 's/.*--body //')
assert_eq "hostname instance_name" "$(printf '%s' "$BODY" | jq -r '.attributes | keys | join(" ")')" \
  "empty outputs are omitted, not sent as empty strings"
assert_contains "$OUT" "database_name" "log names which outputs were empty"

echo "== tofu missing from PATH fails loudly instead of silently skipping =="
NO_TOFU_BIN="$TMP/no-tofu-bin"
mkdir -p "$NO_TOFU_BIN"
cp "$SCRIPT_DIR/stub-bin/np" "$NO_TOFU_BIN/np"
: > "$TMP/np.log"
NOTOFU_OUT=$(
  export PATH="$NO_TOFU_BIN:/usr/bin:/bin"
  export NP_STUB_LOG="$TMP/np.log"
  export OUTPUT_DIR="$TMP/out-notofu"; mkdir -p "$OUTPUT_DIR"
  export CONTEXT="$CONTEXT_JSON"
  bash "$SERVICE_PATH/scripts/write_service_outputs" 2>&1
) && NOTOFU_RC=0 || NOTOFU_RC=$?
assert_eq "1" "$NOTOFU_RC" "exits non-zero when tofu is not on PATH"
assert_contains "$NOTOFU_OUT" "not on PATH" "names the cause instead of warning-and-skipping"
if grep -q 'service patch' "$TMP/np.log"; then
  echo "  FAIL patched the service despite tofu being unavailable" >&2
  FAILURES=$((FAILURES + 1))
else
  echo "  ok   did not patch when tofu was unavailable"
fi

echo "== 'tofu output -json' failing outright also fails loudly =="
: > "$TMP/np.log"
FAILOUT=$(
  export PATH="$SCRIPT_DIR/stub-bin:$PATH"
  export NP_STUB_LOG="$TMP/np.log" TOFU_STUB_LOG="$TMP/tofu.log"
  export TOFU_STUB_FAIL_OUTPUT=true
  export OUTPUT_DIR="$TMP/out-failout"; mkdir -p "$OUTPUT_DIR"
  export CONTEXT="$CONTEXT_JSON"
  bash "$SERVICE_PATH/scripts/write_service_outputs" 2>&1
) && FAILOUT_RC=0 || FAILOUT_RC=$?
assert_eq "1" "$FAILOUT_RC" "exits non-zero when 'tofu output -json' itself fails"
assert_contains "$FAILOUT" "tofu output -json" "names the failing command"

finish_tests
