output "namespace" {
  description = "Namespace donde se desplegó la aplicación"
  value       = kubernetes_namespace.this.metadata[0].name
}

output "frontend_service_name" {
  description = "Nombre del Service de frontend"
  value       = kubernetes_service.frontend.metadata[0].name
}

output "backend_service_name" {
  description = "Nombre del Service de backend"
  value       = kubernetes_service.backend.metadata[0].name
}
