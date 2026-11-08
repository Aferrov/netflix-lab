variable "region" { type = string }
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
