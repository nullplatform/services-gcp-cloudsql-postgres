output "worker_principal" {
  description = "IAM principal the worker authenticates as"
  value       = local.worker_principal
}

output "tfstate_bucket" {
  description = "Bucket to configure as the service's tfstate_bucket (SERVICES_TFSTATE_BUCKET)"
  value       = google_storage_bucket_iam_member.tfstate.bucket
}
