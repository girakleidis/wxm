data "aws_availability_zones" "available" {}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "5.5.2"

  name = "test-vpc"
  cidr = local.vpc_cidr

  azs             = slice(data.aws_availability_zones.available.names, 0, 2)
  private_subnets = slice(local.cidr_list, 0, 2)
  # database_subnets = slice(local.cidr_list, 1, 2)
  public_subnets = slice(local.cidr_list, 2, 4)

  create_igw           = true
  enable_dns_hostnames = true
  enable_dns_support   = true
  # enable_nat_gateway = true
  # enable_vpn_gateway = true

  tags = {
    Usage = "Devops test"
  }
}

data "aws_ami" "ubuntu" {
  most_recent = true
  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server*"]
  }
  owners = ["amazon"]
}

module "security_group" {
  source  = "terraform-aws-modules/security-group/aws"
  version = "5.1.0"

  name        = "ec2-security-group"
  description = "EC2 sg"
  vpc_id      = module.vpc.vpc_id

  ingress_with_source_security_group_id = [
    {
      # cidr_blocks = local.client_ip_list
      source_security_group_id = module.alb.security_group_id
      from_port                = 80
      protocol                 = "tcp"
      to_port                  = 80
    },
    # {
    #   cidr_blocks = local.ip_list
    #   from_port   = 22
    #   protocol    = "tcp"
    #   to_port     = 22
    # },
    # {
    #   cidr_blocks = "0.0.0.0/0"
    #   from_port   = -1
    #   protocol    = "icmp"
    #   to_port     = -1
    # }
  ]

  egress_with_cidr_blocks = [
    {
      cidr_blocks = "0.0.0.0/0"
      from_port   = 0
      protocol    = "-1"
      to_port     = 0
    }
  ]
}

module "ec2" {
  source  = "terraform-aws-modules/ec2-instance/aws"
  version = "5.6.0"

  name                        = "test-name"
  ignore_ami_changes          = true
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = "t3.micro"
  availability_zone           = element(module.vpc.azs, 0)
  subnet_id                   = element(module.vpc.public_subnets, 0)
  vpc_security_group_ids      = [module.security_group.security_group_id]
  associate_public_ip_address = true

  create_iam_instance_profile = true
  iam_role_description        = "IAM role for EC2 instance"
  iam_role_policies = {
    # AdministratorAccess = "arn:aws:iam::aws:policy/AdministratorAccess",
    AmazonSSMManagedInstanceCore = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
    S3policy                     = module.s3_policy.arn
  }

  user_data                   = <<EOF
#!/bin/bash
# Add Docker's official GPG key:
apt-get update
apt-get install ca-certificates curl
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc

# Add the repository to Apt sources:
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  tee /etc/apt/sources.list.d/docker.list > /dev/null
apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io mysql-client awscli

cat << EOFC > /checks
#!/bin/bash

#echo "Content-type: text/html"
aws s3 ls s3://${local.s3_name} >/dev/null 2>&1 && echo "S3 Bucket ${local.s3_name} is accessible." || echo "S3 Bucket ${local.s3_name} is not accessible." 
mysql -u${module.rds.cluster_master_username} -p"${module.rds.cluster_master_password}" -h ${module.rds.cluster_endpoint} -e "show databases;" >/dev/null 2>&1 && echo "RDS test-mysql is accessible." || echo "RDS test-mysql is not accessible."
EOFC

cat << EOFE > /entrypoint.sh
#!/bin/bash
while true; do echo -e "HTTP/1.1 200 OK\n\n\`/checks\`"  | nc -l -k -p 80 -q 1; done
EOFE

chmod +x /entrypoint.sh
chmod +x /checks

cat << EOFD > Dockerfile
FROM ubuntu

RUN apt update ; \
apt install -y mysql-client netcat curl unzip ; \
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip" ; \
unzip awscliv2.zip ; \
./aws/install

COPY entrypoint.sh checks /

CMD ["/entrypoint.sh"]
EOFD

docker build -t http .

docker run --name web -v /checks:/checks -p 80:80 http
EOF
  user_data_replace_on_change = true
}

module "alb" {
  source  = "terraform-aws-modules/alb/aws"
  version = "9.7.0"
  name    = "test-alb"
  vpc_id  = module.vpc.vpc_id
  subnets = module.vpc.public_subnets

  enable_deletion_protection = false

  # Security Group
  security_group_ingress_rules = {
    all_http = {
      from_port   = 80
      to_port     = 80
      ip_protocol = "tcp"
      description = "HTTP web traffic"
      cidr_ipv4   = "0.0.0.0/0"
    }
  }
  security_group_egress_rules = {
    all = {
      ip_protocol = "-1"
      cidr_ipv4   = "0.0.0.0/0"
    }
  }

  listeners = {
    l80 = {
      port     = 80
      protocol = "HTTP"
      forward = {
        target_group_key = "tg80"
      }
    }
  }

  target_groups = {
    tg80 = {
      # name_prefix                       = "h1"
      protocol    = "HTTP"
      port        = 80
      target_type = "instance"

      health_check = {
        enabled             = true
        interval            = 6
        path                = "/"
        port                = "traffic-port"
        healthy_threshold   = 2
        unhealthy_threshold = 2
        timeout             = 4
        protocol            = "HTTP"
        matcher             = "200"
      }

      # protocol_version = "HTTP1"
      # target_id        = module.ec2.id
      create_attachment = false
      # port             = 80

    }
  }

}

resource "aws_lb_target_group_attachment" "instance" {
  target_group_arn = module.alb.target_groups["tg80"].arn
  target_id        = module.ec2.id
}

module "rds" {
  source  = "terraform-aws-modules/rds-aurora/aws"
  version = "8.5.0"

  create_db_subnet_group      = true
  subnets                     = module.vpc.private_subnets
  is_primary_cluster          = true
  name                        = "test-mysql"
  master_username             = "muser"
  manage_master_user_password = false
  master_password             = "PAsssw0rd"
  engine_mode                 = "provisioned"
  engine                      = "aurora-mysql"
  engine_version              = "8.0.mysql_aurora.3.04.1"
  vpc_id                      = module.vpc.vpc_id
  create_security_group       = true
  security_group_rules = {
    ec2_ingress = {
      type                     = "ingress"
      from_port                = 3306
      to_port                  = 3306
      source_security_group_id = module.security_group.security_group_id
    }
  }
  enabled_cloudwatch_logs_exports = ["audit", "error", "slowquery"]
  skip_final_snapshot             = true
  deletion_protection             = false
  create_cloudwatch_log_group     = true
  instances = {
    1 = {
      instance_class = "db.t3.medium"
    }
  }
  # db_cluster_instance_class = "db.t3.medium"
  # allocated_storage         = 20
}

module "s3-bucket" {
  source  = "terraform-aws-modules/s3-bucket/aws"
  version = "4.1.0"
  bucket  = local.s3_name
}

data "aws_iam_policy_document" "s3_policy_document" {
  statement {
    actions = [
      "s3:PutObject",
      "s3:GetObject",
      "s3:DeleteObject",
      "s3:ListBucket"
    ]
    resources = [
      "${module.s3-bucket.s3_bucket_arn}*"
    ]
  }
}

module "s3_policy" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-policy"
  version = "5.34.0"
  policy  = data.aws_iam_policy_document.s3_policy_document.json
}