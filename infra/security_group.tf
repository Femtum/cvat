# Terraform drops the default egress rule, and NFS replies need none: the
# group is stateful. Its one admission is the cluster's own security group,
# which Auto Mode's nodes and pods carry.
resource "aws_security_group" "mount_targets" {
  name        = "${local.name}-data-mount-targets"
  description = "NFS to cvat_data from the Kubernetes cluster only"
  vpc_id      = module.platform.shared.vpc_id
}

resource "aws_vpc_security_group_ingress_rule" "nfs_from_cluster" {
  security_group_id = aws_security_group.mount_targets.id
  description       = "NFS from the Kubernetes cluster nodes and pods"

  referenced_security_group_id = module.platform.shared.kubernetes_cluster_security_group_id
  ip_protocol                  = "tcp"
  from_port                    = 2049
  to_port                      = 2049

  lifecycle {
    precondition {
      condition     = module.platform.shared.kubernetes_cluster_security_group_id != null
      error_message = "The platform workspace infrastructure-aws-${var.environment_name} runs no Kubernetes cluster: set is_kubernetes_cluster_enabled there first."
    }
  }
}
