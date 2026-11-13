# Locks where Argo CD runs CVAT and which Secrets Manager names its
# ExternalSecrets read: the platform's store only reaches k8s/<namespace>/*.
#
# The AWS and TFE providers are mocked and the platform contract is overridden,
# so the suite needs no credentials or Terraform Cloud access, creates nothing
# and costs nothing.

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
  target          = module.ingress.aws_lb_target_group.http
  override_during = plan
  values = {
    arn = "arn:aws:elasticloadbalancing:ca-central-1:111122223333:targetgroup/cvat-http/0123456789abcdef"
  }
}

run "given_the_rnd_environment_when_planned_then_cvat_runs_in_the_namespace_argo_cd_names_cvat_rnd" {
  command = plan

  variables {
    environment_name = "rnd"
  }

  assert {
    condition     = output.kubernetes_namespace == "cvat-rnd"
    error_message = "The ApplicationSet deploys deploy/cvat/values-rnd.yaml into cvat-rnd."
  }
}

run "given_the_rnd_environment_when_planned_then_the_database_user_is_read_from_k8s_cvat_rnd_database" {
  command = plan

  variables {
    environment_name = "rnd"
  }

  assert {
    condition     = output.database_secret_name == "k8s/cvat-rnd/database"
    error_message = "An ExternalSecret in cvat-rnd can only read k8s/cvat-rnd/*: the old k8s/cvat/database is out of its reach."
  }
}

run "given_the_dev_environment_when_planned_then_its_secrets_live_under_k8s_cvat_dev" {
  command = plan

  variables {
    environment_name = "dev"
  }

  assert {
    condition     = output.database_secret_name == "k8s/cvat-dev/database"
    error_message = "Each environment's namespace reads its own prefix: values-dev.yaml deploys into cvat-dev."
  }
}
