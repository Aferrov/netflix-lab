# Almacenamiento persistente para Redis (PVC)
resource "kubernetes_persistent_volume_claim" "redis_data" {
  wait_until_bound = false

  metadata {
    name      = "redis-data"
    namespace = kubernetes_namespace.this.metadata[0].name
  }

  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = var.redis_storage_class_name
    resources {
      requests = {
        storage = var.redis_storage_size
      }
    }
  }
}

resource "kubernetes_deployment" "redis" {
  metadata {
    name      = "redis"
    namespace = kubernetes_namespace.this.metadata[0].name
    labels = {
      app = "redis"
    }
  }

  spec {
    replicas = 1
    strategy {
      type = "Recreate" # ReadWriteOnce: no puede haber 2 pods montando el disco al mismo tiempo
    }

    selector {
      match_labels = {
        app = "redis"
      }
    }

    template {
      metadata {
        labels = {
          app = "redis"
        }
      }

      spec {
        container {
          name  = "redis"
          image = "redis:7-alpine"
          args  = ["--appendonly", "yes"]

          port {
            container_port = 6379
          }

          resources {
            requests = {
              cpu    = "50m"
              memory = "32Mi"
            }
            limits = {
              cpu    = "200m"
              memory = "128Mi"
            }
          }

          readiness_probe {
            tcp_socket {
              port = 6379
            }
            period_seconds = 3
          }

          volume_mount {
            name       = "data"
            mount_path = "/data"
          }
        }

        volume {
          name = "data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.redis_data.metadata[0].name
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "redis" {
  metadata {
    name      = "redis"
    namespace = kubernetes_namespace.this.metadata[0].name
  }

  spec {
    selector = {
      app = "redis"
    }
    port {
      port        = 6379
      target_port = 6379
    }
  }
}
