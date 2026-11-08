region              = "us-east-1"
environment         = "dev"
vpc_cidr            = "10.42.0.0/16"
availability_zones  = ["us-east-1a", "us-east-1b"]
public_subnet_cidrs = ["10.42.0.0/24", "10.42.1.0/24"]
kubernetes_version  = "1.35"
node_instance_type  = "t3.medium"
node_count          = 1
# Pasa api_access_cidrs por TF_VAR_api_access_cidrs con tu IP pública /32.
