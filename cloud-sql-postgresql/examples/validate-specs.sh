#!/bin/bash
# Validates the service and link specs against the nullplatform skills checklist,
# and against what the scripts actually accept and write.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICE_PATH="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/lib/assert.sh"

SERVICE_SPEC="$SERVICE_PATH/specs/service-spec.json.tpl"
LINK_SPEC="$SERVICE_PATH/specs/links/database-user.json.tpl"

# p <attribute> <jq_filter> — queries one service attribute's schema.
p()  { jq -r --arg a "$1" ".attributes.schema.properties[\$a] | $2" "$SERVICE_SPEC" 2>/dev/null; }
lp() { jq -r --arg a "$1" ".attributes.schema.properties[\$a] | $2" "$LINK_SPEC" 2>/dev/null; }

echo "== spec files exist and are valid JSON =="
for f in "$SERVICE_SPEC" "$LINK_SPEC"; do
  if [ -f "$f" ]; then
    assert_eq "ok" "$(jq -e . "$f" >/dev/null 2>&1 && echo ok || echo bad)" "valid JSON: $(basename "$f")"
  else
    assert_eq "present" "missing" "file exists: $f"
  fi
done
assert_eq "database-user.json.tpl" "$(ls "$SERVICE_PATH/specs/links/")" "the only link spec is database-user"

echo "== schema lives in attributes.schema =="
assert_eq "object" "$(jq -r '.attributes.schema.type // "MISSING"' "$SERVICE_SPEC" 2>/dev/null)" "service schema type"
assert_eq "object" "$(jq -r '.attributes.schema.type // "MISSING"' "$LINK_SPEC" 2>/dev/null)" "link schema type"

echo "== specification_schema is absent =="
assert_eq "absent" "$(jq -e 'has("specification_schema")' "$SERVICE_SPEC" >/dev/null 2>&1 && echo present || echo absent)" "service has no specification_schema"
assert_eq "absent" "$(jq -e 'has("specification_schema")' "$LINK_SPEC" >/dev/null 2>&1 && echo present || echo absent)" "link has no specification_schema"

echo "== identity and selectors =="
assert_eq "gcp-cloud-sql-postgresql" "$(jq -r '.slug' "$SERVICE_SPEC" 2>/dev/null)" "service slug"
assert_eq "dependency" "$(jq -r '.type' "$SERVICE_SPEC" 2>/dev/null)" "service type"
assert_eq "GCP" "$(jq -r '.selectors.provider' "$SERVICE_SPEC" 2>/dev/null)" "service provider selector"
assert_eq "Database" "$(jq -r '.selectors.category' "$SERVICE_SPEC" 2>/dev/null)" "service category selector"
assert_eq "database-user" "$(jq -r '.available_links | join(",")' "$SERVICE_SPEC" 2>/dev/null)" "service declares the database-user link"
assert_eq "database-user" "$(jq -r '.slug' "$LINK_SPEC" 2>/dev/null)" "link slug"
assert_eq "GCP" "$(jq -r '.selectors.provider' "$LINK_SPEC" 2>/dev/null)" "link provider selector"

echo "== service attributes are exactly the expected set =="
assert_eq "backup_retention_days connection_name database_name disk_size_gb high_availability hostname instance_name port postgres_version project_id tier" \
  "$(jq -r '.attributes.schema.properties | keys | join(" ")' "$SERVICE_SPEC" 2>/dev/null)" "service attribute set"

echo "== the service required array is exactly the one input with no safe default =="
assert_eq "database_name" "$(jq -r '.attributes.schema.required | join(",")' "$SERVICE_SPEC" 2>/dev/null)" "service required array"

echo "== immutable inputs are editable on create only =="
for a in database_name postgres_version; do
  assert_eq "create" "$(p "$a" '.editableOn | join(",")')" "$a editable on create only"
done
for a in tier disk_size_gb backup_retention_days high_availability; do
  assert_eq "create,update" "$(p "$a" '.editableOn | join(",")')" "$a editable on create and update"
done

echo "== input constraints match what build_context accepts =="
assert_eq "15,16,17" "$(p postgres_version '.enum | join(",")')" "postgres_version enum"
assert_eq "16" "$(p postgres_version '.default')" "postgres_version default"
assert_eq "string" "$(p postgres_version '.type')" "postgres_version is a string"
assert_eq "^[a-z][a-z0-9_]{0,62}$" "$(p database_name '.pattern')" "database_name pattern"
assert_eq "db-g1-small" "$(p tier '.default')" "tier default"
TIER_RE=$(grep -o '"\$TIER" =~ [^ ]*' "$SERVICE_PATH/scripts/build_context" | sed 's/^"\$TIER" =~ //')
# An empty pattern would match every tier and make the loop below vacuous.
assert_contains "$TIER_RE" "^db-" "tier pattern extracted from build_context"
for t in $(p tier '.enum[]'); do
  if [[ "$t" =~ $TIER_RE ]]; then
    echo "  ok   tier $t is accepted by build_context"
  else
    echo "  FAIL tier $t is offered by the spec but rejected by build_context ($TIER_RE)" >&2
    FAILURES=$((FAILURES + 1))
  fi
done
assert_eq "10|10" "$(p disk_size_gb '"\(.minimum)|\(.default)"')" "disk_size_gb minimum and default are the Cloud SQL minimum"
assert_eq "1|365|7" "$(p backup_retention_days '"\(.minimum)|\(.maximum)|\(.default)"')" "backup_retention_days range and default"
assert_eq "boolean|false" "$(p high_availability '"\(.type)|\(.default)"')" "high_availability defaults to off"

echo "== output attributes are not editable =="
for a in hostname port instance_name connection_name project_id; do
  assert_eq "0" "$(p "$a" '.editableOn | length')" "$a editableOn is empty"
done

echo "== exported service attributes =="
for a in hostname port database_name; do
  assert_eq "true" "$(p "$a" '.export')" "$a exported"
done
for a in instance_name connection_name project_id; do
  assert_eq "false" "$(p "$a" '.export')" "$a not exported"
done
assert_eq "number" "$(p port '.type')" "port is a number, as write_service_outputs patches it"

echo "== every attribute write_service_outputs patches is declared =="
while read -r a; do
  assert_eq "present" "$(jq -e --arg a "$a" '.attributes.schema.properties[$a]' "$SERVICE_SPEC" >/dev/null 2>&1 && echo present || echo missing)" "$a declared in the spec"
done < <(grep -o '\-\-arg [a-z_]*' "$SERVICE_PATH/scripts/write_service_outputs" | awk '{print $2}' | sort -u)

echo "== the administrator credentials never appear in the schema =="
for a in admin_login admin_password administrator_password administrator_login password; do
  assert_eq "null" "$(p "$a" '.')" "$a absent from the service schema"
done

echo "== network exposure and TLS are not user-editable =="
for a in ssl_mode ipv4_enabled public_ip authorized_networks network region project; do
  assert_eq "null" "$(p "$a" '.')" "$a absent from the schema"
done

echo "== the uiSchema only references declared attributes =="
for scope in $(jq -r '.. | objects | select(has("scope")) | .scope' "$SERVICE_SPEC"); do
  a="${scope##*/}"
  assert_eq "present" "$(jq -e --arg a "$a" '.attributes.schema.properties[$a]' "$SERVICE_SPEC" >/dev/null 2>&1 && echo present || echo missing)" "uiSchema control $a is declared"
done

echo "== link attributes =="
assert_eq "access_level jdbc_url password username" "$(jq -r '.attributes.schema.properties | keys | join(" ")' "$LINK_SPEC" 2>/dev/null)" "link attribute set"
assert_eq "admin" "$(lp access_level '.default')" "access_level default"
assert_eq "read,read-write,admin" "$(lp access_level '.enum | join(",")')" "access_level enum"
assert_eq "create,update" "$(lp access_level '.editableOn | join(",")')" "access_level editable on create and update"
assert_eq "" "$(jq -r '.attributes.schema.required | join(",")' "$LINK_SPEC" 2>/dev/null)" "no required link input: access_level has a default"
for level in $(lp access_level '.enum[]'); do
  assert_contains "$(cat "$SERVICE_PATH/permissions/locals.tf")" "\"$level\" = {" "access level $level has grants in the permissions module"
done

echo "== link outputs land on the fixed DATABASE_* names the consuming apps read =="
assert_eq "DATABASE_USER"     "$(lp username '.export.target')" "username -> DATABASE_USER"
assert_eq "DATABASE_PASSWORD" "$(lp password '.export.target')" "password -> DATABASE_PASSWORD"
assert_eq "DATABASE_URL"      "$(lp jdbc_url '.export.target')" "jdbc_url -> DATABASE_URL"
for a in username password jdbc_url; do
  assert_eq "environment_variable" "$(lp "$a" '.export.type')" "$a exported as an environment variable"
  assert_eq "0" "$(lp "$a" '.editableOn | length')" "$a is not editable"
done
assert_eq "true"  "$(lp password '.export.secret')" "password exported as secret"
assert_eq "false" "$(lp username '.export.secret')" "username is not a secret"
assert_eq "false" "$(lp jdbc_url '.export.secret')" "jdbc_url is not a secret"

echo "== the link must not re-export service attributes =="
for a in hostname port database_name; do
  assert_eq "null" "$(lp "$a" '.')" "link does not redeclare $a"
done

finish_tests
