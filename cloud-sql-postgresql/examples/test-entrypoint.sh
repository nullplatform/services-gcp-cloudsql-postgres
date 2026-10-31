#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICE_PATH="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/lib/assert.sh"

export PATH="$SCRIPT_DIR/stub-bin:$PATH"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# run_handler <handler> <action_type> <action_slug>
# Runs a handler with a stub np on PATH and echoes the np invocation it made.
run_handler() {
  local handler="$1" action_type="$2" action_slug="$3"
  local log
  log=$(mktemp "$TMP/np.XXXXXX")
  (
    export NP_STUB_LOG="$log"
    export SERVICE_PATH
    export SERVICE_ACTION="$action_slug"
    export SERVICE_ACTION_TYPE="$action_type"
    bash "$SERVICE_PATH/entrypoint/$handler" >/dev/null 2>&1
  ) || true
  grep 'service workflow exec' "$log" 2>/dev/null | head -1
}

echo "== service handler maps action type to workflow =="
assert_contains "$(run_handler service create create-gcp-cloud-sql-postgresql)" \
  "--workflow $SERVICE_PATH/workflows/create.yaml" "create -> create.yaml"
assert_contains "$(run_handler service update update-gcp-cloud-sql-postgresql)" \
  "--workflow $SERVICE_PATH/workflows/update.yaml" "update -> update.yaml"
assert_contains "$(run_handler service delete delete-gcp-cloud-sql-postgresql)" \
  "--workflow $SERVICE_PATH/workflows/delete.yaml" "delete -> delete.yaml"
assert_contains "$(run_handler service custom read)" \
  "--workflow $SERVICE_PATH/workflows/read.yaml" "custom uses the action slug"

echo "== link handler remaps create/update/delete =="
assert_contains "$(run_handler link create create-database-user)" \
  "--workflow $SERVICE_PATH/workflows/link.yaml" "create -> link.yaml"
assert_contains "$(run_handler link update update-database-user)" \
  "--workflow $SERVICE_PATH/workflows/link-update.yaml" "update -> link-update.yaml"
assert_contains "$(run_handler link delete delete-database-user)" \
  "--workflow $SERVICE_PATH/workflows/unlink.yaml" "delete -> unlink.yaml"

echo "== every workflow a handler can dispatch to exists =="
for w in create update delete read link link-update unlink; do
  assert_eq "present" "$([ -f "$SERVICE_PATH/workflows/$w.yaml" ] && echo present || echo absent)" "workflows/$w.yaml"
done

echo "== handlers pass values.yaml =="
assert_contains "$(run_handler service create create-gcp-cloud-sql-postgresql)" \
  "--values $SERVICE_PATH/values.yaml" "values.yaml is passed to the engine"

echo "== entrypoint bridges the API key and builds CONTEXT =="
BRIDGE=$(
  export NP_STUB_LOG="$TMP/bridge.log"
  export NP_API_KEY="key.value"
  unset NULLPLATFORM_API_KEY
  export NP_ACTION_CONTEXT="'"'{"notification":{"slug":"create-gcp-cloud-sql-postgresql","type":"create","action":"service:action:create","link":null,"service":{"id":"svc-1"}}}'"'"
  bash -c '
    source '"$SERVICE_PATH"'/entrypoint/entrypoint >/dev/null 2>&1
    echo "$NULLPLATFORM_API_KEY|$ACTION_SOURCE|$SERVICE_ACTION_TYPE|$SERVICE_ACTION|$SERVICE_PATH|$(echo "$CONTEXT" | jq -r .service.id)"
  '
) || true
assert_eq "key.value|service|create|create-gcp-cloud-sql-postgresql|$SERVICE_PATH|svc-1" "$BRIDGE" \
  "API key bridged, quotes stripped, service action parsed, CONTEXT is the notification"
assert_contains "$(cat "$TMP/bridge.log")" "service-action exec" "hands off to np service-action exec"
assert_contains "$(cat "$TMP/bridge.log")" "--script=$SERVICE_PATH/entrypoint/service" "dispatches to the service handler"

echo "== an existing NULLPLATFORM_API_KEY is not overwritten =="
KEPT=$(
  export NP_STUB_LOG="$TMP/kept.log" NP_API_KEY="agent.key" NULLPLATFORM_API_KEY="explicit.key"
  export NP_ACTION_CONTEXT='{"notification":{"slug":"x","type":"create","link":null,"service":{"id":"svc-1"}}}'
  bash -c 'source '"$SERVICE_PATH"'/entrypoint/entrypoint >/dev/null 2>&1; echo "$NULLPLATFORM_API_KEY"'
) || true
assert_eq "explicit.key" "$KEPT" "explicit key wins"

echo "== entrypoint detects a link action =="
LINKED=$(
  export NP_STUB_LOG="$TMP/linked.log"
  export NP_API_KEY="key.value"
  export NP_ACTION_CONTEXT='{"notification":{"slug":"create-database-user","type":"create","action":"link:action:create","link":{"id":"lnk-1"},"service":{"id":"svc-1"}}}'
  bash -c '
    source '"$SERVICE_PATH"'/entrypoint/entrypoint >/dev/null 2>&1
    echo "$ACTION_SOURCE"
  '
) || true
assert_eq "link" "$LINKED" "ACTION_SOURCE is link when .link is present"
assert_contains "$(cat "$TMP/linked.log")" "--script=$SERVICE_PATH/entrypoint/link" "dispatches to the link handler"

echo "== entrypoint fails fast without a context =="
assert_fails "missing NP_ACTION_CONTEXT exits non-zero" \
  env -u NP_ACTION_CONTEXT bash "$SERVICE_PATH/entrypoint/entrypoint"

finish_tests
