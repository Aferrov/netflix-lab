# Permisos RBAC para que el pod backend pueda consultar el estado de pods y HPA
resource "kubernetes_service_account" "backend" {
  metadata {
    name      = "backend"
    namespace = kubernetes_namespace.this.metadata[0].name
  }
}

resource "kubernetes_role" "backend" {
  metadata {
    name      = "backend"
    namespace = kubernetes_namespace.this.metadata[0].name
  }

  rule {
    api_groups = [""]
    resources  = ["pods"]
    verbs      = ["get", "list", "delete"]
  }

  rule {
    api_groups = ["autoscaling"]
    resources  = ["horizontalpodautoscalers"]
    verbs      = ["get", "list"]
  }
}

resource "kubernetes_role_binding" "backend" {
  metadata {
    name      = "backend"
    namespace = kubernetes_namespace.this.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.backend.metadata[0].name
    namespace = kubernetes_namespace.this.metadata[0].name
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role.backend.metadata[0].name
  }
}
