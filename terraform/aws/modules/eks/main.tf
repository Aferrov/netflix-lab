variable "name" { type = string }
variable "kubernetes_version" { type = string }
variable "subnet_ids" { type = list(string) }
variable "api_access_cidrs" { type = list(string) }
variable "node_instance_type" { type = string }
variable "node_count" { type = number }
variable "cluster_role_arn" {
  type = string
  validation {
    condition     = can(regex("^arn:aws:iam::[0-9]{12}:role/.+", var.cluster_role_arn))
    error_message = "Indica el ARN del rol precreado para el clúster EKS."
  }
}
variable "node_role_arn" {
  type = string
  validation {
    condition     = can(regex("^arn:aws:iam::[0-9]{12}:role/.+", var.node_role_arn)) && var.node_role_arn != var.cluster_role_arn
    error_message = "Indica un ARN de nodos EKS distinto del rol del clúster."
  }
}
variable "ebs_csi_role_arn" {
  type    = string
  default = null
}

resource "aws_eks_cluster" "this" {
  name     = var.name
  role_arn = var.cluster_role_arn
  version  = var.kubernetes_version

  access_config {
    authentication_mode                         = "API_AND_CONFIG_MAP"
    bootstrap_cluster_creator_admin_permissions = true
  }

  upgrade_policy { support_type = "STANDARD" }

  vpc_config {
    subnet_ids              = var.subnet_ids
    endpoint_private_access = true
    endpoint_public_access  = true
    public_access_cidrs     = var.api_access_cidrs
  }

  enabled_cluster_log_types = ["api", "audit", "authenticator"]
}

resource "aws_eks_node_group" "this" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "${var.name}-workers"
  node_role_arn   = var.node_role_arn
  subnet_ids      = var.subnet_ids
  instance_types  = [var.node_instance_type]
  capacity_type   = "ON_DEMAND"
  disk_size       = 20

  scaling_config {
    desired_size = var.node_count
    min_size     = var.node_count
    max_size     = var.node_count
  }

  update_config { max_unavailable = 1 }
}

resource "aws_eks_addon" "pod_identity" {
  count        = var.ebs_csi_role_arn == null ? 0 : 1
  cluster_name = aws_eks_cluster.this.name
  addon_name   = "eks-pod-identity-agent"
  depends_on   = [aws_eks_node_group.this]
}

resource "aws_eks_addon" "ebs_csi" {
  count        = var.ebs_csi_role_arn == null ? 0 : 1
  cluster_name = aws_eks_cluster.this.name
  addon_name   = "aws-ebs-csi-driver"
  pod_identity_association {
    role_arn        = var.ebs_csi_role_arn
    service_account = "ebs-csi-controller-sa"
  }
  depends_on = [aws_eks_addon.pod_identity]
}

resource "aws_eks_addon" "metrics_server" {
  cluster_name = aws_eks_cluster.this.name
  addon_name   = "metrics-server"
  depends_on   = [aws_eks_node_group.this]
}

output "cluster_name" { value = aws_eks_cluster.this.name }
output "cluster_endpoint" { value = aws_eks_cluster.this.endpoint }
output "ebs_addon_id" { value = var.ebs_csi_role_arn == null ? null : aws_eks_addon.ebs_csi[0].id }
