
locals {
  vpc_name           = "seoul-vpc"
  sin_vpc_name       = "singapore-vpc"
  cluster_name       = "seoul-eks"
  sin_cluster_name   = "singapore-eks"
  global_rds_cluster = "global-rds"
  region             = "ap-northeast-2"
}






#############################################################
# VPC 서울 리전
#############################################################


module "vpc1" {
  source = "terraform-aws-modules/vpc/aws"


  name = local.vpc_name
  cidr = "10.0.0.0/16"


  azs             = ["ap-northeast-2a", "ap-northeast-2b"]
  public_subnets  = ["10.0.1.0/24", "10.0.2.0/24"]
  private_subnets = ["10.0.11.0/24", "10.0.12.0/24", "10.0.21.0/24", "10.0.22.0/24"]


  enable_nat_gateway = true
  single_nat_gateway = true


  enable_dns_hostnames = true


  public_subnet_names  = ["public_subnet_1", "public_subnet_2"]
  private_subnet_names = ["private_subnet_1", "private_subnet_2", "private_subnet_3", "private_subnet_4"]


  public_subnet_tags = {
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
    "kubernetes.io/role/elb"                      = "1"
  }


  private_subnet_tags = {
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
    "kubernetes.io/role/internal-elb"             = "1"
  }
}


#############################################################






#############################################################
# VPC 싱가포르 리전
#############################################################


module "vpc2" {
  providers = {
    aws = aws.singapore
  }
  source = "terraform-aws-modules/vpc/aws"
  name   = local.sin_vpc_name
  cidr   = "10.10.0.0/16"


  azs             = ["ap-southeast-1a", "ap-southeast-1b"]
  public_subnets  = ["10.10.1.0/24", "10.10.2.0/24"]
  private_subnets = ["10.10.11.0/24", "10.10.12.0/24", "10.10.21.0/24", "10.10.22.0/24"]


  enable_nat_gateway = true
  single_nat_gateway = true


  enable_dns_hostnames = true


  public_subnet_names  = ["singapore_public_subnet_1"]
  private_subnet_names = ["singapore_private_subnet_1", "singapore_private_subnet_2", "singapore_private_subnet_3", "singapore_private_subnet_4"]


  public_subnet_tags = {
    "kubernetes.io/cluster/${local.sin_cluster_name}" = "shared"
    "kubernetes.io/role/elb"                          = "1"
  }


  private_subnet_tags = {
    "kubernetes.io/cluster/${local.sin_cluster_name}" = "shared"
    "kubernetes.io/role/internal-elb"                 = "1"
  }
}


#############################################################






#############################################################
# VPC 피어링 연결
#############################################################


resource "aws_vpc_peering_connection" "pjconnect" {
  peer_vpc_id = module.vpc2.vpc_id
  vpc_id      = module.vpc1.vpc_id
  peer_region = "ap-southeast-1"


  tags = {
    Name = "VPC Peering connection"
  }
}




resource "aws_vpc_peering_connection_accepter" "pjconnect_ac" {
  provider                  = aws.singapore
  vpc_peering_connection_id = aws_vpc_peering_connection.pjconnect.id
  auto_accept               = true


  tags = {
    Name = "VPC-Peering-accept"
  }
}


resource "aws_route" "Seoul_public_peering_route" {
  route_table_id            = module.vpc1.public_route_table_ids[0]
  destination_cidr_block    = module.vpc2.vpc_cidr_block
  vpc_peering_connection_id = aws_vpc_peering_connection.pjconnect.id
}


resource "aws_route" "Seoul_private_peering_route" {
  route_table_id            = module.vpc1.private_route_table_ids[0]
  destination_cidr_block    = module.vpc2.vpc_cidr_block
  vpc_peering_connection_id = aws_vpc_peering_connection.pjconnect.id
}


resource "aws_route" "Singapore_Public_peering_route" {
  provider                  = aws.singapore
  route_table_id            = module.vpc2.public_route_table_ids[0]
  destination_cidr_block    = module.vpc1.vpc_cidr_block
  vpc_peering_connection_id = aws_vpc_peering_connection.pjconnect.id
}


resource "aws_route" "Singapore_Private_peering_route" {
  provider                  = aws.singapore
  route_table_id            = module.vpc2.private_route_table_ids[0]
  destination_cidr_block    = module.vpc1.vpc_cidr_block
  vpc_peering_connection_id = aws_vpc_peering_connection.pjconnect.id
}
#############################################################






#############################################################
# 서울 리전 EKS
#############################################################


module "eks" {
  source = "terraform-aws-modules/eks/aws"


  cluster_name                    = local.cluster_name
  cluster_version                 = "1.27"
  cluster_endpoint_private_access = false
  cluster_endpoint_public_access  = true


  vpc_id     = module.vpc1.vpc_id
  subnet_ids = [module.vpc1.private_subnets[2], module.vpc1.private_subnets[3]]


  cloudwatch_log_group_retention_in_days = 1


  fargate_profiles = {
    default = {
      name = "default"
      selectors = [
        {
          namespace = "kube-system"
        },
        {
          namespace = "default"
        }
      ]
    },
    videostream = {
      name = "videostream"
      selectors = [
        {
          namespace = "videostream"
        }
      ]
    },
  }
}


#############################################################






#############################################################
# 싱가포르 리전 EKS
#############################################################


module "eks2" {
  providers = {
    aws = aws.singapore
  }
  source = "terraform-aws-modules/eks/aws"


  cluster_name                    = local.sin_cluster_name
  cluster_version                 = "1.27"
  cluster_endpoint_private_access = false
  cluster_endpoint_public_access  = true


  vpc_id     = module.vpc2.vpc_id
  subnet_ids = [module.vpc2.private_subnets[0], module.vpc2.private_subnets[1]]


  cloudwatch_log_group_retention_in_days = 1


  fargate_profiles = {
    default = {
      name = "default"
      selectors = [
        {
          namespace = "kube-system"
        },
        {
          namespace = "default"
        }
      ]
    },
    videostream = {
      name = "videostream"
      selectors = [
        {
          namespace = "videostream"
        }
      ]
    },
  }
}


#############################################################






#############################################################
# RDS
#############################################################


resource "aws_kms_key" "primary" {
  description             = "Multi-Region primary key"
  deletion_window_in_days = 30
  multi_region            = true
}


resource "aws_kms_replica_key" "singapore_rds_key" {
  provider = aws.singapore


  description             = "Multi-Region replica key"
  deletion_window_in_days = 7
  primary_key_arn         = aws_kms_key.primary.arn
}


resource "aws_rds_global_cluster" "global" {
  global_cluster_identifier = local.global_rds_cluster
  engine                    = "aurora-postgresql"
  engine_version            = "14.5"
  database_name             = "postgresqldb"
  storage_encrypted         = true
}




module "cluster" {
  source = "terraform-aws-modules/rds-aurora/aws"


  name                      = "seoul-cluster"
  engine                    = "aurora-postgresql"
  engine_version            = "14.5"
  global_cluster_identifier = aws_rds_global_cluster.global.id


  database_name               = "test1"
  master_username             = "postgres"
  master_password             = "password"
  manage_master_user_password = false


  instance_class = "db.r6g.large"
  instances = {
    1 = {}
    2 = {}
  }


  vpc_id                 = module.vpc1.vpc_id
  create_db_subnet_group = true
  subnets                = [module.vpc1.private_subnets[2], module.vpc1.private_subnets[3]]
  security_group_rules = {
    ingress1 = {
      cidr_blocks = ["10.0.0.0/16"]
    }
    ingress2 = {
      cidr_blocks = ["10.10.0.0/16"]
    }
  }


  storage_encrypted   = true
  kms_key_id          = aws_kms_key.primary.arn
  apply_immediately   = true
  skip_final_snapshot = true
}


module "cluster2" {
  source = "terraform-aws-modules/rds-aurora/aws"


  providers = {
    aws = aws.singapore
  }


  is_primary_cluster            = false
  replication_source_identifier = module.cluster.cluster_arn
  name                          = "singapore-cluster"
  engine                        = "aurora-postgresql"
  engine_version                = "14.5"
  global_cluster_identifier     = aws_rds_global_cluster.global.id
  source_region                 = local.region


  database_name               = "test1"
  master_username             = "postgres"
  master_password             = "password"
  manage_master_user_password = false


  instance_class = "db.r6g.large"
  instances = {
    1 = {}
  }


  vpc_id                 = module.vpc2.vpc_id
  create_db_subnet_group = true
  subnets                = [module.vpc2.private_subnets[2], module.vpc2.private_subnets[3]]
  security_group_rules = {
    ingress1 = {
      cidr_blocks = ["10.0.0.0/16"]
    }
    ingress2 = {
      cidr_blocks = ["10.10.0.0/16"]
    }
  }


  storage_encrypted   = true
  kms_key_id          = aws_kms_replica_key.singapore_rds_key.arn
  apply_immediately   = true
  skip_final_snapshot = true
}


#############################################################






#############################################################
# S3 & ECR
#############################################################


resource "aws_s3_bucket" "my-bucket" {
  bucket = "video-bucket-gtth"


  force_destroy = true


  tags = {
    Name        = "My bucket"
    Environment = "Dev"
  }
}


resource "aws_ecr_repository" "my_ecr" {
  name                 = "my_web"
  image_tag_mutability = "MUTABLE"


  force_delete = true


  image_scanning_configuration {
    scan_on_push = true
  }
}


#############################################################






#############################################################
# EFS
#############################################################
module "efs1" {
  source = "terraform-aws-modules/efs/aws"


  # File system
  name           = "seoul-efs"
  creation_token = "seoul-efs-token"
  encrypted      = true


  lifecycle_policy = {
    transition_to_ia = "AFTER_30_DAYS"
  }


  attach_policy = false


  # Mount targets / security group
  mount_targets = {
    "ap-northeast-2a" = {
      subnet_id = module.vpc1.private_subnets[0]
    }
    "ap-northeast-2b" = {
      subnet_id = module.vpc1.private_subnets[1]
    }
    # "ap-southeast-1" = {
    #   subnet_id = module.vpc2.private_subnets[0]
    # }
  }
  security_group_description = "Example EFS security group"
  security_group_vpc_id      = module.vpc1.vpc_id
  security_group_rules = {
    vpc = {
      # relying on the defaults provdied for EFS/NFS (2049/TCP + ingress)
      description = "NFS ingress from VPC private subnets"
      cidr_blocks = [module.vpc1.vpc_cidr_block, module.vpc2.vpc_cidr_block]
    }
  }


  # Backup policy
  enable_backup_policy = true
}


module "efs2" {
  source = "terraform-aws-modules/efs/aws"


  providers = {
    aws = aws.singapore
  }


  # File system
  name           = "singapore-efs"
  creation_token = "singapore-efs-token"
  encrypted      = true


  lifecycle_policy = {
    transition_to_ia = "AFTER_30_DAYS"
  }


  attach_policy = false


  # Mount targets / security group
  mount_targets = {
    "ap-southeast-1a" = {
      subnet_id = module.vpc2.private_subnets[0]
    }
    "ap-southeast-1b" = {
      subnet_id = module.vpc2.private_subnets[1]
    }
  }
  security_group_description = "Example EFS security group"
  security_group_vpc_id      = module.vpc2.vpc_id
  security_group_rules = {
    vpc = {
      # relying on the defaults provdied for EFS/NFS (2049/TCP + ingress)
      description = "NFS ingress from VPC private subnets"
      cidr_blocks = [module.vpc1.vpc_cidr_block, module.vpc2.vpc_cidr_block]
    }
  }


  # Backup policy
  enable_backup_policy = true
}
#############################################################



#############################################################
# CI/CD
#############################################################


# CodeBuild 역할 생성
resource "aws_iam_role" "codebuild_role" {
  name = "codebuild-role"


  assume_role_policy = <<-EOF
  {
    "Version": "2012-10-17",
    "Statement": [
      {
        "Effect": "Allow",
        "Principal": {
          "Service": "codebuild.amazonaws.com"
        },
        "Action": "sts:AssumeRole"
      }
    ]
  }
  EOF
}



# ECS FullAccess 정책
data "aws_iam_policy" "ECS_FullAccess" {
  name = "AmazonEC2ContainerRegistryFullAccess"
}


# ECS FullAccess 정책 연결
resource "aws_iam_role_policy_attachment" "attach1" {
  role       = aws_iam_role.codebuild_role.name
  policy_arn = data.aws_iam_policy.ECS_FullAccess.arn
}


# S3 FullAccess 정책
data "aws_iam_policy" "S3_FullAccess" {
  name = "AmazonS3FullAccess"
}


# S3 FullAccess 정책 연결
resource "aws_iam_role_policy_attachment" "attach2" {
  role       = aws_iam_role.codebuild_role.name
  policy_arn = data.aws_iam_policy.S3_FullAccess.arn
}
# CodeBuild Project 생성
resource "aws_codebuild_project" "my_build" {
  name         = "my-build-project"
  description  = "test my build project"
  service_role = aws_iam_role.codebuild_role.arn


  artifacts {
    type = "NO_ARTIFACTS"
  }


  environment {
    compute_type                = "BUILD_GENERAL1_SMALL"
    image                       = "aws/codebuild/amazonlinux2-x86_64-standard:4.0"
    type                        = "LINUX_CONTAINER"
    image_pull_credentials_type = "CODEBUILD"
    privileged_mode             = true
  }


  logs_config {
    cloudwatch_logs {
      status = "DISABLED"
    }
    s3_logs {
      status = "DISABLED"
    }
  }


  source {
    type            = "GITHUB"
    location        = "####"
    git_clone_depth = 1
  }
}
