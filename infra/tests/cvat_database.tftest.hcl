# Locks who reaches cvat-database and how it is kept: Postgres only from the
# cluster's and the Client VPN's security groups, never from a network, no
# egress, encrypted, private and protected from deletion.
#
# core/infra/database.tf (lit-database) is the structure these tests mirror,
# not the model: it has no storage_encrypted, no deletion_protection and an
# allow-all egress rule, all three of which are refused here.
#
# The AWS and TFE providers are mocked and the platform contract is overridden,
# so the suite needs no credentials or Terraform Cloud access, creates nothing
# and costs nothing. It applies against the mock because Terraform 1.10 cannot
# override computed values during plan.

mock_provider "tfe" {}

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
  target = aws_security_group.database
  values = {
    id = "sg-0000000000000000d"
  }
}

# The provider validates these as ARNs when other resources reference them.
override_resource {
  target = aws_efs_file_system.data
  values = {
    arn = "arn:aws:elasticfilesystem:ca-central-1:111122223333:file-system/fs-0123456789abcdef0"
  }
}

override_resource {
  target = aws_iam_role.backup
  values = {
    arn = "arn:aws:iam::111122223333:role/cvat-backup-rnd"
  }
}

override_resource {
  target = module.ingress.aws_lb_target_group.http
  values = {
    arn = "arn:aws:elasticloadbalancing:ca-central-1:111122223333:targetgroup/cvat-http/0123456789abcdef"
  }
}

variables {
  environment_name = "rnd"
}

# Every Postgres admission goes through the one keyed postgres resource, so its
# length is the number of rules.
run "given_the_cluster_and_the_client_vpn_when_applying_then_exactly_their_two_groups_reach_postgres" {
  command = apply

  assert {
    condition     = length(aws_vpc_security_group_ingress_rule.postgres) == 2
    error_message = "cvat-database must hold exactly two ingress rules: the cluster's group and the Client VPN's."
  }

  assert {
    condition     = aws_vpc_security_group_ingress_rule.postgres["kubernetes_cluster"].referenced_security_group_id == "sg-0000000000000000e"
    error_message = "Postgres must admit the cluster's security group, the one Auto Mode's nodes and pods carry."
  }

  assert {
    condition     = aws_vpc_security_group_ingress_rule.postgres["client_vpn"].referenced_security_group_id == "sg-0000000000000000c"
    error_message = "Postgres must admit Client VPN users by the endpoint's security group."
  }

  assert {
    condition     = alltrue([for rule in aws_vpc_security_group_ingress_rule.postgres : rule.security_group_id == "sg-0000000000000000d"])
    error_message = "Both rules must belong to cvat-database's own group."
  }

  assert {
    condition     = alltrue([for rule in aws_vpc_security_group_ingress_rule.postgres : rule.ip_protocol == "tcp" && rule.from_port == 5432 && rule.to_port == 5432])
    error_message = "Each client must be admitted to Postgres, 5432/tcp, only."
  }
}

run "given_the_database_group_when_applying_then_no_network_reaches_it_and_0_0_0_0_0_never_does" {
  command = apply

  assert {
    condition     = alltrue([for rule in aws_vpc_security_group_ingress_rule.postgres : rule.cidr_ipv4 == null && rule.cidr_ipv6 == null && rule.prefix_list_id == null])
    error_message = "Postgres must admit security groups and no network: a CIDR would admit every interface in it, site-to-site networks included."
  }

  assert {
    condition     = length(aws_security_group.database.ingress) == 0
    error_message = "cvat-database's group must hold no inline ingress: its only admissions are the two postgres rules."
  }
}

# Terraform removes AWS's default allow-all egress rule when it creates the
# group. The mock only sees the group's own rules: a standalone
# aws_vpc_security_group_egress_rule on it would not show here, so never add
# one (see README.md).
run "given_the_database_group_when_applying_then_it_has_no_egress" {
  command = apply

  assert {
    condition     = length(aws_security_group.database.egress) == 0
    error_message = "cvat-database's group must hold no egress rule, unlike lit-database's 0.0.0.0/0: replies need none and RDS opens no connection here."
  }
}

# EC2 rejects rule descriptions outside this set only at apply, after other
# changes of the same run have already landed.
run "given_the_postgres_rules_when_applying_then_ec2_accepts_their_descriptions" {
  command = apply

  assert {
    condition     = alltrue([for description in concat([aws_security_group.database.description], [for rule in aws_vpc_security_group_ingress_rule.postgres : rule.description]) : can(regex("^[a-zA-Z0-9. _\\-:/()#,@\\[\\]+=&;{}!$*]{0,255}$", description))])
    error_message = "EC2 refuses a description with any other character than a-zA-Z0-9. _-:/()#,@[]+=&;{}!$*, an apostrophe included, and only at apply."
  }
}

run "given_the_database_when_planned_then_it_is_private_encrypted_and_protected_from_deletion" {
  command = plan

  assert {
    condition     = aws_db_instance.database.publicly_accessible == false
    error_message = "cvat-database must not be publicly accessible."
  }

  assert {
    condition     = aws_db_instance.database.storage_encrypted == true
    error_message = "cvat-database must be encrypted at rest."
  }

  assert {
    condition     = aws_db_instance.database.deletion_protection == true
    error_message = "cvat-database must refuse deletion until protection is lifted by hand."
  }

  assert {
    condition     = aws_db_instance.database.skip_final_snapshot == false && aws_db_instance.database.final_snapshot_identifier == "cvat-database-final"
    error_message = "Deleting cvat-database must leave the final snapshot cvat-database-final."
  }

  assert {
    condition     = aws_db_instance.database.backup_retention_period == 7 && aws_db_instance.database.backup_window == "03:00-04:00" && aws_db_instance.database.maintenance_window == "sun:05:00-sun:06:00"
    error_message = "cvat-database must keep 7 days of backups, in lit's backup and maintenance windows."
  }
}

run "given_the_database_when_planned_then_it_runs_postgres_17_on_its_agreed_shape" {
  command = plan

  assert {
    condition     = aws_db_instance.database.identifier == "cvat-database" && aws_db_instance.database.engine == "postgres" && aws_db_instance.database.engine_version == "17"
    error_message = "cvat-database must run Postgres 17, pinned to the major only so minor upgrades never show as a diff."
  }

  assert {
    condition     = aws_db_instance.database.auto_minor_version_upgrade == true && aws_db_instance.database.allow_major_version_upgrade == false
    error_message = "Minor upgrades must apply themselves, major upgrades never."
  }

  assert {
    condition     = aws_db_instance.database.parameter_group_name == "default.postgres17"
    error_message = "cvat-database must use default.postgres17, whose rds.force_ssl = 1 refuses connections without TLS."
  }

  assert {
    condition     = aws_db_instance.database.instance_class == "db.t4g.small" && aws_db_instance.database.multi_az == false
    error_message = "cvat-database must be a single-AZ db.t4g.small."
  }

  assert {
    condition     = aws_db_instance.database.storage_type == "gp3" && aws_db_instance.database.allocated_storage == 20 && aws_db_instance.database.max_allocated_storage == 100
    error_message = "cvat-database must start on 20 GB of gp3 and grow by itself up to 100 GB."
  }

  assert {
    condition     = aws_db_instance.database.performance_insights_enabled == true && aws_db_instance.database.performance_insights_retention_period == 7 && aws_db_instance.database.monitoring_interval == 0
    error_message = "cvat-database must use Performance Insights' free tier, seven days, and no enhanced monitoring."
  }

  assert {
    condition     = aws_db_instance.database.manage_master_user_password == true && aws_db_instance.database.password == null
    error_message = "RDS must manage the master password, so no password ever enters Terraform state."
  }
}

run "given_the_platform_subnets_when_applying_then_the_database_lives_in_the_private_subnets_behind_its_group" {
  command = apply

  assert {
    condition     = aws_db_subnet_group.database.name == "cvat-database" && aws_db_subnet_group.database.subnet_ids == toset(["subnet-aaaaaaaaaaaaaaaaa", "subnet-bbbbbbbbbbbbbbbbb"])
    error_message = "cvat-database's subnet group must span the platform's private subnets, where the Client VPN is attached."
  }

  assert {
    condition     = aws_db_instance.database.db_subnet_group_name == "cvat-database" && aws_db_instance.database.vpc_security_group_ids == toset(["sg-0000000000000000d"])
    error_message = "cvat-database must sit in its own subnet group, behind its own security group only."
  }
}

run "given_a_platform_without_a_cluster_group_when_planning_then_postgres_refuses_the_plan" {
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
        kubernetes_cluster_name              = "femtum-rnd"
        kubernetes_cluster_security_group_id = null
        kubernetes_subnet_ids                = ["subnet-0aaaaaaaaaaaaaaaa", "subnet-0bbbbbbbbbbbbbbbb"]
        eso_controller_role_arn              = "arn:aws:iam::111122223333:role/femtum-rnd-external-secrets"
      }
    }
  }

  # The NFS rule refuses a null cluster group for the same reason.
  expect_failures = [
    aws_vpc_security_group_ingress_rule.postgres,
    aws_vpc_security_group_ingress_rule.nfs_from_cluster,
  ]
}
