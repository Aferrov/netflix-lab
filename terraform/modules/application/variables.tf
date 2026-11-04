variable "namespace" {
  description = "Namespace de Kubernetes para el stack de aplicaciones"
  type        = string
  default     = "netflix-lab"
}

variable "environment" {
  description = "Entorno (dev, prod, test) para etiquetado"
  type        = string
  default     = "dev"
}

variable "backend_min_replicas" {
  description = "Mínimo de réplicas para el backend"
  type        = number
  default     = 3
}

variable "backend_max_replicas" {
  description = "Máximo de réplicas para el backend (HPA)"
  type        = number
  default     = 10
}

variable "backend_target_cpu_utilization" {
  description = "Porcentaje de CPU objetivo para el HPA"
  type        = number
  default     = 50
}

variable "frontend_replicas" {
  description = "Número de réplicas para el frontend"
  type        = number
  default     = 2
}

variable "enable_loadtest_job" {
  description = "Habilitar el Job de prueba de carga con k6"
  type        = bool
  default     = false
}
