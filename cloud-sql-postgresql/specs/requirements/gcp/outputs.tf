output "worker_principal" {
  description = "IAM principal the worker authenticates as"
  value       = local.worker_principal
}

output "tfstate_bucket" {
  description = "Bucket to configure as the service's tfstate_bucket (SERVICES_TFSTATE_BUCKET)"
  # Not google_storage_bucket_iam_member.tfstate.bucket: the provider reads it
  # back as "b/<name>" after an apply.
  value = var.create_tfstate_bucket ? google_storage_bucket.tfstate[0].name : var.tfstate_bucket
}
