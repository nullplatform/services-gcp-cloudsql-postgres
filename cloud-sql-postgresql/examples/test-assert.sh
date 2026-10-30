#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/assert.sh"

echo "== assert.sh =="
assert_eq "a" "a" "equal strings pass"
assert_contains "hello world" "lo wo" "substring found"
assert_fails "false exits non-zero" false

# A deliberate failure must be counted, not fatal.
if ( FAILURES=0; assert_eq "a" "b" "mismatch" >/dev/null 2>&1; [ "$FAILURES" -eq 1 ] ); then
  assert_eq "counted" "counted" "a failed assertion increments FAILURES"
else
  assert_eq "counted" "not counted" "a failed assertion increments FAILURES"
fi

finish_tests
