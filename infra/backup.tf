locals {
  backup_retention_in_days = 35
}

resource "aws_backup_vault" "data" {
  name = "${local.name}-${var.environment_name}"
}

resource "aws_backup_plan" "data" {
  name = "${local.name}-data-${var.environment_name}"

  rule {
    rule_name         = "daily"
    target_vault_name = aws_backup_vault.data.name
    # 03:00 in Montréal in winter, 04:00 in summer: outside working hours.
    schedule = "cron(0 8 * * ? *)"

    lifecycle {
      delete_after = local.backup_retention_in_days
    }
  }
}

resource "aws_iam_role" "backup" {
  name = "${local.name}-backup-${var.environment_name}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "backup.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "backup" {
  for_each = toset([
    "arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForBackup",
    "arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForRestores",
  ])

  role       = aws_iam_role.backup.name
  policy_arn = each.value
}

resource "aws_backup_selection" "data" {
  name         = "${local.name}-data"
  plan_id      = aws_backup_plan.data.id
  iam_role_arn = aws_iam_role.backup.arn
  resources    = [aws_efs_file_system.data.arn]
}
