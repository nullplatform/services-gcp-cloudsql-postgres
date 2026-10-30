#!/bin/bash
# Level 1 test: parses a notification fixture and validates the Terraform
# module, without GCP credentials, an agent, or the nullplatform API.
#
# build_context looks up the cloud-providers provider with "np provider list".
# To stay fully offline, put the test stub first on PATH:
#   PATH="$(pwd)/stub-bin:$PATH" NP_STUB_LOG=/tmp/np.log VALUES=my-values.yaml dry-run.sh
# Placement (project, bucket and, for create/update, region and network) must
# then come from VALUES or from the SERVICES_GCP_* / SERVICES_TFSTATE_BUCKET
# environment variables.
#
# Usage: dry-run.sh [fixture.json]   (defaults to create.json)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICE_PATH="$(dirname "$SCRIPT_DIR")"
CONTEXT_FILE="${1:-$SCRIPT_DIR/create.json}"

if [ ! -f "$CONTEXT_FILE" ]; then
  echo "ERROR: fixture not found: $CONTEXT_FILE" >&2
  exit 1
fi

echo "=== DRY RUN ==="
echo "Fixture: $CONTEXT_FILE"
echo

# Reproduce what the entrypoint sets up.
CONTEXT=$(jq '.notification' "$CONTEXT_FILE")
export CONTEXT
LINK=$(echo "$CONTEXT" | jq '.link')
export LINK
export SERVICE_PATH
export VALUES="${VALUES:-$SERVICE_PATH/values.yaml}"

ACTION_SOURCE="service"
if [ "$(echo "$CONTEXT" | jq '.link != null')" = "true" ]; then
  ACTION_SOURCE="link"
fi
export ACTION_SOURCE

echo "=== 1. Notification ==="
echo "$CONTEXT" | jq '{action_type: .type, action_slug: .slug, service_id: .service.id, service_name: .service.name, action_source: "'"$ACTION_SOURCE"'"}'
echo

echo "=== 2. build_context ==="
# shellcheck source=/dev/null
source "$SERVICE_PATH/scripts/build_context"
echo

if [ "$ACTION_SOURCE" = "link" ]; then
  echo "=== 3. build_permissions_context ==="
  # shellcheck source=/dev/null
  source "$SERVICE_PATH/scripts/build_permissions_context"
  echo
fi

echo "=== 4. Derived variables ==="
printf '  %-28s %s\n' "SERVICE_ID:"      "${SERVICE_ID:-}"
printf '  %-28s %s\n' "INSTANCE_NAME:"   "${INSTANCE_NAME:-}"
printf '  %-28s %s\n' "DATABASE_NAME:"   "${DATABASE_NAME:-}"
printf '  %-28s %s\n' "PROJECT_ID:"      "${PROJECT_ID:-}"
printf '  %-28s %s\n' "REGION:"          "${REGION:-}"
printf '  %-28s %s\n' "NETWORK:"         "${NETWORK:-}"
printf '  %-28s %s\n' "TFSTATE_BUCKET:"  "${TFSTATE_BUCKET:-}"
printf '  %-28s %s\n' "TFSTATE_PREFIX:"  "${TFSTATE_PREFIX:-}"
printf '  %-28s %s\n' "OUTPUT_DIR:"      "${OUTPUT_DIR:-}"
printf '  %-28s %s\n' "TOFU_MODULE_DIR:" "${TOFU_MODULE_DIR:-}"
if [ "$ACTION_SOURCE" = "link" ]; then
  printf '  %-28s %s\n' "LINK_ID:"           "${LINK_ID:-}"
  printf '  %-28s %s\n' "LINK_USERNAME:"     "${LINK_USERNAME:-}"
  printf '  %-28s %s\n' "LINK_ACCESS_LEVEL:" "${LINK_ACCESS_LEVEL:-}"
fi
echo

echo "=== 5. backend.hcl ==="
cat "${OUTPUT_DIR}/backend.hcl" 2>/dev/null; echo

echo "=== 6. terraform.tfvars.json ==="
printf '%s' "$TOFU_VARIABLES" | jq .
echo

echo "=== 7. Terraform validation ==="
# "tofu init -backend=false" downloads the providers on first use; it never
# touches GCP or the state bucket.
if command -v tofu >/dev/null 2>&1; then
  tofu -chdir="$TOFU_MODULE_DIR" init -backend=false -input=false >/dev/null 2>&1 || true
  if tofu -chdir="$TOFU_MODULE_DIR" validate; then
    echo "  validate: OK"
  else
    echo "  validate: FAILED" >&2
    exit 1
  fi
else
  echo "  tofu not installed, skipping"
fi

echo
echo "=== DRY RUN COMPLETE ==="
