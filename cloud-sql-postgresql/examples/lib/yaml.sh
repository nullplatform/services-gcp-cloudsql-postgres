#!/bin/bash
# Converts YAML to JSON for the tests, so every assertion on a workflow can be
# written in jq. Sourced, never executed.
#
# Uses whichever parser this machine has: PyYAML, mikefarah's yq, or Ruby's
# bundled Psych. None of them is a runtime dependency of the service.

# yaml_json <file> — echoes the file as compact JSON, or fails.
yaml_json() {
  local f="$1"
  if python3 -c 'import yaml' >/dev/null 2>&1; then
    python3 -c 'import json, sys, yaml; print(json.dumps(yaml.safe_load(open(sys.argv[1])) or {}))' "$f"
  elif command -v yq >/dev/null 2>&1 && yq --version 2>/dev/null | grep -q mikefarah; then
    yq -o=json -I=0 '. // {}' "$f"
  elif command -v ruby >/dev/null 2>&1; then
    ruby -ryaml -rjson -e 'puts JSON.generate(YAML.safe_load(File.read(ARGV[0])) || {})' "$f"
  else
    echo "yaml_json: no YAML parser found (need PyYAML, mikefarah yq or ruby)" >&2
    return 1
  fi
}
