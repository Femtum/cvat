locals {
  name = "cvat"
}

# Pinned to a commit of Femtum/Infrastructure. Terraform only accepts a literal
# `source`, so bump the ref by hand once the platform publishes what is needed.
module "platform" {
  source = "git::ssh://git@github.com/Femtum/Infrastructure.git//infrastructure-aws/modules/platform_contract?ref=d5a5c3b92e254648d63d18edb2d6a454483041aa"

  environment_name = var.environment_name
}
