# Locks where the office and Client VPN users reach CVAT. deploy.sh gives this
# host to the chart and to the Gateway's HTTPRoute.
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

variables {
  environment_name = "rnd"
}

run "given_the_rnd_platform_when_planned_then_cvat_answers_on_its_intranet_host_over_https" {
  command = plan

  assert {
    condition     = output.url == "https://cvat.rnd.intranet.femtum.com"
    error_message = "CVAT must answer on cvat.<intranet domain>, the host the office and the Client VPN resolve to the platform's Gateway, over HTTPS."
  }
}
