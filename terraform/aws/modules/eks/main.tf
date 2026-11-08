variable "name" { type = string }
variable "kubernetes_version" { type = string }
variable "subnet_ids" { type = list(string) }
variable "api_access_cidrs" { type = list(string) }
variable "node_instance_type" { type = string }
variable "node_count" { type = number }
variable "cluster_role_arn" {
  type    = string
  default = null
}
variable "node_role_arn" {
  type    = string
  default = null
  validation {
    condition     = var.node_role_arn == null || var.cluster_role_arn == null || var.node_role_arn != var.cluster_role_arn
    error_message = "El rol de los nodos EKS debe ser distinto del rol del clúster."
  }
}
variable "ebs_csi_role_arn" {
  type    = string
  default = null
}

data "aws_iam_policy_document" "cluster_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "node_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "pod_assume" {
  statement {
    actions = ["sts:AssumeRole", "sts:TagSession"]
    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "cluster" {
  count              = var.cluster_role_arn == null ? 1 : 0
  name               = "${var.name}-cluster"
  assume_role_policy = data.aws_iam_policy_document.cluster_assume.json
}

resource "aws_iam_role_policy_attachment" "cluster" {
  count      = var.cluster_role_arn == null ? 1 : 0
  role       = aws_iam_role.cluster[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

resource "aws_iam_role" "node" {
  count              = var.node_role_arn == null ? 1 : 0
  name               = "${var.name}-node"
  assume_role_policy = data.aws_iam_policy_document.node_assume.json
}

locals {
  node_policies = {
    worker = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
    cni    = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
    ecr    = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPullOnly"
  }
  cluster_role = var.cluster_role_arn != null ? var.cluster_role_arn : aws_iam_role.cluster[0].arn
  node_role    = var.node_role_arn != null ? var.node_role_arn : aws_iam_role.node[0].arn
  ebs_role     = var.ebs_csi_role_arn != null ? var.ebs_csi_role_arn : aws_iam_role.ebs_csi[0].arn
}

resource "aws_iam_role_policy_attachment" "node" {
  for_each   = var.node_role_arn == null ? local.node_policies : {}
  role       = aws_iam_role.node[0].name
  policy_arn = each.value
}

resource "aws_iam_role" "ebs_csi" {
  count              = var.ebs_csi_role_arn == null ? 1 : 0
  name               = "${var.name}-ebs-csi"
  assume_role_policy = data.aws_iam_policy_document.pod_assume.json
}

resource "aws_iam_role_policy_attachment" "ebs_csi" {
  count      = var.ebs_csi_role_arn == null ? 1 : 0
  role       = aws_iam_role.ebs_csi[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

resource "aws_eks_cluster" "this" {
  name     = var.name
  role_arn = local.cluster_role
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
  depends_on                = [aws_iam_role_policy_attachment.cluster]
}

resource "aws_eks_node_group" "this" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "${var.name}-workers"
  node_role_arn   = local.node_role
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
  depends_on = [aws_iam_role_policy_attachment.node]
}

resource "aws_eks_addon" "pod_identity" {
  cluster_name = aws_eks_cluster.this.name
  addon_name   = "eks-pod-identity-agent"
  depends_on   = [aws_eks_node_group.this]
}

resource "aws_eks_addon" "ebs_csi" {
  cluster_name = aws_eks_cluster.this.name
  addon_name   = "aws-ebs-csi-driver"
  pod_identity_association {
    role_arn        = local.ebs_role
    service_account = "ebs-csi-controller-sa"
  }
  depends_on = [aws_eks_addon.pod_identity, aws_iam_role_policy_attachment.ebs_csi]
}

resource "aws_eks_addon" "metrics_server" {
  cluster_name = aws_eks_cluster.this.name
  addon_name   = "metrics-server"
  depends_on   = [aws_eks_node_group.this]
}

output "cluster_name" { value = aws_eks_cluster.this.name }
output "cluster_endpoint" { value = aws_eks_cluster.this.endpoint }
output "ebs_addon_id" { value = aws_eks_addon.ebs_csi.id }
