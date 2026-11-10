# Locks how cvat_data is stored and who reaches it: NFS only from the
# Kubernetes cluster, never from a network, every mount over TLS and through
# CVAT's access point, a mount target in each cluster zone, and a daily backup.
#
# The AWS provider is mocked and the platform contract is overridden, so the
# suite needs no credentials, creates nothing and costs nothing. It applies
# against the mock because Terraform 1.10 cannot override computed values
# during plan.

mock_provider "aws" {}

override_module {
  target = module.platform
  outputs = {
    shared = {
      vpc_id                               = "vpc-0123456789abcdef0"
      private_subnet_ids                   = ["subnet-aaaaaaaaaaaaaaaaa", "subnet-bbbbbbbbbbbbbbbbb"]
      client_vpn_security_group_id         = "sg-0000000000000000c"
      https_listener_arn                   = "arn:aws:elasticloadbalancing:ca-central-1:111122223333:listener/app/femtum-lit-api-alb/0123456789abcdef/0123456789abcdef"
      intranet_domain                      = "rnd.intranet.femtum.com"
      reserved_rule_priorities             = [50000]
      kubernetes_cluster_name              = "femtum-rnd"
      kubernetes_cluster_security_group_id = "sg-0000000000000000e"
      kubernetes_subnet_ids                = ["subnet-0aaaaaaaaaaaaaaaa", "subnet-0bbbbbbbbbbbbbbbb"]
      eso_controller_role_arn              = "arn:aws:iam::111122223333:role/femtum-rnd-external-secrets"
    }
  }
}

override_resource {
  target = aws_efs_file_system.data
  values = {
    id  = "fs-0123456789abcdef0"
    arn = "arn:aws:elasticfilesystem:ca-central-1:111122223333:file-system/fs-0123456789abcdef0"
  }
}

override_resource {
  target = module.ingress.aws_lb_target_group.http
  values = {
    arn = "arn:aws:elasticloadbalancing:ca-central-1:111122223333:targetgroup/cvat-http/0123456789abcdef"
  }
}

override_resource {
  target = aws_efs_access_point.data
  values = {
    id = "fsap-0123456789abcdef0"
  }
}

override_resource {
  target = aws_security_group.mount_targets
  values = {
    id = "sg-0000000000000000f"
  }
}

override_resource {
  target = aws_iam_role.backup
  values = {
    arn = "arn:aws:iam::111122223333:role/cvat-backup-rnd"
  }
}

variables {
  environment_name = "rnd"
}

run "given_the_cluster_when_applying_then_it_alone_reaches_nfs" {
  command = apply

  assert {
    condition     = aws_vpc_security_group_ingress_rule.nfs_from_cluster.security_group_id == "sg-0000000000000000f" && aws_vpc_security_group_ingress_rule.nfs_from_cluster.referenced_security_group_id == "sg-0000000000000000e"
    error_message = "The mount targets' group must admit the cluster's security group, the one Auto Mode's nodes and pods carry."
  }

  assert {
    condition     = aws_vpc_security_group_ingress_rule.nfs_from_cluster.ip_protocol == "tcp" && aws_vpc_security_group_ingress_rule.nfs_from_cluster.from_port == 2049 && aws_vpc_security_group_ingress_rule.nfs_from_cluster.to_port == 2049
    error_message = "The cluster must reach NFS on 2049 only."
  }
}

run "given_the_nfs_rules_when_applying_then_their_descriptions_only_use_characters_ec2_accepts" {
  command = apply

  assert {
    condition     = aws_security_group.mount_targets.description == "NFS to cvat_data from the Kubernetes cluster only" && aws_vpc_security_group_ingress_rule.nfs_from_cluster.description == "NFS from the Kubernetes cluster nodes and pods"
    error_message = "The descriptions must say what the group and its rule admit."
  }

  assert {
    condition     = alltrue([for description in [aws_security_group.mount_targets.description, aws_vpc_security_group_ingress_rule.nfs_from_cluster.description] : can(regex("^[a-zA-Z0-9. _\\-:/()#,@\\[\\]+=&;{}!$*]{0,255}$", description))])
    error_message = "EC2 refuses a description with any other character than a-zA-Z0-9. _-:/()#,@[]+=&;{}!$*, an apostrophe included, and only at apply."
  }
}

run "given_the_mount_targets_when_applying_then_no_network_reaches_them_and_0_0_0_0_0_never_does" {
  command = apply

  assert {
    condition     = aws_vpc_security_group_ingress_rule.nfs_from_cluster.cidr_ipv4 == null && aws_vpc_security_group_ingress_rule.nfs_from_cluster.cidr_ipv6 == null && aws_vpc_security_group_ingress_rule.nfs_from_cluster.prefix_list_id == null
    error_message = "NFS must admit the cluster's group and no network: an office CIDR or 0.0.0.0/0 would let anything on it read cvat_data."
  }

  assert {
    condition     = length(aws_security_group.mount_targets.ingress) == 0 && length(aws_security_group.mount_targets.egress) == 0
    error_message = "The mount targets' group must hold no inline rule: its only admission is nfs_from_cluster."
  }
}

run "given_two_cluster_subnets_when_applying_then_each_holds_one_mount_target_in_the_nfs_group" {
  command = apply

  assert {
    condition     = toset([for target in aws_efs_mount_target.data : target.subnet_id]) == toset(["subnet-0aaaaaaaaaaaaaaaa", "subnet-0bbbbbbbbbbbbbbbb"])
    error_message = "Each Kubernetes subnet must hold one mount target, so nodes mount from their own zone."
  }

  assert {
    condition     = alltrue([for target in aws_efs_mount_target.data : target.file_system_id == "fs-0123456789abcdef0" && target.security_groups == toset(["sg-0000000000000000f"])])
    error_message = "Every mount target must serve cvat_data behind the NFS group only."
  }
}

run "given_the_file_system_when_applying_then_it_is_encrypted_with_elastic_throughput" {
  command = apply

  assert {
    condition     = aws_efs_file_system.data.encrypted == true
    error_message = "cvat_data must be encrypted at rest."
  }

  assert {
    condition     = aws_efs_file_system.data.throughput_mode == "elastic"
    error_message = "cvat_data must use Elastic throughput: Bursting starves a 20 GiB file system to about 1 MiB/s."
  }

}

run "given_the_file_system_when_applying_then_files_untouched_for_30_days_move_to_infrequent_access_and_back_on_first_read" {
  command = apply

  assert {
    condition = jsonencode(aws_efs_file_system.data.lifecycle_policy) == jsonencode([
      { transition_to_archive = null, transition_to_ia = "AFTER_30_DAYS", transition_to_primary_storage_class = null },
      { transition_to_archive = null, transition_to_ia = null, transition_to_primary_storage_class = "AFTER_1_ACCESS" },
    ])
    error_message = "Files untouched for 30 days must move to Infrequent Access, never to Archive, and come back to Standard on their first read."
  }
}

run "given_the_file_system_policy_when_applying_then_mounts_need_a_mount_target_and_tls" {
  command = apply

  assert {
    condition = jsondecode(aws_efs_file_system_policy.data.policy) == {
      Version = "2012-10-17"
      Statement = [
        {
          Sid       = "AllowMountThroughMountTargets"
          Effect    = "Allow"
          Principal = { AWS = "*" }
          Action    = ["elasticfilesystem:ClientMount", "elasticfilesystem:ClientWrite"]
          Resource  = "arn:aws:elasticfilesystem:ca-central-1:111122223333:file-system/fs-0123456789abcdef0"
          Condition = { Bool = { "elasticfilesystem:AccessedViaMountTarget" = "true" } }
        },
        {
          Sid       = "DenyUnencryptedTransport"
          Effect    = "Deny"
          Principal = { AWS = "*" }
          Action    = "*"
          Resource  = "arn:aws:elasticfilesystem:ca-central-1:111122223333:file-system/fs-0123456789abcdef0"
          Condition = { Bool = { "aws:SecureTransport" = "false" } }
        },
      ]
    }
    error_message = "Mounting must go through a mount target, never as root, and every request without TLS must be refused."
  }
}

run "given_the_access_point_when_applying_then_every_file_is_cvats_in_a_private_directory" {
  command = apply

  assert {
    condition     = one(aws_efs_access_point.data.posix_user).uid == 1000 && one(aws_efs_access_point.data.posix_user).gid == 1000
    error_message = "Every file must be written as CVAT's django user, 1000:1000, whatever uid the pod runs as."
  }

  assert {
    condition     = one(aws_efs_access_point.data.root_directory).path == "/cvat_data" && one(one(aws_efs_access_point.data.root_directory).creation_info).owner_uid == 1000 && one(one(aws_efs_access_point.data.root_directory).creation_info).owner_gid == 1000 && one(one(aws_efs_access_point.data.root_directory).creation_info).permissions == "0750"
    error_message = "The access point's directory must be created for CVAT's user with mode 0750, so no other user can list it."
  }
}

run "given_the_file_system_when_applying_then_it_is_backed_up_daily_for_35_days" {
  command = apply

  assert {
    condition     = aws_backup_selection.data.resources == toset(["arn:aws:elasticfilesystem:ca-central-1:111122223333:file-system/fs-0123456789abcdef0"]) && aws_backup_selection.data.iam_role_arn == "arn:aws:iam::111122223333:role/cvat-backup-rnd"
    error_message = "The backup must select cvat_data, as the backup role."
  }

  assert {
    condition     = one(aws_backup_plan.data.rule).target_vault_name == "cvat-rnd" && one(aws_backup_plan.data.rule).schedule == "cron(0 8 * * ? *)" && one(one(aws_backup_plan.data.rule).lifecycle).delete_after == 35
    error_message = "cvat_data must be backed up every night into CVAT's vault and kept 35 days."
  }

  assert {
    condition     = jsondecode(aws_iam_role.backup.assume_role_policy).Statement[0].Principal == { Service = "backup.amazonaws.com" }
    error_message = "Only AWS Backup may assume the backup role."
  }
}

run "given_the_file_system_and_access_point_when_applying_then_the_volume_handle_names_both" {
  command = apply

  assert {
    condition     = output.backend_data_volume_handle == "fs-0123456789abcdef0::fsap-0123456789abcdef0"
    error_message = "The volume handle must name the file system and the access point, so every mount goes through CVAT's directory."
  }
}

run "given_a_platform_without_a_kubernetes_cluster_when_planning_then_the_plan_is_refused" {
  command = plan

  override_module {
    target = module.platform
    outputs = {
      shared = {
        vpc_id                               = "vpc-0123456789abcdef0"
        private_subnet_ids                   = ["subnet-aaaaaaaaaaaaaaaaa", "subnet-bbbbbbbbbbbbbbbbb"]
        client_vpn_security_group_id         = "sg-0000000000000000c"
        https_listener_arn                   = "arn:aws:elasticloadbalancing:ca-central-1:111122223333:listener/app/femtum-lit-api-alb/0123456789abcdef/0123456789abcdef"
        intranet_domain                      = "rnd.intranet.femtum.com"
        reserved_rule_priorities             = [50000]
        kubernetes_cluster_name              = null
        kubernetes_cluster_security_group_id = null
        kubernetes_subnet_ids                = null
        eso_controller_role_arn              = null
      }
    }
  }

  # Without a cluster there is no cluster group for Postgres either, and no
  # External Secrets controller to trust: cvat_database.tftest.hcl checks each.
  expect_failures = [
    aws_vpc_security_group_ingress_rule.nfs_from_cluster,
    aws_vpc_security_group_ingress_rule.postgres,
    aws_iam_role.secrets_read,
  ]
}
