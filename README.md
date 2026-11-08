# Netflix Lab: Kubernetes e infraestructura como código

Laboratorio de frontend, API y Redis en Kubernetes. Terraform define la infraestructura y los objetos del clúster; los scripts versionados preparan el estado S3 y publican imágenes. El proyecto tiene dos formas de ejecución:

| Entorno | Infraestructura | Uso |
|---|---|---|
| **Local** | KinD con dos workers por defecto, `metrics-server` y Redis con PVC | Desarrollo y experimentos sin consumir crédito AWS. |
| **AWS Academy `dev`** | Amazon EKS con un nodo, VPC, ECR, S3 y Redis temporal | Demostrar un despliegue real en la nube durante sesiones cortas. |

El despliegue `dev` de AWS se **creó, verificó y destruyó** en una sesión real. Al cerrar esa prueba, no quedó un clúster EKS activo; el bucket S3 del estado permaneció para reutilizarlo. Consulta la [evidencia por capítulos 1–10 del libro *Infrastructure as Code*](EVIDENCIA_IAC_AWS.md) para distinguir lo comprobado de lo pendiente.

## Arquitectura

```text
Navegador ── port-forward ── frontend (Nginx)
                              │ /api/
                              ▼
                         backend (Node.js) ── Redis
                              │
                              └── API de Kubernetes: pods y HPA (RBAC)
```

El frontend muestra pods, tráfico y estado del HPA. El backend tiene sondas de salud, un Service y un HPA; Redis guarda el contador de visitas. El Job de carga k6 es **opcional** y está desactivado por defecto. El dashboard comienza sin generar tráfico: pulsa **«Enviar tráfico constante»** para ver cambiar peticiones y visitas.

En AWS, Docker construye las imágenes en el equipo local, ECR las almacena y EKS ejecuta los contenedores. El acceso al dashboard se hace mediante `kubectl port-forward`; el proyecto no crea un balanceador público. La VPC tiene dos subredes públicas, sin NAT Gateway. Redis usa `emptyDir` en AWS Academy porque el laboratorio no proporciona un rol EBS CSI compatible; sus datos se pierden al recrear el pod.

## Infraestructura como código

El proyecto aplica conceptos de los primeros diez capítulos de la segunda edición de *Infrastructure as Code*, de Kief Morris:

| Concepto | Implementación |
|---|---|
| Recursos definidos y versionados | Terraform para VPC, EKS, ECR y Kubernetes; scripts para bootstrap S3 y empaquetado. |
| Recursos desechables y stacks pequeños | Estados S3 separados para `platform` y `application`; creación y destrucción independientes. |
| Configuración externa | Archivos `.tfvars` por entorno y variables `TF_VAR_*`; credenciales temporales fuera de Git. |
| Validación progresiva | Workflow de CI configurado con `fmt` y `validate`; revisión manual de `plan`, comprobación HTTP/Kubernetes y `destroy`. |
| Plataforma de ejecución | Imágenes inmutables en ECR y servicios desplegados en EKS. |

La [explicación detallada de AWS](EVIDENCIA_IAC_AWS.md) relaciona cada capítulo con archivos y pruebas observadas. [EXPLICACION_IAC_PROYECTO.md](EXPLICACION_IAC_PROYECTO.md) describe el laboratorio KinD original; [PLAN_MIGRACION_AWS_IAC.md](PLAN_MIGRACION_AWS_IAC.md) registra objetivos futuros.

## Ejecutar el laboratorio local con KinD

Requiere Terraform ≥ 1.5, Docker funcionando dentro de la distribución Linux, `kind` y `kubectl`. En WSL, habilita la integración de Docker Desktop para esa distribución. La alternativa `docker.exe` del script AWS se probó para construir y publicar imágenes, pero no con KinD.

Desde la raíz del repositorio:

```bash
terraform -chdir=terraform init
terraform -chdir=terraform plan
terraform -chdir=terraform apply
```

Terraform usa los valores predeterminados de [terraform/variables.tf](terraform/variables.tf): dos workers, tres réplicas iniciales de backend (máximo diez) y dos de frontend. El módulo local crea KinD, instala `metrics-server`, construye las imágenes y despliega la aplicación. Revisa el plan y confirma el `apply` cuando Terraform lo solicite.

Comprueba los pods y abre el dashboard:

```bash
kubectl --context kind-netflix-lab -n netflix-lab get pods,hpa
kubectl --context kind-netflix-lab -n netflix-lab port-forward svc/frontend 8080:80
```

Abre `http://localhost:8080`. El botón de tráfico permite observar peticiones y el contador de Redis. Las acciones de fallos y la carga k6 son experimentos opcionales; [loadtest/k6-job.yaml](loadtest/k6-job.yaml) contiene el Job de carga.

Al terminar, detén el `port-forward` con `Ctrl+C` y destruye el entorno local:

```bash
terraform -chdir=terraform destroy
```

## Ejecutar el laboratorio en AWS Academy

Sigue [AWS_MIGRACION.md](AWS_MIGRACION.md) para configurar las credenciales temporales del Learner Lab, preparar el bucket S3, revisar los planes, crear EKS, publicar las imágenes en ECR y desplegar la aplicación. **No guardes credenciales en el repositorio.** El entorno `dev` usa un nodo `t3.medium` y está diseñado para permanecer encendido solo durante la prueba: EKS y EC2 consumen crédito mientras existen.

La sesión verificada confirmó un nodo `Ready`, tres pods `Running`, métricas del HPA y respuestas HTTP `200` del dashboard y la API. Después se destruyeron la aplicación y la plataforma; se comprobó que EKS, el nodo y los repositorios ECR ya no aparecían. No se ejecutaron k6 ni `prod`, ni se demostró alta disponibilidad entre nodos o persistencia de Redis. El [registro de evidencia](EVIDENCIA_IAC_AWS.md) detalla estos límites.

La destrucción en AWS sigue este orden: primero `terraform/aws/application`, después `terraform/aws/platform`. Espera a que ambos comandos terminen; el bucket S3 versionado conserva el estado para futuras sesiones y puede generar un costo pequeño de almacenamiento. Los comandos y variables exactos están en la [guía de migración](AWS_MIGRACION.md#destrucción-y-estado).

## Estructura principal

```text
backend/                         API Node.js e imagen Docker
frontend/                        Dashboard Nginx e imagen Docker
loadtest/                        Job k6 opcional
scripts/push-images.sh            Publicación de imágenes en ECR
terraform/                        Laboratorio local KinD y módulo de aplicación compartido
terraform/aws/bootstrap/          Bootstrap S3 compatible con Learner Lab
terraform/aws/platform/           VPC, EKS, ECR y logs
terraform/aws/application/        Objetos Kubernetes sobre EKS
terraform/aws/environments/       Parámetros dev y prod de AWS
AWS_MIGRACION.md                  Guía de despliegue y destrucción AWS
EVIDENCIA_IAC_AWS.md              Evidencia y límites por capítulo del libro
```
