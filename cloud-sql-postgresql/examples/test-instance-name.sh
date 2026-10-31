#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICE_PATH="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/lib/assert.sh"

IN="$SERVICE_PATH/scripts/instance_name"
SID="9f8e7d6c-1234-4321-abcd-000000000000"

echo "== happy path =="
assert_eq "conciliation-db-9f8e7d6c" "$("$IN" "Conciliation DB" "$SID")" "spaces become hyphens, case stripped, id suffix appended"

echo "== hyphens survive, runs collapse, edges are trimmed =="
assert_eq "orders-payments-9f8e7d6c" "$("$IN" "orders-payments" "$SID")" "hyphens kept"
assert_eq "orders-payments-9f8e7d6c" "$("$IN" "--orders___payments--" "$SID")" "runs collapsed and edges trimmed"
assert_eq "orders-payments-9f8e7d6c" "$("$IN" "orders.payments" "$SID")" "dots become hyphens (Cloud SQL rejects them)"

echo "== the name always starts with a letter =="
assert_eq "nppg-2024-db-9f8e7d6c" "$("$IN" "2024 DB" "$SID")" "a leading digit gets the nppg- prefix"
assert_eq "nppg-9-9f8e7d6c" "$("$IN" "9" "$SID")" "a single digit gets the prefix"
assert_eq "nppg-2024-db-9f8e7d6c" "$("$IN" "--2024 DB" "$SID")" "a digit exposed by edge trimming gets the prefix"
assert_eq "ledger-12345678" "$("$IN" "ledger" "12345678-aaaa")" "a service id starting with a digit is fine as a suffix"

echo "== length cap is 63 and the id suffix survives =="
LONG=$("$IN" "averyveryverylongservicenamethatoverflowsthesixtythreecharacterlimitbyfar" "$SID")
assert_eq "63" "${#LONG}" "result is exactly 63 chars"
assert_eq "9f8e7d6c" "${LONG: -8}" "id suffix preserved at the end"
assert_eq "-" "${LONG:54:1}" "base and suffix are joined by a hyphen"
LONG_DIGIT=$("$IN" "1averyveryverylongservicenamethatoverflowsthesixtythreecharacterlimit" "$SID")
assert_eq "63" "${#LONG_DIGIT}" "a prefixed long name is still capped at 63"
assert_eq "nppg-1" "${LONG_DIGIT:0:6}" "the prefix survives truncation"
LONG_HYPHEN=$("$IN" "$(printf 'a%.0s' $(seq 1 53))-b" "$SID")
assert_eq "$(printf 'a%.0s' $(seq 1 53))-9f8e7d6c" "$LONG_HYPHEN" "a hyphen left at the cut is dropped, never doubled"

echo "== empty and unusable names fall back =="
assert_eq "nppg-9f8e7d6c" "$("$IN" "" "$SID")" "empty name falls back to nppg"
assert_eq "nppg-9f8e7d6c" "$("$IN" "!!!___###" "$SID")" "name that sanitizes to nothing falls back"

echo "== output always satisfies the Cloud SQL pattern =="
for name in "" "a" "ab" "Conciliation DB" "!!!" "averyveryverylongservicenamethatoverflowsthesixtythreecharacterlimitbyfar" \
            "UPPER-CASE-99" "trailing-" "2024" "-1-" "ünïcödé name" "a.b.c"; do
  out=$("$IN" "$name" "$SID")
  if [[ "$out" =~ ^[a-z]([a-z0-9-]{0,61}[a-z0-9])?$ ]] && [ "${#out}" -le 63 ]; then
    echo "  ok   valid for input [$name] -> $out"
  else
    echo "  FAIL invalid for input [$name] -> $out" >&2
    FAILURES=$((FAILURES + 1))
  fi
done

echo "== the same input always yields the same name =="
assert_eq "$("$IN" "Conciliation DB" "$SID")" "$("$IN" "Conciliation DB" "$SID")" "deterministic"

echo "== bad arguments are errors =="
assert_fails "no service_id exits non-zero" "$IN" "some-name"
assert_fails "a service_id with no alphanumerics exits non-zero" "$IN" "some-name" "----"

finish_tests
