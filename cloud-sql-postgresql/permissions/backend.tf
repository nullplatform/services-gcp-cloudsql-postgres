# Backend configuration is supplied at "tofu init" time by
# build_permissions_context. Each link gets its own prefix inside the
# service's tfstate prefix, so destroying a link's state on unlink cannot
# touch the instance's own state.
terraform {
  backend "gcs" {}
}
