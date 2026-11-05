variable "project_id" {
  description = "GCP project where the instances are created and the agent's cluster runs."
  type        = string
}

variable "agent_namespace" {
  description = "Kubernetes namespace of the agent's service account. tofu-modules' nullplatform/agent installs into nullplatform-tools."
  type        = string
  default     = "nullplatform-tools"
}

variable "agent_service_account" {
  description = "Kubernetes service account the agent and its workers run as (the agent module's service_account_name)."
  type        = string
  default     = "nullplatform-agent"
}

variable "tfstate_bucket" {
  description = "GCS bucket the service keeps its OpenTofu state in. Use a dedicated one: the worker gets object admin on the whole bucket, and the state holds each instance's administrator password."
  type        = string
}

variable "create_tfstate_bucket" {
  description = "Create the tfstate bucket here. False when it already exists."
  type        = bool
  default     = true
}

variable "tfstate_bucket_location" {
  description = "Location of the tfstate bucket, when this module creates it."
  type        = string
  default     = "US"
}

variable "enable_apis" {
  description = "Enable sqladmin and servicenetworking on the project. False when the project's own infrastructure code already does."
  type        = bool
  default     = false
}
