remote_state {

  backend = "s3"
  generate = {
    path      = "backend.tf"
    if_exists = "overwrite_terragrunt"
  }

  config = {
    bucket = "devops_xmc_state_s3"
    key    = "xmc_state/terraform.tfstate"
    region = "eu-west-1"
  }
}