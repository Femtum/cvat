output "backend_data_volume_handle" {
  description = "volumeHandle of the static PersistentVolume behind <release>-backend-data: the file system and the access point every mount goes through"
  value       = "${aws_efs_file_system.data.id}::${aws_efs_access_point.data.id}"
}

output "target_group_arn" {
  description = "Target group the TargetGroupBinding registers Traefik's pods into"
  value       = module.ingress.target_group_arn
}

output "url" {
  value = "https://${module.ingress.hostname}"
}

output "database_address" {
  description = "Host of cvat-database, for the chart's postgresql.external.host"
  value       = aws_db_instance.database.address
}

output "kubernetes_namespace" {
  description = "Namespace Argo CD deploys CVAT into, which the platform's ApplicationSet names <app>-<env> after deploy/cvat/values-<env>.yaml"
  value       = local.kubernetes_namespace
}

output "database_secret_name" {
  description = "Secrets Manager secret holding CVAT's database user (username, database, password), made by hand: the platform's store only lets kubernetes_namespace read k8s/<namespace>/*"
  value       = "k8s/${local.kubernetes_namespace}/database"
}

output "grafana_admin_secret_name" {
  description = "Secrets Manager secret holding Grafana's admin (username, password), made by hand under the same prefix as database_secret_name"
  value       = "k8s/${local.kubernetes_namespace}/grafana"
}
