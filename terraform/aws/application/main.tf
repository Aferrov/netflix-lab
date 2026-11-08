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
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.35, < 3.0"
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
      Stack       = "application"
    }
  }
}

locals {
  cluster_name = "netflix-lab-${var.environment}"
}

data "aws_eks_cluster" "this" { name = local.cluster_name }
data "aws_eks_addon" "ebs_csi" {
  count        = var.redis_persistence_enabled ? 1 : 0
  cluster_name = local.cluster_name
  addon_name   = "aws-ebs-csi-driver"
}
data "aws_ecr_repository" "backend" { name = "${local.cluster_name}/backend" }
data "aws_ecr_repository" "frontend" { name = "${local.cluster_name}/frontend" }
data "aws_ecr_image" "backend" {
  repository_name = data.aws_ecr_repository.backend.name
  image_tag       = var.image_tag
}
data "aws_ecr_image" "frontend" {
  repository_name = data.aws_ecr_repository.frontend.name
  image_tag       = var.image_tag
}

provider "kubernetes" {
  host                   = data.aws_eks_cluster.this.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.this.certificate_authority[0].data)
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", local.cluster_name, "--region", var.region]
  }
}

resource "kubernetes_storage_class_v1" "gp3" {
  count = var.redis_persistence_enabled ? 1 : 0
  metadata { name = "netflix-lab-gp3" }
  storage_provisioner    = "ebs.csi.aws.com"
  volume_binding_mode    = "WaitForFirstConsumer"
  allow_volume_expansion = true
  parameters = {
    type      = "gp3"
    encrypted = "true"
  }
}

module "application" {
  source                         = "../../modules/application"
  namespace                      = "netflix-lab"
  environment                    = var.environment
  backend_min_replicas           = var.backend_min_replicas
  backend_max_replicas           = var.backend_max_replicas
  backend_target_cpu_utilization = 50
  frontend_replicas              = var.frontend_replicas
  enable_loadtest_job            = var.enable_loadtest_job
  backend_image                  = "${data.aws_ecr_repository.backend.repository_url}@${data.aws_ecr_image.backend.image_digest}"
  frontend_image                 = "${data.aws_ecr_repository.frontend.repository_url}@${data.aws_ecr_image.frontend.image_digest}"
  redis_storage_class_name       = var.redis_persistence_enabled ? kubernetes_storage_class_v1.gp3[0].metadata[0].name : null
  redis_storage_size             = "1Gi"
  redis_persistence_enabled      = var.redis_persistence_enabled
  depends_on = [
    data.aws_eks_addon.ebs_csi,
    data.aws_ecr_image.backend,
    data.aws_ecr_image.frontend,
  ]
}

output "cluster_name" { value = local.cluster_name }
output "namespace" { value = module.application.namespace }
output "dashboard_port_forward_cmd" {
  value = "kubectl --context ${data.aws_eks_cluster.this.arn} -n ${module.application.namespace} port-forward svc/${module.application.frontend_service_name} 8080:80"
}
