provider "aws" {
  region = local.region
}

terraform {
  backend "s3" {
    bucket = "terraform-state-final-task"
    key    = "terraform.tfstate"
    region = "us-east-1"
  }
}

data "aws_availability_zones" "available" {}



################################################################################
# Access keys
################################################################################

resource "random_password" "db_password" {
  length  = 16
  special = true
}

resource "random_id" "secret_suffix" {
  byte_length = 8
}

resource "aws_secretsmanager_secret" "rds_password" {
  name        = "${local.name}-rds-password-${random_id.secret_suffix.hex}"
  description = "RDS credentials for MySQL database"
}

resource "aws_secretsmanager_secret_version" "rds_password_version" {
  secret_id     = aws_secretsmanager_secret.rds_password.id
  secret_string = jsonencode({
    username = "admin"
    password = "AdminAdmin123"
  })
}

################################################################################
# RDS Module
################################################################################

module "db" {
  source = "terraform-aws-modules/rds/aws"

  identifier = local.name

  engine               = "mysql"
  engine_version       = "8.0"
  family               = "mysql8.0" 
  major_engine_version = "8.0"      
  instance_class       = "db.t3.micro"

  allocated_storage     = 20
  max_allocated_storage = 100

  db_name  = "completeMysql"
  username = jsondecode(aws_secretsmanager_secret_version.rds_password_version.secret_string).username
  password = jsondecode(aws_secretsmanager_secret_version.rds_password_version.secret_string).password
  manage_master_user_password = false
  port     = 3306

  multi_az               = false
  db_subnet_group_name   = module.vpc.database_subnet_group
  vpc_security_group_ids = [module.rds_security_group.security_group_id]

  maintenance_window              = "Mon:00:00-Mon:03:00"
  backup_window                   = "03:00-06:00"
  enabled_cloudwatch_logs_exports = ["general"]
  create_cloudwatch_log_group     = true

  skip_final_snapshot = true
  deletion_protection = false

  parameters = [
    {
      name  = "character_set_client"
      value = "utf8mb4"
    },
    {
      name  = "character_set_server"
      value = "utf8mb4"
    }
  ]

  tags = local.tags
  db_instance_tags = {
    "Sensitive" = "high"
  }
  db_option_group_tags = {
    "Sensitive" = "low"
  }
  db_parameter_group_tags = {
    "Sensitive" = "low"
  }
  db_subnet_group_tags = {
    "Sensitive" = "high"
  }
  cloudwatch_log_group_tags = {
    "Sensitive" = "high"
  }

 storage_encrypted = false
 kms_key_id = null

}


################################################################################
# Supporting Resources
################################################################################

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = local.name
  cidr = local.vpc_cidr

  azs              = local.azs
  public_subnets   = [cidrsubnet(local.vpc_cidr, 8, 0), cidrsubnet(local.vpc_cidr, 8, 1), cidrsubnet(local.vpc_cidr, 8, 5), cidrsubnet(local.vpc_cidr, 8, 6)]
  private_subnets  = [cidrsubnet(local.vpc_cidr, 8, 2)]
  database_subnets = [cidrsubnet(local.vpc_cidr, 8, 3), cidrsubnet(local.vpc_cidr, 8, 4)]

  create_database_subnet_group = true
  create_igw = true
  create_multiple_public_route_tables = true

  enable_nat_gateway = true
  single_nat_gateway = true
  one_nat_gateway_per_az = false

  tags = local.tags
}

module "security_group" {
  source  = "terraform-aws-modules/security-group/aws"
  version = "~> 5.0"

  name        = local.name
  description = "Security group allowing access on HTTP, HTTPS, SSH, and custom Node.js port"
  vpc_id      = module.vpc.vpc_id

  # Ingress rules
  ingress_with_cidr_blocks = [
    # Allow SSH access
    {
      from_port   = 22
      to_port     = 22
      protocol    = "tcp"
      description = "SSH access"
      cidr_blocks = "0.0.0.0/0"  # String, not a list
    },
    # Allow HTTPS access (port 443)
    {
      from_port   = 443
      to_port     = 443
      protocol    = "tcp"
      description = "HTTPS access"
      cidr_blocks = "0.0.0.0/0"
    },
    # Allow HTTP access (port 80)
    {
      from_port   = 80
      to_port     = 80
      protocol    = "tcp"
      description = "HTTP access"
      cidr_blocks = "0.0.0.0/0"
    },
    # Allow access to port 3030 for my Node.js app
    {
      from_port   = 3030
      to_port     = 3030
      protocol    = "tcp"
      description = "Node.js app access"
      cidr_blocks = "0.0.0.0/0"
    },
  ]

  # Explicit egress rules
  egress_with_cidr_blocks = [
    {
      from_port   = 0
      to_port     = 0
      protocol    = "-1"  # Allows all protocols
      description = "Allow all outbound traffic"
      cidr_blocks = "0.0.0.0/0"
    },
  ]

  tags = local.tags
  
}

module "rds_security_group" {
  source  = "terraform-aws-modules/security-group/aws"
  version = "~> 5.0"

  name        = "rds-security-group"
  description = "Security group for RDS MySQL Database"
  vpc_id      = module.vpc.vpc_id

  # Ingress rule to allow MySQL access from the public security group
  ingress_with_cidr_blocks = [
    {
      from_port   = 3306
      to_port     = 3306
      protocol    = "tcp"
      description = "Allow MySQL access from public instances"
      cidr_blocks = "0.0.0.0/0"
    }
  ]

  tags = local.tags
}

module "back_security_group" {
  source  = "terraform-aws-modules/security-group/aws"
  version = "~> 5.0"

  name        = "back_security_group"
  description = "Security group for Backend to the Database"
  vpc_id      = module.vpc.vpc_id

  # Ingress rule to allow MySQL access from the public security group
  ingress_with_cidr_blocks = [
    {
      from_port   = 22
      to_port     = 22
      protocol    = "tcp"
      description = "SSH access"
      cidr_blocks = "0.0.0.0/0" # module.ec2_instance["Bastion"].private_ip
    },
    # Allow HTTPS access (port 443)
    {
      from_port   = 443
      to_port     = 443
      protocol    = "tcp"
      description = "HTTPS access"
      cidr_blocks = "0.0.0.0/0"
    },
    # Allow HTTP access (port 80)
    {
      from_port   = 80
      to_port     = 80
      protocol    = "tcp"
      description = "HTTP access"
      cidr_blocks = "0.0.0.0/0"
    },
    # Allow access to port 3000 for the Node.js app
    {
      from_port   = 3000
      to_port     = 3000
      protocol    = "tcp"
      description = "Node.js app access backend"
      cidr_blocks = "0.0.0.0/0"
    }
    
  ]

    egress_with_cidr_blocks = [
    {
      from_port   = 0
      to_port     = 0
      protocol    = "-1"  # Allows all protocols
      description = "Allow all outbound traffic"
      cidr_blocks = "0.0.0.0/0"
    },
    {
      from_port   = 3306
      to_port     = 3306
      protocol    = "tcp"
      description = "Allow outbound MySQL traffic"
      cidr_blocks = "0.0.0.0/0"
    }
  ]

  tags = local.tags
}

module "load_security_group" {
  source  = "terraform-aws-modules/security-group/aws"
  version = "~> 5.0"

  name        = local.name
  description = "LoadBalancer"
  vpc_id      = module.vpc.vpc_id

  # Ingress rules
  ingress_with_cidr_blocks = [
    # Allow HTTPS access (port 443)
    {
      from_port   = 443
      to_port     = 443
      protocol    = "tcp"
      description = "HTTPS access"
      cidr_blocks = "0.0.0.0/0"
    },
    # Allow HTTP access (port 80)
    {
      from_port   = 80
      to_port     = 80
      protocol    = "tcp"
      description = "HTTP access"
      cidr_blocks = "0.0.0.0/0"
    },
    # Allow access to port 3000 for the Node.js app
    {
      from_port   = 3000
      to_port     = 3000
      protocol    = "tcp"
      description = "Node.js app access backend"
      cidr_blocks = "0.0.0.0/0"
    }
  ]

  # Explicit egress rules
  egress_with_cidr_blocks = [
    {
      from_port   = 0
      to_port     = 0
      protocol    = "-1"  # Allows all protocols
      description = "Allow all outbound traffic"
      cidr_blocks = "0.0.0.0/0"
    },
  ]

  tags = local.tags
  
}

################################################################################
# EC2 Instances
################################################################################

module "ec2" {
  source = "./modules/ec2"

  key_name        = "user1"
  public_key_path = "~/.ssh/user1.pub"
  ami_id          = "ami-084568db4383264d4"
  instance_type   = "t2.micro"

  security_groups = {
    "Frontend" = [module.security_group.security_group_id]
    "Backend"  = [module.back_security_group.security_group_id]
    "Bastion"  = [module.security_group.security_group_id]
  }

  subnets = {
    "Frontend" = module.vpc.public_subnets[0]
    "Backend"  = module.vpc.private_subnets[0]
    "Bastion"  = module.vpc.public_subnets[1]
  }
}

################################################################################
# Application Load Balancer
################################################################################

module "load_balancer" {
  source = "./modules/load_balancer"  # Path to the load balancer module

  name                     = "my-alb"
  security_groups          = [module.load_security_group.security_group_id]
  subnets                  = [module.vpc.public_subnets[2], module.vpc.public_subnets[3]]
  enable_deletion_protection = false
  tags                     = {
    Name = "whiz-alb"
  }

  target_group_name        = "my-target-group"
  target_group_port        = 3000
  target_group_protocol    = "HTTP"
  vpc_id                   = module.vpc.vpc_id
  listener_port            = 80
  listener_protocol        = "HTTP"
  target_id                = module.ec2_instance["Backend"].id
}
