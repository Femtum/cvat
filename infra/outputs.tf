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
