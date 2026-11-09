variable "region" { type = string }
variable "environment" {
  type = string
  validation {
    condition     = contains(["dev", "prod"], var.environment)
    error_message = "El entorno debe ser dev o prod."
  }
}
variable "vpc_cidr" { type = string }
variable "availability_zones" {
  type = list(string)
  validation {
    condition     = length(var.availability_zones) >= 2
    error_message = "EKS requiere subredes en al menos dos zonas de disponibilidad."
  }
}
variable "public_subnet_cidrs" {
  type = list(string)
  validation {
    condition     = length(var.public_subnet_cidrs) >= 2
    error_message = "Se requieren al menos dos CIDR de subred pública."
  }
}
variable "api_access_cidrs" {
  description = "CIDR de la IP de administración, por ejemplo 198.51.100.10/32"
  type        = list(string)
  validation {
    condition     = length(var.api_access_cidrs) > 0 && alltrue([for cidr in var.api_access_cidrs : cidr != "0.0.0.0/0"])
    error_message = "Indica al menos un CIDR de administración; no uses 0.0.0.0/0."
  }
}
variable "kubernetes_version" { type = string }
variable "node_instance_type" { type = string }
variable "node_disk_size" {
  description = "Disco EBS de cada nodo, en GiB"
  type        = number
  default     = 20
  validation {
    condition     = var.node_disk_size >= 20 && floor(var.node_disk_size) == var.node_disk_size
    error_message = "node_disk_size debe ser un entero de al menos 20 GiB."
  }
}
variable "log_retention_days" {
  description = "Retención de logs del control plane"
  type        = number
  default     = 7
  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90], var.log_retention_days)
    error_message = "Usa una retención de 1, 3, 5, 7, 14, 30, 60 o 90 días."
  }
}
variable "node_count" {
  type = number
  validation {
    condition     = var.node_count >= 1 && var.node_count <= 3
    error_message = "node_count debe estar entre 1 y 3 para controlar el gasto."
  }
}
variable "cluster_role_arn" {
  description = "ARN del rol EKS Cluster precreado en Learner Lab"
  type        = string
}
variable "node_role_arn" {
  description = "ARN del rol EKS Node precreado en Learner Lab"
  type        = string
}
variable "ebs_csi_role_arn" {
  description = "ARN opcional de un rol existente para EBS CSI Pod Identity"
  type        = string
  default     = null
}
