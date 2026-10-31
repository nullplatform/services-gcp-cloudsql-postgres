terraform {
  required_version = ">= 1.9.0"

  required_providers {
    postgresql = {
      source  = "cyrilgdn/postgresql"
      version = "~> 1.25"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

# No google provider here: this module touches GCP only through the
# terraform_remote_state data source (the gcs backend, authenticated with
# Application Default Credentials) and PostgreSQL itself, over TLS, on the
# instance's private IP.
provider "postgresql" {
  host     = local.server.hostname
  port     = local.server.port
  database = local.server.database_name
  username = local.server.admin_login
  password = local.server.admin_password

  # The instance runs with ssl_mode = ENCRYPTED_ONLY.
  sslmode = "require"

  # A Cloud SQL user is a member of cloudsqlsuperuser, not a superuser.
  # With superuser = false the provider grants itself the link's role for the
  # operations that need ownership (REASSIGN OWNED on drop, default
  # privileges), which is exactly what Cloud SQL allows.
  superuser       = false
  connect_timeout = 30
}
