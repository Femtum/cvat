locals {
  name = "cvat"

  # Traefik's `web` entrypoint in the pod, where the ALB sends requests and
  # health checks. Traefik splits them between CVAT's frontend, backend and
  # analytics by path.
  traefik_web_port = 8000
}

# Pinned to a commit of Femtum/Infrastructure. Terraform only accepts a literal
# `source`, so both modules repeat the ref: bump them together, app_ingress
# takes platform_contract's output.
module "platform" {
  source = "git::ssh://git@github.com/Femtum/Infrastructure.git//infrastructure-aws/modules/platform_contract?ref=3ae7fe7de569a752c6bc599427c12231a64665e5"

  environment_name = var.environment_name
}

module "ingress" {
  source = "git::ssh://git@github.com/Femtum/Infrastructure.git//infrastructure-aws/modules/app_ingress?ref=3ae7fe7de569a752c6bc599427c12231a64665e5"

  name     = local.name
  platform = module.platform.shared
  # Claimed after prod-bench-api's 20 on the shared HTTPS listener.
  rule_priority     = 30
  target_port       = local.traefik_web_port
  health_check_path = "/ping"
}
