#!/bin/bash
# Smoke test for dry-run.sh, fully offline: np and tofu are the stubs.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/assert.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/values.yaml" <<'YAML'
project_id: "np-services-test"
region: "us-east1"
network: "pg-vpc"
tfstate_bucket: "np-services-tfstate"
YAML

run_dry() {
  (
    unset SERVICES_GCP_PROJECT GOOGLE_CLOUD_PROJECT SERVICES_GCP_REGION SERVICES_GCP_NETWORK \
          SERVICES_TFSTATE_BUCKET NP_STUB_PROVIDER_JSON || true
    export PATH="$SCRIPT_DIR/stub-bin:$PATH" NP_STUB_LOG="$TMP/np.log" TOFU_STUB_LOG="$TMP/tofu.log"
    export VALUES="$TMP/values.yaml"
    bash "$SCRIPT_DIR/dry-run.sh" "$1" 2>&1
  )
}

for fixture in create.json link.json; do
  echo "== dry-run.sh $fixture =="
  OUT=$(run_dry "$SCRIPT_DIR/$fixture") && RC=0 || RC=$?
  assert_eq "0" "$RC" "$fixture: completes"
  assert_contains "$OUT" "DRY RUN COMPLETE" "$fixture: reaches the end"
  assert_contains "$OUT" "INSTANCE_NAME:" "$fixture: prints the instance name"
  assert_contains "$OUT" 'bucket = "np-services-tfstate"' "$fixture: prints backend.hcl"
done
assert_contains "$OUT" "LINK_USERNAME:" "link.json: prints the link variables"
assert_contains "$OUT" "/links/" "link.json: uses the per-link state prefix"

echo "== a missing fixture is a clear error =="
OUT=$(run_dry "$TMP/nope.json") && RC=0 || RC=$?
assert_eq "1" "$RC" "fails on a missing fixture"
assert_contains "$OUT" "fixture not found" "names the problem"

finish_tests
