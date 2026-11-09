resource "kubernetes_deployment" "backend" {
  metadata {
    name      = "backend"
    namespace = kubernetes_namespace.this.metadata[0].name
    labels = {
      app = "backend"
    }
  }

  spec {
    replicas = var.backend_min_replicas

    strategy {
      type = "RollingUpdate"
      rolling_update {
        max_unavailable = "0"
        max_surge       = "1"
      }
    }

    selector {
      match_labels = {
        app = "backend"
      }
    }

    template {
      metadata {
        labels = {
          app = "backend"
        }
      }

      spec {
        service_account_name             = kubernetes_service_account.backend.metadata[0].name
        termination_grace_period_seconds = 15

        topology_spread_constraint {
          max_skew           = 1
          topology_key       = "kubernetes.io/hostname"
          when_unsatisfiable = "ScheduleAnyway"
          label_selector {
            match_labels = {
              app = "backend"
            }
          }
        }

        container {
          name              = "backend"
          image             = var.backend_image
          image_pull_policy = "IfNotPresent"

          port {
            container_port = 8080
          }

          env {
            name  = "REDIS_HOST"
            value = "redis"
          }

          # El Service redis inyecta REDIS_PORT=tcp://...; Node necesita un puerto numérico.
          env {
            name  = "REDIS_PORT"
            value = "6379"
          }

          resources {
            requests = {
              cpu    = "100m"
              memory = "64Mi"
            }
            limits = {
              cpu    = "250m"
              memory = "128Mi"
            }
          }

          readiness_probe {
            http_get {
              path = "/ready"
              port = 8080
            }
            period_seconds    = 2
            timeout_seconds   = 3
            failure_threshold = 2
          }

          liveness_probe {
            http_get {
              path = "/healthz"
              port = 8080
            }
            period_seconds    = 3
            timeout_seconds   = 5
            failure_threshold = 3
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "backend" {
  metadata {
    name      = "backend"
    namespace = kubernetes_namespace.this.metadata[0].name
  }

  spec {
    selector = {
      app = "backend"
    }
    port {
      port        = 8080
      target_port = 8080
    }
  }
}

# Autoescalado Horizontal de Pods (HPA)
resource "kubernetes_horizontal_pod_autoscaler_v2" "backend" {
  metadata {
    name      = "backend"
    namespace = kubernetes_namespace.this.metadata[0].name
  }

  spec {
    min_replicas = var.backend_min_replicas
    max_replicas = var.backend_max_replicas

    scale_target_ref {
      api_version = "apps/v1"
      kind        = "Deployment"
      name        = kubernetes_deployment.backend.metadata[0].name
    }

    metric {
      type = "Resource"
      resource {
        name = "cpu"
        target {
          type                = "Utilization"
          average_utilization = var.backend_target_cpu_utilization
        }
      }
    }

    behavior {
      scale_down {
        stabilization_window_seconds = 60
        select_policy                = "Max"
        policy {
          type           = "Percent"
          value          = 100
          period_seconds = 15
        }
      }
    }
  }
}

# PodDisruptionBudget para garantizar al menos 2 réplicas durante mantenimiento de nodos
resource "kubernetes_pod_disruption_budget_v1" "backend" {
  metadata {
    name      = "backend"
    namespace = kubernetes_namespace.this.metadata[0].name
  }

  spec {
    min_available = tostring(min(2, var.backend_min_replicas))
    selector {
      match_labels = {
        app = "backend"
      }
    }
  }
}
