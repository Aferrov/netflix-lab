terraform {
  required_version = ">= 1.10.0"
  backend "s3" {
    use_lockfile = true
    encrypt      = true
  }
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.80, < 7.0"
    }
  }
}

provider "aws" {
  region = var.region
  default_tags {
    tags = {
      Project     = "netflix-lab"
      Environment = var.environment
      ManagedBy   = "terraform"
      Stack       = "platform"
    }
  }
}

locals { name = "netflix-lab-${var.environment}" }

module "network" {
  source              = "../modules/network"
  name                = local.name
  vpc_cidr            = var.vpc_cidr
  availability_zones  = var.availability_zones
  public_subnet_cidrs = var.public_subnet_cidrs
}

module "ecr" {
  source = "../modules/ecr"
  name   = local.name
}

resource "aws_cloudwatch_log_group" "eks" {
  name              = "/aws/eks/${local.name}/cluster"
  retention_in_days = 7
}

module "eks" {
  source             = "../modules/eks"
  name               = local.name
  kubernetes_version = var.kubernetes_version
  subnet_ids         = module.network.subnet_ids
  api_access_cidrs   = var.api_access_cidrs
  node_instance_type = var.node_instance_type
  node_count         = var.node_count
  cluster_role_arn   = var.cluster_role_arn
  node_role_arn      = var.node_role_arn
  ebs_csi_role_arn   = var.ebs_csi_role_arn
  depends_on         = [aws_cloudwatch_log_group.eks]
}

output "cluster_name" { value = module.eks.cluster_name }
output "cluster_endpoint" { value = module.eks.cluster_endpoint }
output "ecr_repository_urls" { value = module.ecr.repository_urls }
output "vpc_id" { value = module.network.vpc_id }
