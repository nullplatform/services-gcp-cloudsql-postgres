variable "link_id" {
  type        = string
  description = "Nullplatform link ID, used for traceability"

  validation {
    condition     = length(var.link_id) > 0
    error_message = "link_id must not be empty. build_permissions_context refuses to run without it, and this mirrors that rule."
  }
}

variable "username" {
  type        = string
  description = "PostgreSQL role to create for this link, precomputed by build_context and stable across updates"

  validation {
    condition     = can(regex("^[a-z][a-z0-9_]{2,62}$", var.username))
    error_message = "username must be 3-63 lowercase letters, digits and underscores, starting with a letter."
  }
}

variable "access_level" {
  type        = string
  default     = "admin"
  description = "Grants given to the role: read, read-write or admin"

  validation {
    condition     = contains(["read", "read-write", "admin"], var.access_level)
    error_message = "access_level must be read, read-write or admin."
  }
}

# --- Where the deployment module left its state ------------------------------
# The instance's address, database and administrator credentials are read
# from there rather than passed in: the password never crosses the workflow
# engine's environment channel, and the address cannot drift from what was
# actually created.

variable "tfstate_bucket" {
  type        = string
  description = "GCS bucket holding the tfstate"

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9._-]{1,61}[a-z0-9]$", var.tfstate_bucket))
    error_message = "tfstate_bucket must be a valid GCS bucket name."
  }
}

variable "deployment_state_prefix" {
  type        = string
  description = "Prefix of the deployment module's state for this service instance"

  validation {
    condition     = endswith(var.deployment_state_prefix, "/deployment")
    error_message = "deployment_state_prefix must point at a <service>/deployment prefix."
  }
}
