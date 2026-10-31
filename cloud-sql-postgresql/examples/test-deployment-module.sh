#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICE_PATH="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/lib/assert.sh"
source "$SCRIPT_DIR/lib/tofu-module.sh"

MODULE="$SERVICE_PATH/deployment"
MAIN=$(sed 's/#.*//' "$MODULE/main.tf")

has() { grep -q -- "$1" <<<"$2" && echo present || echo absent; }

echo "== the module takes typed variables, not a context blob =="
assert_eq "absent" "$(has 'variable "context"' "$(cat "$MODULE/variables.tf")")" "no var.context"
assert_eq "absent" "$(grep -q 'jsondecode' "$MODULE"/*.tf && echo present || echo absent)" "no jsondecode of a notification"
VARS=$(grep -o '^variable "[a-z_]*"' "$MODULE/variables.tf" | cut -d'"' -f2 | sort | tr '\n' ' ' | sed 's/ $//')
assert_eq "backup_retention_days database_name disk_size_gb high_availability instance_name labels network postgres_version project_id region service_id tier" \
  "$VARS" "exactly the variables build_context emits"

echo "== every variable with a format is validated, mirroring build_context =="
for v in service_id instance_name project_id region network database_name postgres_version tier disk_size_gb backup_retention_days; do
  BLOCK=$(sed -n "/variable \"$v\"/,/^}/p" "$MODULE/variables.tf")
  assert_contains "$BLOCK" "validation {" "variable $v carries a validation block"
done

echo "== the module's regexes are the ones build_context enforces =="
BC=$(cat "$SERVICE_PATH/scripts/build_context")
for v in instance_name project_id region network database_name tier; do
  RE=$(sed -n "/variable \"$v\"/,/^}/p" "$MODULE/variables.tf" | grep -o 'regex("[^"]*"' | head -1 | sed 's/^regex("//; s/"$//')
  if [ -n "$RE" ] && [[ "$BC" == *"$RE"* ]]; then
    echo "  ok   $v: same pattern in the module and in build_context"
  else
    echo "  FAIL $v: module pattern [$RE] not found in build_context" >&2
    FAILURES=$((FAILURES + 1))
  fi
done

echo "== the instance is private, TLS-only, and none of it is variable =="
assert_eq "present" "$(has 'ipv4_enabled    = false' "$MAIN")" "no public IP"
assert_eq "present" "$(has 'private_network = var.network' "$MAIN")" "private IP in the caller's VPC"
assert_eq "present" "$(has 'ssl_mode        = "ENCRYPTED_ONLY"' "$MAIN")" "ssl_mode is ENCRYPTED_ONLY"
assert_eq "absent" "$(has 'authorized_networks' "$MAIN")" "no authorized networks"
assert_eq "absent" "$(sed 's/#.*//' "$MODULE"/*.tf | grep -q '0\.0\.0\.0' && echo present || echo absent)" "no 0.0.0.0 anywhere"
for v in ssl_mode ipv4_enabled public_ip; do
  assert_eq "absent" "$(has "variable \"$v\"" "$(cat "$MODULE/variables.tf")")" "$v is not a variable"
done

echo "== the edition is pinned so the small tiers keep working =="
assert_eq "present" "$(has 'edition           = "ENTERPRISE"' "$MAIN")" "edition ENTERPRISE"
assert_eq "present" "$(has 'database_version = "POSTGRES_${var.postgres_version}"' "$MAIN")" "major version from the variable"

echo "== HA is dropped on shared-core tiers and brings PITR with it =="
assert_eq "present" "$(has 'contains(\["db-f1-micro", "db-g1-small"\], var.tier)' "$MAIN")" "shared-core tiers detected"
assert_eq "present" "$(has 'availability_type = local.ha_enabled ? "REGIONAL" : "ZONAL"' "$MAIN")" "REGIONAL only when HA is enabled"
assert_eq "present" "$(has 'point_in_time_recovery_enabled = local.ha_enabled' "$MAIN")" "PITR follows HA"

echo "== the disk and backups follow the variables =="
assert_eq "present" "$(has 'disk_size = var.disk_size_gb' "$MAIN")" "disk size from the variable"
assert_eq "present" "$(has 'disk_autoresize = false' "$MAIN")" "autoresize off, so disk_size stays the source of truth"
assert_eq "present" "$(has 'retained_backups = var.backup_retention_days' "$MAIN")" "backup retention from the variable"

echo "== labels from the notification are merged with the managed-by labels =="
assert_eq "present" "$(has 'user_labels                 = local.labels' "$MAIN")" "labels applied to the instance"
assert_eq "present" "$(has 'merge(var.labels' "$MAIN")" "notification labels merged"

echo "== the administrator password is generated, never taken as input =="
assert_eq "present" "$(has 'resource "random_password" "admin"' "$MAIN")" "random_password.admin exists"
assert_eq "present" "$(has 'password = random_password.admin.result' "$MAIN")" "the admin user gets the generated password"
assert_eq "absent" "$(grep -q 'variable "admin_password"\|variable "administrator_password"\|variable "password"' "$MODULE/variables.tf" && echo present || echo absent)" "no password variable"
assert_eq "present" "$(has 'resource "google_sql_user" "admin"' "$MAIN")" "administrator user declared"
assert_eq "present" "$(has 'name     = "npadmin"' "$MAIN")" "administrator is npadmin"

echo "== the database is created on the instance =="
assert_eq "present" "$(has 'resource "google_sql_database" "database"' "$MAIN")" "google_sql_database declared"
assert_eq "present" "$(has 'name     = var.database_name' "$MAIN")" "database name from the variable"

echo "== the name is never recomputed inside the module =="
assert_eq "present" "$(has 'name             = var.instance_name' "$MAIN")" "instance name comes straight from the variable"

echo "== the delete action is not blocked by Terraform-level guards =="
assert_eq "present" "$(has 'deletion_protection = false' "$MAIN")" "deletion_protection off"
assert_eq "present" "$(has 'deletion_protection_enabled = false' "$MAIN")" "API-level deletion protection off"

echo "== outputs the write_service_outputs step and the permissions module depend on =="
OUTS=$(grep -o '^output "[a-z_]*"' "$MODULE/outputs.tf" | cut -d'"' -f2 | sort | tr '\n' ' ' | sed 's/ $//')
assert_eq "admin_login admin_password connection_name database_name hostname instance_name port project_id" "$OUTS" "exactly the expected outputs"
assert_eq "present" "$(sed -n '/output "admin_password"/,/^}/p' "$MODULE/outputs.tf" | grep -q 'sensitive   = true' && echo present || echo absent)" "admin_password marked sensitive"
assert_eq "present" "$(sed -n '/output "hostname"/,/^}/p' "$MODULE/outputs.tf" | grep -q 'private_ip_address' && echo present || echo absent)" "hostname is the private IP"
WSO=$(cat "$SERVICE_PATH/scripts/write_service_outputs")
for o in hostname port database_name instance_name connection_name project_id; do
  assert_contains "$WSO" ".$o.value" "write_service_outputs reads the $o output"
done
while read -r o; do
  assert_contains " $OUTS " " $o " "output $o, read by the permissions module, exists"
done < <(grep -ho 'local\.server\.[a-z_]*' "$SERVICE_PATH"/permissions/*.tf | sed 's/^local\.server\.//' | sort -u)

echo "== audit logging flags (trivy GCP-0014/0016/0020/0022/0025) =="
# flag_value <name>: the value of the database_flags block with that name.
flag_value() {
  grep -A1 "name  = \"$1\"" "$MODULE/main.tf" | sed -n 's/.*value = "\(.*\)"/\1/p' | head -1
}
for f in log_checkpoints log_connections log_disconnections log_lock_waits; do
  assert_eq "on" "$(flag_value "$f")" "flag $f is on"
done
assert_eq "0" "$(flag_value log_temp_files)" "log_temp_files logs every temporary file"
assert_eq "absent" "$(grep -q 'dynamic "database_flags"' "$MODULE/main.tf" && echo present || echo absent)" "flags are literal blocks, which static scanners can read"

echo "== backend is static, gcs, and unconfigured =="
assert_eq "present" "$(grep -q 'backend "gcs" {}' "$MODULE/backend.tf" && echo present || echo absent)" "empty gcs backend declared in backend.tf"
assert_eq "present" "$(grep -q 'hashicorp/google' "$MODULE/providers.tf" && echo present || echo absent)" "google provider declared"
assert_eq "absent" "$(sed 's/#.*//' "$MODULE/providers.tf" | grep -q 'credentials' && echo present || echo absent)" "no credentials in the provider (ADC only)"

tofu_module_checks "$MODULE"

finish_tests
