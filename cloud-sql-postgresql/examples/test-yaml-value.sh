#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICE_PATH="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/lib/assert.sh"

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# yaml_value() is duplicated in every script that reads $VALUES — shell
# functions do not survive across workflow steps. Find every copy and run the
# same cases against all of them, so the copies cannot drift.
SCRIPTS=$(grep -l '^yaml_value() {' "$SERVICE_PATH"/scripts/* | xargs -n1 basename | sort)
assert_contains " $(echo "$SCRIPTS" | tr '\n' ' ')" " build_context " "build_context carries a yaml_value"

# Any script that reads $VALUES must carry its own copy.
for f in "$SERVICE_PATH"/scripts/*; do
  s=$(basename "$f")
  if grep -v '^[[:space:]]*#' "$f" | grep -q 'yaml_value .*"\$VALUES"'; then
    assert_contains " $(echo "$SCRIPTS" | tr '\n' ' ')" " $s " "$s reads \$VALUES and defines yaml_value"
  fi
done

cat > "$TMP/values.yaml" <<'EOF'
quoted_empty_with_comment: ""   # empty = from the provider
quoted_value_with_comment: "np-services-test"   # a trailing note
bare_value_with_comment: us-east1   # a trailing note
bare_value: pg-vpc
quoted_empty: ""
quoted_with_spaces: "two words"
single_quoted: 'np-services-tfstate'   # note
self_link: "projects/p-1/global/networks/v"
EOF

for s in $SCRIPTS; do
  echo "== yaml_value in $s =="
  awk '/^yaml_value\(\) \{/,/^\}/' "$SERVICE_PATH/scripts/$s" > "$TMP/fn.sh"
  assert_eq "yes" "$([ -s "$TMP/fn.sh" ] && echo yes || echo no)" "$s: yaml_value found"
  # shellcheck source=/dev/null
  source "$TMP/fn.sh"

  # The regression: an inline comment after a quoted empty value must not
  # become the value. It used to return '"   # empty = ...', which outranked
  # every other resolution tier and landed in backend.hcl.
  assert_eq "FALLBACK" "$(yaml_value quoted_empty_with_comment FALLBACK "$TMP/values.yaml")" \
    "$s: quoted empty + inline comment falls back to the default"

  assert_eq "np-services-test"    "$(yaml_value quoted_value_with_comment X "$TMP/values.yaml")" "$s: quoted value drops the comment"
  assert_eq "us-east1"            "$(yaml_value bare_value_with_comment X "$TMP/values.yaml")"   "$s: bare value drops the comment"
  assert_eq "pg-vpc"              "$(yaml_value bare_value X "$TMP/values.yaml")"                "$s: bare value"
  assert_eq "FALLBACK"            "$(yaml_value quoted_empty FALLBACK "$TMP/values.yaml")"       "$s: quoted empty is empty"
  assert_eq "two words"           "$(yaml_value quoted_with_spaces X "$TMP/values.yaml")"        "$s: spaces inside quotes survive"
  assert_eq "np-services-tfstate" "$(yaml_value single_quoted X "$TMP/values.yaml")"             "$s: single quotes are stripped"
  assert_eq "projects/p-1/global/networks/v" "$(yaml_value self_link X "$TMP/values.yaml")"      "$s: slashes survive"
  assert_eq "FALLBACK"            "$(yaml_value absent_key FALLBACK "$TMP/values.yaml")"         "$s: missing key uses the default"
  assert_eq "FALLBACK"            "$(yaml_value bare FALLBACK "$TMP/values.yaml")"               "$s: a key prefix does not match a longer key"
  assert_eq "FALLBACK"            "$(yaml_value any_key FALLBACK /nonexistent/file.yaml)"        "$s: missing file uses the default"
done

echo "== the shipped values.yaml parses to all-empty (it is a template) =="
awk '/^yaml_value\(\) \{/,/^\}/' "$SERVICE_PATH/scripts/build_context" > "$TMP/fn.sh"
# shellcheck source=/dev/null
source "$TMP/fn.sh"
KEYS_READ=$(grep -o 'yaml_value "[a-z_]*"' "$SERVICE_PATH/scripts/build_context" | cut -d'"' -f2 | sort -u)
assert_eq "network project_id region tfstate_bucket" "$(echo "$KEYS_READ" | tr '\n' ' ' | sed 's/ $//')" "build_context reads exactly the placement keys"
for k in $KEYS_READ; do
  assert_eq "present" "$(grep -q "^$k:" "$SERVICE_PATH/values.yaml" && echo present || echo missing)" "shipped values.yaml documents $k"
  assert_eq "EMPTY" "$(yaml_value "$k" EMPTY "$SERVICE_PATH/values.yaml")" "shipped values.yaml: $k is empty"
done

finish_tests
