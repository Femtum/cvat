locals {
  name = "cvat"
}

# Pinned to a commit of Femtum/Infrastructure.
module "platform" {
  source = "git::ssh://git@github.com/Femtum/Infrastructure.git//infrastructure-aws/modules/platform_contract?ref=cf3466fd6b63e705688615b7c589ec7ae6bb6c67"

  environment_name = var.environment_name
}
