# ==============================================================================
# COMPOSICIÓN DE STACKS (Kief Morris - Capítulos 5 y 6)
# Separa la infraestructura base (Plataforma) de las cargas de trabajo (Aplicación)
# ==============================================================================

# 1. Stack de Plataforma (Cap. 3 y 5)
module "cluster" {
  source       = "./modules/cluster"
  cluster_name = var.cluster_name
  worker_count = var.worker_nodes
  project_root = abspath("${path.root}/..")
}

# 2. Stack de Cargas de Trabajo / Microservicios (Cap. 5)
module "application" {
  source     = "./modules/application"
  depends_on = [module.cluster]

  namespace                      = var.namespace
  environment                    = var.environment
  backend_min_replicas           = var.backend_min_replicas
  backend_max_replicas           = var.backend_max_replicas
  backend_target_cpu_utilization = var.backend_target_cpu_utilization
  frontend_replicas              = var.frontend_replicas
  enable_loadtest_job            = var.enable_loadtest_job
}
