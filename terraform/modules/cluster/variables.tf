variable "cluster_name" {
  description = "Nombre del clúster KinD"
  type        = string
}

variable "worker_count" {
  description = "Cantidad de nodos workers a crear"
  type        = number
  default     = 2
}

variable "project_root" {
  description = "Ruta absoluta a la raíz del repositorio"
  type        = string
}
