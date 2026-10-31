#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICE_PATH="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/lib/assert.sh"
source "$SCRIPT_DIR/lib/tofu-module.sh"

MODULE="$SERVICE_PATH/permissions"

echo "== variables match what build_permissions_context emits =="
VARS=$(grep -o '^variable "[a-z_]*"' "$MODULE/variables.tf" | cut -d'"' -f2 | sort | tr '\n' ' ' | sed 's/ $//')
assert_eq "access_level deployment_state_prefix link_id tfstate_bucket username" "$VARS" "exactly the expected variables"

echo "== every variable is validated =="
for v in link_id username access_level tfstate_bucket deployment_state_prefix; do
  BLOCK=$(sed -n "/variable \"$v\"/,/^}/p" "$MODULE/variables.tf" 2>/dev/null)
  assert_contains "$BLOCK" "validation {" "variable $v carries a validation block"
done
PREFIX_BLOCK=$(sed -n '/variable "deployment_state_prefix"/,/^}/p' "$MODULE/variables.tf")
assert_contains "$PREFIX_BLOCK" '"/deployment"' "the remote state must be a deployment prefix, never a link's"

echo "== the instance coordinates and credentials come from the deployment state, not from variables =="
MAIN=$(sed 's/#.*//' "$MODULE/main.tf")
RS=$(sed -n '/data "terraform_remote_state" "deployment"/,/^}/p' "$MODULE/main.tf")
assert_contains "$RS" 'backend = "gcs"' "reads the deployment state from GCS"
assert_contains "$RS" 'bucket = var.tfstate_bucket' "from the shared bucket"
assert_contains "$RS" 'prefix = var.deployment_state_prefix' "at the service's deployment prefix"
assert_eq "absent" "$(grep -q 'variable "admin_password"\|variable "password"\|variable "hostname"' "$MODULE/variables.tf" 2>/dev/null && echo present || echo absent)" "no credential or hostname passed in as a variable"

echo "== the access level matrix covers all three levels =="
for level in '"read"' '"read-write"' '"admin"'; do
  assert_eq "present" "$(grep -q "$level" "$MODULE/locals.tf" 2>/dev/null && echo present || echo absent)" "locals map has $level"
done

echo "== read must not grant writes or CREATE =="
READ_BLOCK=$(sed -n '/"read" *= *{/,/^    }/p' "$MODULE/locals.tf" 2>/dev/null | tr -s ' ')
assert_contains "$READ_BLOCK" 'table = ["SELECT"]' "read grants SELECT only on tables"
assert_contains "$READ_BLOCK" 'database = ["CONNECT"]' "read grants CONNECT only on the database"
if printf '%s' "$READ_BLOCK" | grep -q 'CREATE\|INSERT\|UPDATE\|DELETE\|ALL'; then
  echo "  FAIL read grants a write or CREATE privilege" >&2
  FAILURES=$((FAILURES + 1))
else
  echo "  ok   read grants no write or CREATE privilege"
fi

echo "== read-write changes rows but never the schema =="
RW_BLOCK=$(sed -n '/"read-write" *= *{/,/^    }/p' "$MODULE/locals.tf" 2>/dev/null | tr -s ' ')
assert_contains "$RW_BLOCK" '"INSERT", "UPDATE", "DELETE"' "read-write grants DML"
if printf '%s' "$RW_BLOCK" | grep -q 'CREATE\|ALL'; then
  echo "  FAIL read-write grants CREATE or ALL" >&2
  FAILURES=$((FAILURES + 1))
else
  echo "  ok   read-write grants no CREATE or ALL"
fi

echo "== admin can create schemas and tables (what a migration tool needs) =="
ADMIN_BLOCK=$(sed -n '/"admin" *= *{/,/^    }/p' "$MODULE/locals.tf" 2>/dev/null | tr -s ' ')
assert_contains "$ADMIN_BLOCK" '"CREATE"' "admin grants CREATE"

echo "== the role is dropped without taking its objects along =="
assert_eq "present" "$(grep -q 'skip_reassign_owned = false' <<<"$MAIN" && echo present || echo absent)" "ownership is reassigned on drop"

echo "== default privileges cover objects the administrator creates later =="
assert_eq "present" "$(grep -q 'owner       = local.server.admin_login' <<<"$MAIN" && echo present || echo absent)" "default privileges keyed on the admin role"

echo "== the provider connects over TLS and not as a superuser =="
PROV=$(sed 's/#.*//' "$MODULE/providers.tf")
assert_eq "present" "$(grep -q 'sslmode = "require"' <<<"$PROV" && echo present || echo absent)" "sslmode=require, matching ENCRYPTED_ONLY"
assert_eq "present" "$(grep -q 'superuser       = false' <<<"$PROV" && echo present || echo absent)" "superuser=false, as Cloud SQL requires"
assert_eq "present" "$(grep -q 'cyrilgdn/postgresql' <<<"$PROV" && echo present || echo absent)" "postgresql provider declared"
assert_eq "absent" "$(grep -q 'provider "google"' <<<"$PROV" && echo present || echo absent)" "no google provider: GCP is reached only through the gcs remote state"
assert_eq "present" "$(grep -q 'host     = local.server.hostname' <<<"$PROV" && echo present || echo absent)" "host read from the deployment state"
assert_eq "present" "$(grep -q 'password = local.server.admin_password' <<<"$PROV" && echo present || echo absent)" "admin password read from the deployment state"

echo "== the link password has no URL-reserved characters =="
LINK_PW=$(sed -n '/resource "random_password" "link"/,/^}/p' "$MODULE/main.tf" 2>/dev/null | tr -s ' ')
assert_contains "$LINK_PW" 'special = false' "link password is alphanumeric"

echo "== the JDBC URL requires TLS and carries no credentials =="
assert_eq "present" "$(grep -q 'sslmode=require' "$MODULE/locals.tf" 2>/dev/null && echo present || echo absent)" "jdbc_url has sslmode=require"
assert_eq "absent" "$(sed 's/#.*//' "$MODULE/locals.tf" | grep 'jdbc_url' | grep -q 'password' && echo present || echo absent)" "jdbc_url embeds no password"

echo "== outputs write_link_outputs depends on =="
for o in username password jdbc_url; do
  assert_eq "present" "$(grep -q "output \"$o\"" "$MODULE/outputs.tf" 2>/dev/null && echo present || echo absent)" "output $o declared"
done
assert_eq "present" "$(sed -n '/output "password"/,/^}/p' "$MODULE/outputs.tf" 2>/dev/null | grep -q 'sensitive   = true' && echo present || echo absent)" "password marked sensitive"

echo "== backend is static and gcs =="
assert_eq "present" "$(grep -q 'backend "gcs" {}' "$MODULE/backend.tf" 2>/dev/null && echo present || echo absent)" "empty gcs backend in backend.tf"

tofu_module_checks "$MODULE"

finish_tests
