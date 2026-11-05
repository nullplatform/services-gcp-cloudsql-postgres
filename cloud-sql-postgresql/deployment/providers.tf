terraform {
  required_version = ">= 1.9.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

# Credentials come from Application Default Credentials: in the worker pod,
# the agent's Kubernetes service account through Workload Identity
# Federation; during local testing, a "gcloud auth application-default
# login" session or GOOGLE_APPLICATION_CREDENTIALS.
provider "google" {
  project = var.project_id
  region  = var.region
}
