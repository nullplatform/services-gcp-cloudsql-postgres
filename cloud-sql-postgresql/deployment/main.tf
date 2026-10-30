# =============================================================================
# Cloud SQL for PostgreSQL
# =============================================================================
#
# Provisions one Cloud SQL instance with one database per nullplatform
# service instance. Roles for applications are NOT created here: each link
# creates its own role, with grants derived from the link's access level,
# through the permissions/ module.

locals {
  # Cloud SQL offers no HA on the shared-core tiers. Dropping it here,
  # instead of failing the create, keeps the attribute meaningful on a later
  # tier change.
  shared_core = contains(["db-f1-micro", "db-g1-small"], var.tier)
  ha_enabled  = var.high_availability && !local.shared_core

  labels = merge(var.labels, {
    "managed-by" = "nullplatform"
    "service-id" = lower(replace(var.service_id, "/[^a-zA-Z0-9_-]/", "_"))
  })
}

# The administrator password lives in this module's state and nowhere else:
# the permissions/ module reads it back through terraform_remote_state to
# create the per-link roles. Applications never receive it.
resource "random_password" "admin" {
  length           = 32
  special          = true
  override_special = "!#%^*-_+="
  min_lower        = 1
  min_upper        = 1
  min_numeric      = 1
  min_special      = 1
}

resource "google_sql_database_instance" "instance" {
  name             = var.instance_name
  project          = var.project_id
  region           = var.region
  database_version = "POSTGRES_${var.postgres_version}"

  # The delete action is the platform's way to remove the instance; a
  # Terraform-level guard would only make that action fail.
  deletion_protection = false

  settings {
    # ENTERPRISE explicitly: PostgreSQL 16+ defaults to ENTERPRISE_PLUS,
    # which rejects the shared-core and small custom tiers.
    edition           = "ENTERPRISE"
    tier              = var.tier
    availability_type = local.ha_enabled ? "REGIONAL" : "ZONAL"

    disk_type = "PD_SSD"
    disk_size = var.disk_size_gb
    # Off so disk_size stays the single source of truth: with autoresize on,
    # Cloud SQL grows the disk behind Terraform's back and the next update
    # would plan a shrink, which Cloud SQL refuses.
    disk_autoresize = false

    deletion_protection_enabled = false
    user_labels                 = local.labels

    # Private IP only, in the caller's VPC, which must already have Private
    # Service Access (a servicenetworking peering) configured. Every client
    # must speak TLS; no client certificate is required.
    ip_configuration {
      ipv4_enabled    = false
      private_network = var.network
      ssl_mode        = "ENCRYPTED_ONLY"
    }

    backup_configuration {
      enabled    = true
      start_time = "03:00"
      # PostgreSQL HA requires point-in-time recovery.
      point_in_time_recovery_enabled = local.ha_enabled

      backup_retention_settings {
        retained_backups = var.backup_retention_days
        retention_unit   = "COUNT"
      }
    }

    # Audit logging the CIS benchmark asks for (trivy GCP-0014/0016/0020/0022/0025).
    # The logs go to Cloud Logging. These are dynamic PostgreSQL settings, so
    # Cloud SQL applies them without a restart. Literal blocks rather than a
    # dynamic one: static scanners do not expand a dynamic block over locals.
    database_flags {
      name  = "log_checkpoints"
      value = "on"
    }
    database_flags {
      name  = "log_connections"
      value = "on"
    }
    database_flags {
      name  = "log_disconnections"
      value = "on"
    }
    database_flags {
      name  = "log_lock_waits"
      value = "on"
    }
    # 0 logs every temporary file, whatever its size.
    database_flags {
      name  = "log_temp_files"
      value = "0"
    }
  }
}

resource "google_sql_database" "database" {
  name     = var.database_name
  project  = var.project_id
  instance = google_sql_database_instance.instance.name
  charset  = "UTF8"

  # Dropping the database fails while link roles still own objects in it;
  # deleting the instance removes it anyway.
  deletion_policy = "ABANDON"
}

# Cloud SQL users are members of cloudsqlsuperuser, not superusers, which is
# what the permissions/ module's provider is configured for.
resource "google_sql_user" "admin" {
  name     = "npadmin"
  project  = var.project_id
  instance = google_sql_database_instance.instance.name
  password = random_password.admin.result

  # Same reason as the database: the instance deletion removes it.
  deletion_policy = "ABANDON"
}
