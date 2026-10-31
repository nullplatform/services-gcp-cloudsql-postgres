#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICE_PATH="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/lib/assert.sh"
source "$SCRIPT_DIR/lib/yaml.sh"

WF="$SERVICE_PATH/workflows"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

echo "== every workflow the handlers can dispatch to exists =="
for w in create update delete read link link-update unlink; do
  assert_eq "present" "$([ -f "$WF/$w.yaml" ] && echo present || echo absent)" "$w.yaml exists"
done

echo "== every workflow is valid YAML =="
for f in "$WF"/*.yaml; do
  w=$(basename "$f" .yaml)
  if yaml_json "$f" > "$TMP/$w.json" 2>/dev/null && jq -e 'type == "object"' "$TMP/$w.json" >/dev/null 2>&1; then
    echo "  ok   valid YAML: $w.yaml"
  else
    echo "  FAIL invalid YAML: $w.yaml" >&2
    FAILURES=$((FAILURES + 1))
    echo '{}' > "$TMP/$w.json"
  fi
done

# wf <workflow> <jq_filter> — queries a workflow parsed above.
wf() { jq -r "$2" "$TMP/$1.json"; }

steps_of()       { wf "$1" '[.steps[].name] | join("|")'; }
tofu_action_of() { wf "$1" '[.steps[] | select(.name == "tofu")][0].configuration.TOFU_ACTION'; }
# outputs_of <workflow> <step_name> — the step's declared output names.
outputs_of()     { jq -r --arg s "$2" '[.steps[] | select(.name == $s) | .output[]?.name] | join(" ")' "$TMP/$1.json"; }

echo "== every referenced script exists and is executable =="
MISSING=""
for f in "$WF"/*.yaml; do
  w=$(basename "$f" .yaml)
  for script in $(wf "$w" '.steps[]? | .file // empty'); do
    resolved="${script/\$SERVICE_PATH/$SERVICE_PATH}"
    [ -x "$resolved" ] || MISSING="$MISSING $w:$script"
  done
  for inc in $(wf "$w" '.include[]? // empty'); do
    resolved="${inc/\$SERVICE_PATH/$SERVICE_PATH}"
    [ -f "$resolved" ] || MISSING="$MISSING $w:$inc"
  done
done
assert_eq "" "$MISSING" "all referenced step scripts and includes exist"

echo "== every step script lives under scripts/ =="
OUTSIDE=$(cat "$TMP"/*.json | jq -r '.steps[]? | .file // empty' | grep -v '^\$SERVICE_PATH/scripts/' || true)
assert_eq "" "$OUTSIDE" "no step points outside scripts/"

echo "== create and update build context, apply, write outputs =="
for w in create update; do
  assert_eq "build context|tofu|write service outputs" "$(steps_of "$w")" "$w step order"
  assert_eq "apply" "$(tofu_action_of "$w")" "$w uses TOFU_ACTION=apply"
done

echo "== delete destroys =="
assert_eq "build context|tofu" "$(steps_of delete)" "delete step order"
assert_eq "destroy" "$(tofu_action_of delete)" "delete uses TOFU_ACTION=destroy"

echo "== link builds the permissions context before applying =="
assert_eq "build context|build permissions context|tofu|write link outputs" "$(steps_of link)" "link step order"
assert_eq "apply" "$(tofu_action_of link)" "link applies"

echo "== there is no credential step: identity comes from Workload Identity / ADC =="
for w in create update delete read link link-update unlink; do
  assert_eq "" "$(wf "$w" '[.steps[]?.name | select(test("credential"; "i"))] | join(",")')" "$w has no credential step"
done
CRED_OUTS=$(cat "$TMP"/*.json | jq -r '.steps[]? | .output[]?.name' | grep -E 'CREDENTIAL|SECRET|PASSWORD|TOKEN|KEY' || true)
assert_eq "" "$CRED_OUTS" "no workflow passes a credential between steps"

echo "== workflows that run tofu ask for the cloud-providers provider =="
for w in create update delete link; do
  assert_contains "$(wf "$w" '.provider_categories // [] | join(",")')" "cloud-providers" "$w declares cloud-providers"
done

echo "== link-update and unlink reuse link.yaml through include =="
for w in link-update unlink; do
  assert_contains "$(wf "$w" '.include // [] | join(",")')" "workflows/link.yaml" "$w includes link.yaml"
  assert_eq "replace" "$(wf "$w" '[.steps[]?.action] | unique | join(",")')" "$w replaces a step rather than redefining the workflow"
  assert_eq "tofu" "$(wf "$w" '[.steps[]?.name] | join(",")')" "$w only replaces the tofu step"
done
assert_eq "destroy" "$(tofu_action_of unlink)" "unlink destroys the link's module"
assert_eq "apply" "$(tofu_action_of link-update)" "link-update applies"

echo "== read.yaml must not run tofu: a read may not touch GCP =="
assert_eq "false" "$(wf read '[.steps[] | .file // "" | test("do_tofu")] | any')" "read.yaml invokes no tofu step"
assert_eq "build context|read current state" "$(steps_of read)" "read.yaml step order"
READ_SCRIPT=$(wf read '[.steps[] | select(.name == "read current state")][0].script // ""')
READ_OUTS=$(outputs_of read "build context")
for v in $(printf '%s' "$READ_SCRIPT" | grep -oE '\$\{[A-Z_]+:-' | tr -d '${:-' | sort -u); do
  assert_contains " $READ_OUTS " " $v " "read declares $v, which the read step uses"
done

echo "== build_context declares the variables do_tofu needs =="
for w in create update delete link; do
  OUTS=$(outputs_of "$w" "build context")
  for v in OUTPUT_DIR TOFU_MODULE_DIR TOFU_INIT_VARIABLES TOFU_VARIABLES; do
    assert_contains " $OUTS " " $v " "$w declares $v"
  done
done

echo "== every variable build_context exports is declared on a workflow that runs it =="
EXPORTED=$(grep -E '^[[:space:]]*export [A-Z]' "$SERVICE_PATH/scripts/build_context" | sed 's/^[[:space:]]*export //' | tr ' ' '\n' | grep -E '^[A-Z_]+$' | sort -u)
LINK_OUTS=$(outputs_of link "build context")
for v in $EXPORTED; do
  case "$v" in
    # Recomputed by build_context on every step that needs them.
    SERVICE_ID|SERVICE_NAME|NETWORK) continue ;;
  esac
  assert_contains " $LINK_OUTS " " $v " "link declares $v"
done

echo "== link declares everything build_permissions_context needs =="
for v in LINK_ID LINK_USERNAME LINK_ACCESS_LEVEL TFSTATE_BUCKET TFSTATE_PREFIX; do
  assert_contains " $LINK_OUTS " " $v " "link declares $v"
done
PERM_NEEDS=$(grep -oE '\$\{?[A-Z_]+' "$SERVICE_PATH/scripts/build_permissions_context" | tr -d '${' | sort -u)
for v in $PERM_NEEDS; do
  case "$v" in
    # Set by the entrypoint, or by build_permissions_context itself.
    CONTEXT|SERVICE_PATH|ACTION_TYPE|SERVICE_ID|SERVICE_ATTRS|TARGET_HOSTNAME|USERNAME|OUTPUT_DIR|TOFU_MODULE_DIR|TOFU_INIT_VARIABLES|TOFU_VARIABLES|NP_SKIP_TOFU) continue ;;
  esac
  assert_contains " $LINK_OUTS " " $v " "link declares $v, read by build_permissions_context"
done

echo "== the permissions step overrides everything do_tofu reads =="
PERM_OUTS=$(outputs_of link "build permissions context")
for v in OUTPUT_DIR TOFU_MODULE_DIR TOFU_INIT_VARIABLES TOFU_VARIABLES NP_SKIP_TOFU; do
  assert_contains " $PERM_OUTS " " $v " "build permissions context declares $v"
done

finish_tests
