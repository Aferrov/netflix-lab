output "cluster_name" {
  description = "Nombre del clúster provisionado"
  value       = module.cluster.cluster_name
}

output "dashboard_port_forward_cmd" {
  description = "Comando para acceder al frontend en vivo"
  value       = "kubectl --context kind-${var.cluster_name} -n ${var.namespace} port-forward svc/${module.application.frontend_service_name} 8080:80"
}

output "loadtest_run_cmd" {
  description = "Comando para correr la prueba de carga k6 de forma manual si no se activó con Terraform"
  value       = "kubectl --context kind-${var.cluster_name} apply -f ${abspath("${path.root}/../loadtest/k6-job.yaml")}"
}
