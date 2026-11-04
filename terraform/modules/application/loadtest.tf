# Script de prueba de carga con k6 almacenado en ConfigMap
resource "kubernetes_config_map" "k6_script" {
  metadata {
    name      = "k6-script"
    namespace = kubernetes_namespace.this.metadata[0].name
  }

  data = {
    "test.js" = <<-EOT
      import http from 'k6/http';
      import { check, sleep } from 'k6';

      export const options = {
        stages: [
          { duration: '30s', target: 50 },   // sube a 50 usuarios virtuales
          { duration: '90s', target: 50 },   // se mantiene
          { duration: '30s', target: 0 },    // baja
        ],
        thresholds: {
          http_req_failed: ['rate<0.01'],     // menos de 1% de errores
          http_req_duration: ['p(95)<1500'],  // p95 bajo 1.5 s
        },
      };

      export default function () {
        const r = http.get(`$${__ENV.TARGET}/api/work?ms=80`);
        check(r, { 'status 200': (res) => res.status === 200 });
        sleep(0.1);
      }
    EOT
  }
}

# Job de Kubernetes para ejecutar la prueba de estrés bajo demanda
resource "kubernetes_job_v1" "k6_stress" {
  count = var.enable_loadtest_job ? 1 : 0

  metadata {
    name      = "k6-stress"
    namespace = kubernetes_namespace.this.metadata[0].name
  }

  spec {
    backoff_limit              = 0
    ttl_seconds_after_finished = 600

    template {
      metadata {
        labels = {
          app = "k6-stress"
        }
      }

      spec {
        restart_policy = "Never"

        container {
          name  = "k6"
          image = "grafana/k6:latest"
          args  = ["run", "/scripts/test.js"]

          env {
            name  = "TARGET"
            value = "http://backend:8080"
          }

          volume_mount {
            name       = "script"
            mount_path = "/scripts"
          }
        }

        volume {
          name = "script"
          config_map {
            name = kubernetes_config_map.k6_script.metadata[0].name
          }
        }
      }
    }
  }
}
