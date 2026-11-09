terraform {
  cloud {
    organization = "Femtum"

    workspaces {
      name = "cvat-rnd"
    }
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "5.100.0"
    }
  }

  required_version = ">= 1.10"
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      App       = local.name
      ManagedBy = "Terraform"
    }
  }
}
