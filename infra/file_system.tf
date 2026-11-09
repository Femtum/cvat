locals {
  # CVAT's image runs as the django user, `USER 1000:1000` in the Dockerfile.
  cvat_user_id  = 1000
  cvat_group_id = 1000
}

# cvat_data outlives everything else here: the pods and the chart can be
# reinstalled, the uploaded tasks and their chunks cannot.
resource "aws_efs_file_system" "data" {
  encrypted       = true
  throughput_mode = "elastic"

  tags = {
    Name = "${local.name}-data"
  }

  lifecycle {
    prevent_destroy = true
  }
}

# One per zone, so a node mounts from its own zone and never pays for crossing.
# The subnets are null without a cluster, a plan the NFS rule's precondition
# refuses with the reason.
resource "aws_efs_mount_target" "data" {
  for_each = toset(coalesce(module.platform.shared.kubernetes_subnet_ids, []))

  file_system_id  = aws_efs_file_system.data.id
  subnet_id       = each.value
  security_groups = [aws_security_group.mount_targets.id]
}

# Whatever uid a pod runs as, files land as CVAT's user, inside a directory
# nobody else on the file system can list.
resource "aws_efs_access_point" "data" {
  file_system_id = aws_efs_file_system.data.id

  posix_user {
    uid = local.cvat_user_id
    gid = local.cvat_group_id
  }

  root_directory {
    path = "/cvat_data"

    creation_info {
      owner_uid   = local.cvat_user_id
      owner_gid   = local.cvat_group_id
      permissions = "0750"
    }
  }

  tags = {
    Name = "${local.name}-data"
  }
}

# A file system policy replaces EFS's default one, so mounting through the
# mount targets has to be granted again next to the TLS requirement.
resource "aws_efs_file_system_policy" "data" {
  file_system_id = aws_efs_file_system.data.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowMountThroughMountTargets"
        Effect    = "Allow"
        Principal = { AWS = "*" }
        Action    = ["elasticfilesystem:ClientMount", "elasticfilesystem:ClientWrite"]
        Resource  = aws_efs_file_system.data.arn
        Condition = {
          Bool = { "elasticfilesystem:AccessedViaMountTarget" = "true" }
        }
      },
      {
        Sid       = "DenyUnencryptedTransport"
        Effect    = "Deny"
        Principal = { AWS = "*" }
        Action    = "*"
        Resource  = aws_efs_file_system.data.arn
        Condition = {
          Bool = { "aws:SecureTransport" = "false" }
        }
      },
    ]
  })
}
