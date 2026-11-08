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
variable "node_count" {
  type = number
  validation {
    condition     = var.node_count >= 1 && var.node_count <= 3
    error_message = "node_count debe estar entre 1 y 3 para controlar el gasto."
  }
}
variable "cluster_role_arn" {
  type    = string
  default = null
}
variable "node_role_arn" {
  type    = string
  default = null
}
variable "ebs_csi_role_arn" {
  type    = string
  default = null
}
