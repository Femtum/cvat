output "backend_data_volume_handle" {
  description = "volumeHandle of the static PersistentVolume behind <release>-backend-data: the file system and the access point every mount goes through"
  value       = "${aws_efs_file_system.data.id}::${aws_efs_access_point.data.id}"
}

output "url" {
  description = "Where office and Client VPN users reach CVAT, through the platform's Gateway"
  value       = "https://${local.name}.${module.platform.shared.intranet_domain}"
}

output "database_address" {
  description = "Host of cvat-database, for the chart's postgresql.external.host"
  value       = aws_db_instance.database.address
}
