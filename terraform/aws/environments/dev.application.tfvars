region                    = "us-east-1"
environment               = "dev"
backend_min_replicas      = 1
backend_max_replicas      = 2
frontend_replicas         = 1
redis_persistence_enabled = false
# Pasa image_tag por TF_VAR_image_tag después de publicar las imágenes en ECR.
