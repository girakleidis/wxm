locals {
  # client_ip_list = "141.237.27.81/32"
  vpc_cidr  = "192.168.0.0/24"
  cidr_list = cidrsubnets(local.vpc_cidr, 2, 2, 2, 2)
  s3_name   = "test-wxm-devops-bucket"
  region    = "eu-west-1"
}
