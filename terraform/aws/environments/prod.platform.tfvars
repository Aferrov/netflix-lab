region              = "us-east-1"
environment         = "prod"
vpc_cidr            = "10.43.0.0/16"
availability_zones  = ["us-east-1a", "us-east-1b"]
public_subnet_cidrs = ["10.43.0.0/24", "10.43.1.0/24"]
kubernetes_version  = "1.35"
node_instance_type  = "t3.medium"
node_count          = 2
node_disk_size      = 20
log_retention_days  = 7
# Esta variante de laboratorio requiere un presupuesto mayor. Para producción real,
# mover nodos a subredes privadas y diseñar salida NAT/endpoints y alta disponibilidad.
