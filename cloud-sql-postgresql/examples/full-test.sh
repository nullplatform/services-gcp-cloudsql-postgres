#!/bin/bash
# Level 2 test: runs build_context and do_tofu against a REAL GCP project,
# without an agent or the nullplatform API.
#
# This CREATES REAL GCP RESOURCES and costs money. It requires Application
# Default Credentials ("gcloud auth application-default login" or
# GOOGLE_APPLICATION_CREDENTIALS) and a values.yaml with real placement: a
# project, an EXISTING tfstate bucket, a region and a VPC with Private
# Service Access configured. A link run must also reach the instance's
# private IP from this machine (a VPN or a bastion into that VPC).
#
# Usage: full-test.sh [fixture.json] [apply|destroy]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICE_PATH="$(dirname "$SCRIPT_DIR")"
CONTEXT_FILE="${1:-$SCRIPT_DIR/create.json}"
ACTION="${2:-apply}"

if [[ ! "$ACTION" =~ ^(apply|destroy)$ ]]; then
  echo "ERROR: action must be apply or destroy, got '$ACTION'" >&2
  exit 1
fi

if [ ! -f "$CONTEXT_FILE" ]; then
  echo "ERROR: fixture not found: $CONTEXT_FILE" >&2
  exit 1
fi

if ! command -v gcloud >/dev/null 2>&1; then
  echo "ERROR: the gcloud CLI is required to check the credentials for a full test." >&2
  exit 1
fi

if ! gcloud auth application-default print-access-token >/dev/null 2>&1; then
  echo "ERROR: no Application Default Credentials. Run:" >&2
  echo "  gcloud auth application-default login" >&2
  exit 1
fi

echo "=== FULL TEST (creates real GCP resources) ==="
echo "Fixture: $CONTEXT_FILE"
echo "Action:  $ACTION"
echo

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

# No credential step: the google provider and the gcs backend pick up
# Application Default Credentials on their own, as the worker pod does
# through Workload Identity.

echo "=== 1. build_context ==="
# shellcheck source=/dev/null
source "$SERVICE_PATH/scripts/build_context"
echo

if [ "$ACTION_SOURCE" = "link" ]; then
  echo "=== 2. build_permissions_context ==="
  # shellcheck source=/dev/null
  source "$SERVICE_PATH/scripts/build_permissions_context"
  echo
fi

read -r -p "This will $ACTION real resources in project ${PROJECT_ID}. Continue? [y/N] " reply
if [ "$reply" != "y" ] && [ "$reply" != "Y" ]; then
  echo "Aborted."
  exit 0
fi

echo "=== 3. do_tofu ($ACTION) ==="
export TOFU_ACTION="$ACTION"

# do_tofu runs as a SUBPROCESS here, not sourced, for two reasons.
#
# 1. Failure handling. Sourcing it means a failing `tofu apply` trips this
#    script's own `set -e` and kills the process at that line — so the cleanup
#    guidance below never prints, in exactly the situation where the operator
#    most needs it: a partial apply that may have left real GCP resources
#    behind. And `source X || rc=$?` does NOT rescue that: the `||` never gets
#    to run, because the failure is raised inside the sourced script and exits
#    the current shell first.
# 2. Fidelity. The nullplatform agent runs each workflow step as its own
#    process, so a subprocess is what production actually does.
TOFU_RC=0
bash "$SERVICE_PATH/scripts/do_tofu" || TOFU_RC=$?

if [ "$TOFU_RC" -ne 0 ]; then
  echo
  echo "!!! tofu ${ACTION} FAILED (exit ${TOFU_RC})."
  echo "    GCP resources may have been PARTIALLY created."
  echo "    Terraform state is in: gs://${TFSTATE_BUCKET}/ (working dir ${OUTPUT_DIR})"
  echo "    Clean up with:"
  echo "      bash $0 $CONTEXT_FILE destroy"
  exit "$TOFU_RC"
fi
echo

if [ "$ACTION" = "apply" ]; then
  echo "=== 4. Terraform outputs ==="
  (cd "$OUTPUT_DIR" && tofu output)
  echo
  echo "Note: outputs were NOT written to nullplatform — write_service_outputs"
  echo "and write_link_outputs need a real service or link ID."
  echo
  echo "Clean up with:"
  echo "  bash $0 $CONTEXT_FILE destroy"
fi

echo "=== FULL TEST COMPLETE ==="
