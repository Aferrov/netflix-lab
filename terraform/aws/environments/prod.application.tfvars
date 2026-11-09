region                         = "us-east-1"
environment                    = "prod"
backend_min_replicas           = 2
backend_max_replicas           = 4
frontend_replicas              = 2
backend_target_cpu_utilization = 50
redis_storage_size             = "1Gi"
redis_persistence_enabled      = false
# Redis usa emptyDir para el laboratorio; el contador se pierde al recrear el pod.
# Pasa image_tag por TF_VAR_image_tag después de publicar las imágenes en ECR.
