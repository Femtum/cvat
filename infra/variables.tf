variable "environment_name" {
  description = "Platform environment to deploy into, e.g. rnd"
  type        = string
}

variable "region" {
  type    = string
  default = "ca-central-1"
}
