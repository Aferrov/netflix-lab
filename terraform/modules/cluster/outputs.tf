output "cluster_name" {
  description = "Nombre del clúster KinD creado"
  value       = kind_cluster.this.name
}

output "endpoint" {
  description = "API endpoint del clúster de Kubernetes"
  value       = kind_cluster.this.endpoint
}

output "client_certificate" {
  description = "Certificado del cliente para autenticación"
  value       = kind_cluster.this.client_certificate
  sensitive   = true
}

output "client_key" {
  description = "Clave privada del cliente"
  value       = kind_cluster.this.client_key
  sensitive   = true
}

output "cluster_ca_certificate" {
  description = "Certificado CA del clúster"
  value       = kind_cluster.this.cluster_ca_certificate
  sensitive   = true
}

output "kubeconfig_path" {
  description = "Ruta al archivo kubeconfig del clúster"
  value       = kind_cluster.this.kubeconfig_path
}
