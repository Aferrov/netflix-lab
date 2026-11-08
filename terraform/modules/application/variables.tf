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

variable "backend_image" {
  description = "Imagen del backend; en EKS se usa URI de ECR con tag inmutable"
  type        = string
  default     = "netflix-lab/backend:1.0"
}

variable "frontend_image" {
  description = "Imagen del frontend; en EKS se usa URI de ECR con tag inmutable"
  type        = string
  default     = "netflix-lab/frontend:1.0"
}

variable "redis_storage_class_name" {
  description = "StorageClass de Redis; null conserva la clase predeterminada de KinD"
  type        = string
  default     = null
}

variable "redis_storage_size" {
  description = "Tamaño del PVC de Redis"
  type        = string
  default     = "100Mi"
}
