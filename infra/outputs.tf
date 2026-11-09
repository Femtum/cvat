output "backend_data_volume_handle" {
  description = "volumeHandle of the static PersistentVolume behind <release>-backend-data: the file system and the access point every mount goes through"
  value       = "${aws_efs_file_system.data.id}::${aws_efs_access_point.data.id}"
}
