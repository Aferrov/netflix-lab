# Plan de migración a AWS y mejora de prácticas IaC

> Implementación para el crédito AWS Academy de USD 50: consulta [AWS_MIGRACION.md](AWS_MIGRACION.md). El entorno `dev` evita NAT Gateway y Load Balancer, usa un nodo EKS público con acceso a la API restringido por CIDR y se destruye después de cada sesión. Las subredes privadas y el entorno `prod` descritos abajo son objetivos para un presupuesto mayor.

## Objetivo

Migrar el laboratorio actual basado en KinD hacia AWS usando Amazon EKS, manteniendo Terraform como herramienta principal de Infrastructure as Code y aplicando las prácticas pendientes del libro *Infrastructure as Code* de Kief Morris.

La meta inicial es tener un entorno `dev` reproducible en AWS mediante `terraform apply`, sin depender de comandos manuales de KinD, `kubectl apply` ni construcción local de imágenes.

## Arquitectura objetivo

```text
AWS
├── VPC
│   ├── Subnets públicas
│   └── Subnets privadas
├── EKS
│   ├── Control plane administrado
│   ├── Managed Node Groups
│   └── Add-ons de Kubernetes
├── ECR
│   ├── netflix-lab/backend
│   └── netflix-lab/frontend
├── S3
│   └── Estado remoto de Terraform
├── IAM
│   ├── Rol de Terraform
│   └── Roles para workloads
└── CloudWatch / Prometheus
```

## Fases del proyecto

### 1. Separar los stacks de Terraform

Organizar la infraestructura en módulos independientes:

```text
terraform/
├── bootstrap/
├── environments/
│   ├── dev/
│   └── prod/
├── modules/
│   ├── network/
│   ├── eks/
│   ├── ecr/
│   ├── addons/
│   ├── application/
│   └── observability/
└── policies/
```

Responsabilidad de cada módulo:

- `network`: VPC, subnets, rutas, NAT Gateway e Internet Gateway.
- `eks`: clúster EKS y Managed Node Groups.
- `ecr`: repositorios de imágenes Docker.
- `addons`: AWS Load Balancer Controller, metrics-server y EBS CSI Driver.
- `application`: frontend, backend, Redis, RBAC, HPA y PDB.
- `observability`: logs, métricas, dashboards y alarmas.

Separar la plataforma de la aplicación reduce el *blast radius*: cambiar la aplicación no debería recrear la red ni el clúster.

### 2. Implementar estado remoto

Crear un stack `bootstrap` que provisionará:

- Bucket S3 privado para el estado.
- Versionado del bucket.
- Cifrado.
- Bloqueo de acceso público.
- Locking de Terraform mediante `use_lockfile = true`.

Se recomienda separar los estados por entorno y stack:

```text
dev/platform.tfstate
dev/application.tfstate
prod/platform.tfstate
prod/application.tfstate
```

Ejemplo de backend:

```hcl
terraform {
  backend "s3" {
    bucket       = "netflix-lab-terraform-state"
    key          = "dev/platform.tfstate"
    region       = "us-east-1"
    use_lockfile = true
    encrypt      = true
  }
}
```

### 3. Crear la red AWS

Implementar una VPC con:

- Dos o tres Availability Zones.
- Subnets públicas para load balancers.
- Subnets privadas para los nodos EKS.
- NAT Gateway.
- Internet Gateway.
- Route tables.
- Tags requeridos por EKS y el AWS Load Balancer Controller.

Los nodos y las aplicaciones deberían ejecutarse en subnets privadas.

### 4. Migrar KinD a EKS

Reemplazar el módulo actual `modules/cluster`:

- Eliminar `kind_cluster`.
- Eliminar `kind load docker-image`.
- Crear el clúster EKS.
- Crear Managed Node Groups.
- Definir versiones explícitas de Kubernetes y providers.
- Usar instancias pequeñas en `dev`.
- Usar más nodos y Availability Zones en `prod`.
- Configurar logs del control plane.
- Restringir el endpoint público del clúster.

El entorno KinD puede conservarse como entorno local opcional.

### 5. Migrar las imágenes a ECR

Sustituir la construcción local ejecutada mediante `local-exec`:

1. Crear los repositorios ECR con Terraform.
2. Construir las imágenes en CI/CD.
3. Publicarlas en ECR.
4. Pasar la URI de cada imagen a Kubernetes.

Usar tags inmutables basados en el SHA del commit:

```text
123456789012.dkr.ecr.us-east-1.amazonaws.com/netflix-lab/backend:<git-sha>
```

Evitar depender únicamente de `latest` o `1.0`.

### 6. Gestionar Redis y almacenamiento

Evaluar dos opciones:

- Redis dentro de EKS usando EBS CSI Driver, StorageClass `gp3` y PVC dinámico.
- ElastiCache for Redis, recomendado para producción.

Para el laboratorio se puede comenzar con Redis sobre EBS. Para una arquitectura productiva, ElastiCache reduce la responsabilidad operativa.

### 7. Mejorar la seguridad

Aplicar las siguientes prácticas:

- No almacenar credenciales AWS en el repositorio.
- Usar roles IAM y OIDC para CI/CD.
- Separar los permisos de Terraform de los permisos de los workloads.
- Usar IRSA o EKS Pod Identity.
- Guardar secretos en AWS Secrets Manager o SSM Parameter Store.
- Mantener RBAC Kubernetes con mínimo privilegio.
- Restringir Security Groups.
- Cifrar EBS y el estado de Terraform.
- Habilitar CloudTrail y logs de EKS.

### 8. Implementar entornos reales

Crear configuraciones reutilizables para `dev` y `prod`.

Ejemplo para desarrollo:

```hcl
environment           = "dev"
worker_instance_types = ["t3.small"]
desired_nodes         = 1
backend_min_replicas  = 1
backend_max_replicas  = 3
frontend_replicas     = 1
```

Ejemplo para producción:

```hcl
environment           = "prod"
worker_instance_types = ["t3.medium"]
desired_nodes         = 3
backend_min_replicas  = 3
backend_max_replicas  = 10
frontend_replicas     = 2
```

Ambos entornos deben reutilizar los mismos módulos y diferenciarse únicamente mediante configuración. No se deben duplicar archivos Terraform completos.

Los archivos `.tfvars` no sensibles pueden versionarse. El `.gitignore` debe modificarse para ignorar únicamente archivos que contengan secretos.

### 9. Incorporar CI/CD y pruebas

En cada Pull Request:

```bash
terraform fmt -check -recursive
terraform init
terraform validate
terraform plan
```

Después del merge a `main`:

- Aplicar automáticamente en `dev`.
- Aplicar en `prod` únicamente con aprobación manual.
- Usar OIDC entre GitHub Actions y AWS.

Añadir también:

- `tflint`.
- `tfsec` o Checkov.
- Pruebas de conectividad.
- Pruebas del despliegue Kubernetes.
- Pruebas k6 contra `dev`.
- Validación del comportamiento del HPA.
- Entornos temporales que se destruyan automáticamente.

## Orden recomendado de implementación

1. Crear `environments/dev` y `environments/prod`.
2. Separar `bootstrap`, `platform` y `application`.
3. Crear el bucket S3 remoto con versionado y locking.
4. Crear la VPC en AWS.
5. Crear el clúster EKS de desarrollo.
6. Crear ECR y el pipeline de imágenes.
7. Migrar frontend, backend, HPA y RBAC.
8. Implementar almacenamiento para Redis.
9. Añadir IAM, secretos y observabilidad.
10. Crear el entorno EKS de producción.
11. Añadir CI/CD con aprobación para producción.
12. Ejecutar pruebas de resiliencia y carga.

## Resultado esperado

Al finalizar, el proyecto tendrá:

- Infraestructura AWS completamente declarada en Terraform.
- Estados remotos, versionados y bloqueados.
- Entornos `dev` y `prod` reproducibles.
- EKS como plataforma administrada.
- Imágenes almacenadas en ECR.
- Aplicaciones desplegadas con módulos reutilizables.
- CI/CD con validaciones y aprobación para producción.
- Seguridad, observabilidad y pruebas automatizadas.
