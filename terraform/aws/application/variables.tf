variable "region" { type = string }
variable "cluster_name" {
  description = "Contrato con platform; null conserva el nombre por entorno"
  type        = string
  default     = null
}
variable "backend_repository_name" {
  type    = string
  default = null
}
variable "frontend_repository_name" {
  type    = string
  default = null
}
variable "backend_target_cpu_utilization" {
  type    = number
  default = 50
  validation {
    condition     = var.backend_target_cpu_utilization > 0 && var.backend_target_cpu_utilization <= 100
    error_message = "El objetivo CPU debe ser mayor que cero y como máximo 100."
  }
}
variable "redis_storage_size" {
  type    = string
  default = "1Gi"
}
variable "environment" {
  type = string
  validation {
    condition     = contains(["dev", "prod"], var.environment)
    error_message = "El entorno debe ser dev o prod."
  }
}
variable "image_tag" {
  description = "Tag inmutable de ambas imágenes publicadas en ECR"
  type        = string
  validation {
    condition     = length(var.image_tag) > 0 && var.image_tag != "latest"
    error_message = "Usa un tag inmutable distinto de latest."
  }
}
variable "backend_min_replicas" {
  type = number
  validation {
    condition     = var.backend_min_replicas >= 1
    error_message = "Se requiere al menos una réplica del backend."
  }
}
variable "backend_max_replicas" {
  type = number
  validation {
    condition     = var.backend_max_replicas >= var.backend_min_replicas
    error_message = "El máximo del HPA debe ser mayor o igual al mínimo."
  }
}
variable "frontend_replicas" {
  type = number
  validation {
    condition     = var.frontend_replicas >= 1
    error_message = "Se requiere al menos una réplica del frontend."
  }
}
variable "enable_loadtest_job" {
  description = "Activa el Job k6 del módulo durante una sesión de pruebas"
  type        = bool
  default     = false
}
variable "redis_persistence_enabled" {
  description = "Requiere un EBS CSI addon con rol Pod Identity existente; false usa emptyDir"
  type        = bool
  default     = false
}
