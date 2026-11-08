region               = "us-east-1"
environment          = "prod"
backend_min_replicas = 2
backend_max_replicas = 4
frontend_replicas    = 2
# Pasa image_tag por TF_VAR_image_tag después de publicar las imágenes en ECR.
