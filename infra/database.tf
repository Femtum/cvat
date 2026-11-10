locals {
  database_name = "${local.name}-database"
  database_port = 5432

  # Postgres admits callers by security group, never by address range: a range
  # admits every interface in it, site-to-site networks included. Keyed so the
  # tests can hold the set to exactly these two.
  database_clients = {
    # Auto Mode gives the API endpoint, every node and every pod this one
    # group, so every pod on the cluster is admitted. Accepted while CVAT is
    # the cluster's only app; revisit when a second one joins.
    kubernetes_cluster = {
      security_group_id = module.platform.shared.kubernetes_cluster_security_group_id
      description       = "PostgreSQL from the Kubernetes cluster nodes and pods"
    }
    # Client VPN source-NATs its clients to its network interfaces, which
    # carry this group.
    client_vpn = {
      security_group_id = module.platform.shared.client_vpn_security_group_id
      description       = "PostgreSQL from Client VPN users"
    }
  }
}

resource "aws_db_subnet_group" "database" {
  name       = local.database_name
  subnet_ids = module.platform.shared.private_subnet_ids

  tags = {
    Name = local.database_name
  }
}

# Terraform drops the default egress rule, and Postgres replies need none: the
# group is stateful and RDS opens no connection of its own here.
resource "aws_security_group" "database" {
  name        = local.database_name
  description = "PostgreSQL to cvat-database from the Kubernetes cluster and Client VPN only"
  vpc_id      = module.platform.shared.vpc_id

  tags = {
    Name = local.database_name
  }
}

resource "aws_vpc_security_group_ingress_rule" "postgres" {
  for_each = local.database_clients

  security_group_id = aws_security_group.database.id
  description       = each.value.description

  referenced_security_group_id = each.value.security_group_id
  ip_protocol                  = "tcp"
  from_port                    = local.database_port
  to_port                      = local.database_port

  lifecycle {
    precondition {
      condition     = each.value.security_group_id != null
      error_message = "The platform workspace infrastructure-aws-${var.environment_name} publishes no ${each.key} security group: set is_kubernetes_cluster_enabled there first, and apply the platform before bumping platform_contract."
    }
  }
}

# CVAT's data outlives everything else here, alongside cvat_data. The master
# user is RDS-managed and for humans only: CVAT connects as its own user, made
# by hand (see README.md), because RDS rotates the master password every week.
resource "aws_db_instance" "database" {
  identifier = local.database_name

  engine = "postgres"
  # Major only, so a minor upgrade in the maintenance window never shows as a
  # diff. A major upgrade is a deliberate change of this line.
  engine_version              = "17"
  auto_minor_version_upgrade  = true
  allow_major_version_upgrade = false
  # Sets rds.force_ssl = 1 (checked with `aws rds describe-db-parameters`):
  # every connection is refused without TLS.
  parameter_group_name = "default.postgres17"

  # About 200 max_connections; CVAT opens one per request.
  instance_class        = "db.t4g.small"
  storage_type          = "gp3"
  allocated_storage     = 20
  max_allocated_storage = 100
  storage_encrypted     = true
  multi_az              = false

  username                    = "femtum"
  manage_master_user_password = true

  db_subnet_group_name   = aws_db_subnet_group.database.name
  vpc_security_group_ids = [aws_security_group.database.id]
  publicly_accessible    = false
  port                   = local.database_port

  backup_retention_period = 7
  backup_window           = "03:00-04:00"
  maintenance_window      = "sun:05:00-sun:06:00"
  copy_tags_to_snapshot   = true

  # Free tier: seven days, no enhanced monitoring.
  performance_insights_enabled          = true
  performance_insights_retention_period = 7
  monitoring_interval                   = 0

  deletion_protection       = true
  skip_final_snapshot       = false
  final_snapshot_identifier = "${local.database_name}-final"

  tags = {
    Name = local.database_name
  }

  # A replaced security group must admit the cluster and the Client VPN
  # before the database switches to it.
  depends_on = [aws_vpc_security_group_ingress_rule.postgres]

  lifecycle {
    prevent_destroy = true
  }
}
