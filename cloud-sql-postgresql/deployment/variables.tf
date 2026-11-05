variable "service_id" {
  type        = string
  description = "Nullplatform service instance ID, labelled onto the instance"

  validation {
    condition     = length(var.service_id) > 0
    error_message = "service_id must not be empty. build_context rejects an empty or null .service.id, and this mirrors that rule so a hand-run tofu plan catches it too."
  }
}

variable "instance_name" {
  type        = string
  description = "Cloud SQL instance name, precomputed by scripts/instance_name"

  validation {
    condition     = can(regex("^[a-z]([a-z0-9-]{0,61}[a-z0-9])?$", var.instance_name))
    error_message = "instance_name must be up to 63 lowercase letters, digits and hyphens, starting with a letter and not ending with a hyphen."
  }
}

variable "project_id" {
  type        = string
  description = "GCP project that will hold the instance"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", var.project_id))
    error_message = "project_id must be a valid GCP project ID."
  }
}

variable "region" {
  type        = string
  description = "GCP region of the instance"

  validation {
    condition     = can(regex("^[a-z]+-[a-z]+[0-9]+$", var.region))
    error_message = "region must be a GCP region such as us-east1."
  }
}

variable "network" {
  type        = string
  description = <<-EOT
    VPC the instance gets its private IP in, as
    projects/<project>/global/networks/<name>. It must already have Private
    Service Access configured, and it must be the VPC the agent's cluster runs
    in: the link action connects to the instance from the worker pod.
  EOT

  validation {
    condition     = can(regex("^projects/[a-z][a-z0-9-]{4,28}[a-z0-9]/global/networks/[a-z]([a-z0-9-]{0,61}[a-z0-9])?$", var.network))
    error_message = "network must look like projects/<project>/global/networks/<name>."
  }
}

variable "database_name" {
  type        = string
  description = "Database created on the instance"

  validation {
    condition     = can(regex("^[a-z][a-z0-9_]{0,62}$", var.database_name))
    error_message = "database_name must be 1-63 lowercase letters, digits and underscores, starting with a letter."
  }
}

variable "postgres_version" {
  type        = string
  default     = "16"
  description = "PostgreSQL major version"

  validation {
    condition     = contains(["15", "16", "17"], var.postgres_version)
    error_message = "postgres_version must be 15, 16 or 17."
  }
}

variable "tier" {
  type        = string
  default     = "db-g1-small"
  description = "Machine tier: db-f1-micro, db-g1-small (shared core) or db-custom-<vCPUs>-<memory MB>"

  validation {
    condition     = can(regex("^db-(f1-micro|g1-small|custom-[0-9]+-[0-9]+)$", var.tier))
    error_message = "tier must be db-f1-micro, db-g1-small or db-custom-<vCPUs>-<memory MB>."
  }
}

variable "disk_size_gb" {
  type        = number
  default     = 10
  description = "SSD size in GB. Cloud SQL never shrinks a disk."

  validation {
    condition     = var.disk_size_gb >= 10 && floor(var.disk_size_gb) == var.disk_size_gb
    error_message = "disk_size_gb must be a whole number of at least 10."
  }
}

variable "backup_retention_days" {
  type        = number
  default     = 7
  description = "Number of daily automated backups Cloud SQL keeps"

  validation {
    condition     = var.backup_retention_days >= 1 && var.backup_retention_days <= 365
    error_message = "backup_retention_days must be between 1 and 365."
  }
}

variable "high_availability" {
  type        = bool
  default     = false
  description = "Regional standby. Silently ignored on the shared-core tiers, which Cloud SQL does not run with HA."
}

variable "labels" {
  type        = map(string)
  default     = {}
  description = "Labels propagated from the nullplatform notification context"
}
