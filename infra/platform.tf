locals {
  name = "cvat"
}

# Pinned to a commit of Femtum/Infrastructure.
module "platform" {
  source = "git::ssh://git@github.com/Femtum/Infrastructure.git//infrastructure-aws/modules/platform_contract?ref=c8c57d74d1e7d3890bfaa6317d6ea366eb075345"

  environment_name = var.environment_name
}
