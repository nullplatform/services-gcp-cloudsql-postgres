################################################################################
# Requirements — the GCP permissions the cloud-sql-postgresql worker needs.
#
# The worker pod runs as the agent's Kubernetes service account (the agent
# module patches serviceAccountName onto every package listed in
# worker_orchestrated_packages). Workload Identity Federation for GKE lets IAM
# grant roles to that Kubernetes identity directly, as a principal:// member,
# so there is no GCP service account and no key anywhere.
#
# Grants:
#   - roles/cloudsql.admin on the project: create, update and delete
#     instances, databases and users.
#   - roles/storage.objectAdmin on the tfstate bucket: read and write the
#     per-service state. Optionally creates the bucket.
#
# Not here, because it belongs to the network layer: Private Service Access
# on the VPC (a reserved range plus the servicenetworking peering). Every
# instance gets a private IP in that range.
################################################################################

data "google_project" "this" {
  project_id = var.project_id
}

locals {
  worker_principal = format(
    "principal://iam.googleapis.com/projects/%s/locations/global/workloadIdentityPools/%s.svc.id.goog/subject/ns/%s/sa/%s",
    data.google_project.this.number,
    var.project_id,
    var.agent_namespace,
    var.agent_service_account,
  )
}

resource "google_project_service" "apis" {
  for_each = var.enable_apis ? toset(["sqladmin.googleapis.com", "servicenetworking.googleapis.com"]) : toset([])

  project            = var.project_id
  service            = each.value
  disable_on_destroy = false
}

resource "google_project_iam_member" "cloudsql_admin" {
  project = var.project_id
  role    = "roles/cloudsql.admin"
  member  = local.worker_principal
}

resource "google_storage_bucket" "tfstate" {
  count = var.create_tfstate_bucket ? 1 : 0

  name                        = var.tfstate_bucket
  project                     = var.project_id
  location                    = var.tfstate_bucket_location
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"

  # The state holds the instance's administrator password.
  versioning {
    enabled = true
  }
}

resource "google_storage_bucket_iam_member" "tfstate" {
  bucket = var.create_tfstate_bucket ? google_storage_bucket.tfstate[0].name : var.tfstate_bucket
  role   = "roles/storage.objectAdmin"
  member = local.worker_principal
}
