locals {
  # The namespace deploy/ installs the chart into. The platform's admission
  # policy only lets a SecretStore in namespace <ns> assume
  # role/external-secrets/<ns>-secrets-read, so the role name follows it.
  kubernetes_namespace = "cvat"

  # Created by hand, with its value: the password never enters Terraform state.
  # Secrets Manager appends a random six-character suffix to the name, and `?`
  # matches exactly one character in an IAM resource ARN, so this keeps working
  # when the secret is deleted and recreated with a different suffix. Naming the
  # live suffix instead would break External Secrets Operator with an opaque
  # AccessDenied the next time that happens.
  database_user_secret_id = "rds/cvat_database_user-??????"
}

data "aws_caller_identity" "current" {}

# External Secrets Operator's controller assumes this role for CVAT's
# SecretStore, then reads CVAT's database user secret and nothing else.
resource "aws_iam_role" "secrets_read" {
  name        = "${local.kubernetes_namespace}-secrets-read"
  path        = "/external-secrets/"
  description = "External Secrets Operator reads CVAT database user secret for namespace ${local.kubernetes_namespace}"

  # The account root, pinned to the controller by aws:PrincipalArn: naming the
  # controller role as the principal would fail while it does not exist, and
  # break silently if it were ever recreated. sts:TagSession carries Pod
  # Identity's transitive session tags; STS refuses the AssumeRole without it.
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
      Condition = {
        ArnEquals = { "aws:PrincipalArn" = module.platform.shared.eso_controller_role_arn }
      }
    }]
  })

  lifecycle {
    precondition {
      condition     = module.platform.shared.eso_controller_role_arn != null
      error_message = "The platform workspace infrastructure-aws-${var.environment_name} publishes no eso_controller_role_arn: it runs no Kubernetes cluster, or has not been applied since External Secrets Operator landed."
    }
  }
}

# The exact ARN, never a prefix: rds/ also holds lit's database user.
resource "aws_iam_role_policy" "secrets_read" {
  name = "read-own-secrets"
  role = aws_iam_role.secrets_read.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
      Resource = ["arn:aws:secretsmanager:${var.region}:${data.aws_caller_identity.current.account_id}:secret:${local.database_user_secret_id}"]
    }]
  })
}
