# ==============================================================================
# STACK DE PLATAFORMA (Kief Morris - Capítulos 3 y 5)
# Aprovisiona el clúster de cómputo (KinD) y la infraestructura base (metrics-server)
# ==============================================================================

resource "kind_cluster" "this" {
  name           = var.cluster_name
  wait_for_ready = true

  kind_config {
    kind        = "Cluster"
    api_version = "kind.x-k8s.io/v1alpha4"

    node {
      role = "control-plane"
    }

    dynamic "node" {
      for_each = range(var.worker_count)
      content {
        role = "worker"
      }
    }
  }
}

# Instalación automatizada de metrics-server para permitir la lectura de CPU del HPA
resource "null_resource" "metrics_server" {
  depends_on = [kind_cluster.this]

  provisioner "local-exec" {
    command = <<-EOT
      kubectl apply --context kind-${var.cluster_name} -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
      kubectl patch --context kind-${var.cluster_name} -n kube-system deployment metrics-server --type=json \
        -p '[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'
    EOT
  }
}

# Construcción y carga automatizada de imágenes locales de Docker dentro del clúster KinD
resource "null_resource" "docker_images" {
  depends_on = [kind_cluster.this]

  triggers = {
    backend_server = filemd5("${var.project_root}/backend/server.js")
    backend_docker = filemd5("${var.project_root}/backend/Dockerfile")
    frontend_html  = filemd5("${var.project_root}/frontend/index.html")
    frontend_conf  = filemd5("${var.project_root}/frontend/nginx.conf")
  }

  provisioner "local-exec" {
    command = <<-EOT
      docker build -t netflix-lab/backend:1.0 ${var.project_root}/backend
      docker build -t netflix-lab/frontend:1.0 ${var.project_root}/frontend
      kind load docker-image netflix-lab/backend:1.0 netflix-lab/frontend:1.0 --name ${var.cluster_name}
    EOT
  }
}
