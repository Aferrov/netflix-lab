variable "cluster_name" {
  description = "Nombre del clúster local de KinD"
  type        = string
  default     = "netflix-lab"
}

variable "worker_nodes" {
  description = "Cantidad de nodos workers en el clúster (para simular alta disponibilidad)"
  type        = number
  default     = 2
}

variable "environment" {
  description = "Nombre del entorno de despliegue (dev, test, prod) - Patrón Reusable Stack (Cap. 6)"
  type        = string
  default     = "dev"
}

variable "namespace" {
  description = "Namespace de Kubernetes para aislar los recursos del laboratorio"
  type        = string
  default     = "netflix-lab"
}

variable "backend_min_replicas" {
  description = "Número mínimo de réplicas para el backend (HPA)"
  type        = number
  default     = 3
}

variable "backend_max_replicas" {
  description = "Número máximo de réplicas para el backend (HPA)"
  type        = number
  default     = 10
}

variable "backend_target_cpu_utilization" {
  description = "Porcentaje de CPU objetivo para activar el autoescalado horizontal (HPA)"
  type        = number
  default     = 50
}

variable "frontend_replicas" {
  description = "Número de réplicas para el dashboard frontend"
  type        = number
  default     = 2
}

variable "enable_loadtest_job" {
  description = "Si es true, despliega el Job de Kubernetes de k6 para ejecutar la prueba de carga"
  type        = bool
  default     = false
}
