#!/bin/bash
# Offline OpenTofu checks shared by the module tests. Sourced, never executed.
# Requires lib/assert.sh to be sourced first.

# tofu_module_checks <module_dir>
# fmt -check always runs (it needs no providers). validate runs in a scratch
# copy of the module, initialised ONLY from the providers already under
# <module_dir>/.terraform/providers, through a CLI config that declares a
# filesystem mirror and no direct installation: nothing is downloaded, and
# the module directory itself is never written to. With no local providers,
# validate is skipped.
tofu_module_checks() {
  local module="$1" scratch vout vrc
  if ! command -v tofu >/dev/null 2>&1; then
    echo "  skip tofu not installed"
    return 0
  fi

  echo "== fmt and validate =="
  assert_eq "formatted" "$(tofu fmt -check -recursive "$module" >/dev/null 2>&1 && echo formatted || echo unformatted)" "tofu fmt -check passes"

  if [ ! -d "$module/.terraform/providers" ]; then
    echo "  skip tofu validate (no local providers; run: tofu -chdir=$module init -backend=false)"
    return 0
  fi

  scratch=$(mktemp -d)
  cp "$module"/*.tf "$scratch"/
  cat > "$scratch/offline.tofurc" <<EOF
provider_installation {
  filesystem_mirror {
    path    = "$module/.terraform/providers"
    include = ["*/*/*"]
  }
}
EOF

  if ! vout=$(cd "$scratch" && TF_CLI_CONFIG_FILE="$scratch/offline.tofurc" tofu init -backend=false -input=false -no-color 2>&1); then
    echo "  skip tofu validate (local providers do not satisfy the constraints; run: tofu -chdir=$module init -backend=false)"
    rm -rf "$scratch"
    return 0
  fi

  vout=$(cd "$scratch" && TF_CLI_CONFIG_FILE="$scratch/offline.tofurc" tofu validate -no-color 2>&1) && vrc=0 || vrc=$?
  assert_eq "0" "$vrc" "tofu validate succeeds"
  [ "$vrc" -eq 0 ] || echo "$vout" >&2
  rm -rf "$scratch"
}
