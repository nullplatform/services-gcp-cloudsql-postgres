output "hostname" {
  description = "Private IP address of the instance"
  value       = google_sql_database_instance.instance.private_ip_address
}

output "port" {
  description = "PostgreSQL port. Cloud SQL always listens on 5432."
  value       = 5432
}

output "database_name" {
  description = "Database created on the instance"
  value       = google_sql_database.database.name
}

output "instance_name" {
  description = "Cloud SQL instance name"
  value       = google_sql_database_instance.instance.name
}

output "connection_name" {
  description = "Instance connection name (<project>:<region>:<instance>), for the Cloud SQL Auth Proxy and connectors"
  value       = google_sql_database_instance.instance.connection_name
}

output "project_id" {
  description = "GCP project holding the instance"
  value       = google_sql_database_instance.instance.project
}

# Read by the permissions/ module through terraform_remote_state, which is
# the only consumer. write_service_outputs never patches these onto the
# service, and the workflow never prints them.
output "admin_login" {
  description = "Administrator login, used by the permissions module to create per-link roles"
  value       = google_sql_user.admin.name
}

output "admin_password" {
  description = "Administrator password, used by the permissions module to create per-link roles"
  value       = random_password.admin.result
  sensitive   = true
}
