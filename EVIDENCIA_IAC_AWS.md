# Evidencia de infraestructura como código en AWS

Este documento relaciona el laboratorio `dev` ejecutado en AWS Academy con los primeros diez capítulos de [*Infrastructure as Code*, segunda edición, de Kief Morris](https://www.oreilly.com/library/view/infrastructure-as-code/9781098114664/). Describe lo que se comprobó durante una sesión real de noviembre de 2026. [AWS_MIGRACION.md](AWS_MIGRACION.md) contiene los comandos para repetirla; [PLAN_MIGRACION_AWS_IAC.md](PLAN_MIGRACION_AWS_IAC.md) contiene objetivos futuros, no resultados verificados.

## Arquitectura ejecutada

| Capa | Definición en el repositorio | Resultado probado |
|---|---|---|
| Estado | [Bootstrap S3](terraform/aws/bootstrap/bootstrap.sh) y backends de [plataforma](terraform/aws/platform/main.tf) y [aplicación](terraform/aws/application/main.tf) | Bucket privado, cifrado y versionado; estados separados con bloqueo `.tflock`. El bucket permanece después de `destroy`. |
| Red y cómputo | [Módulos de red](terraform/aws/modules/network/main.tf) y [EKS](terraform/aws/modules/eks/main.tf) | VPC, dos subredes en zonas distintas, clúster EKS 1.35 y un nodo `t3.medium` en estado `Ready`. |
| Imágenes | [Módulo ECR](terraform/aws/modules/ecr/main.tf) y [script de publicación](scripts/push-images.sh) | Frontend y backend publicados con el mismo tag derivado del contenido; repositorios con tags inmutables. |
| Aplicación | [Stack de aplicación](terraform/aws/application/main.tf) y [módulo Kubernetes](terraform/modules/application) | Frontend, backend y Redis `Running`; HPA con métricas; respuestas HTTP `200` del dashboard y de `/api/info` y `/api/cluster`. |

La sesión siguió la secuencia **definir → validar → planificar → aplicar → verificar → destruir**. El plan de plataforma mostró `15 to add, 0 to change, 0 to destroy` y el de aplicación `13 to add, 0 to change, 0 to destroy`. Después de ejecutar ambos `destroy`, los dos estados de Terraform quedaron vacíos; EKS no listó clústeres, el nodo ya no apareció en EC2 y ambos repositorios ECR dejaron de existir. Estas comprobaciones son manuales de una sesión, no pruebas automáticas repetidas.

## Relación con los capítulos 1–10

| Capítulo del libro | Concepto aplicado | Evidencia y alcance |
|---|---|---|
| **1. ¿Qué es IaC?** | Infraestructura versionada, cambios pequeños y validación antes de aplicar. | HCL, scripts y workflow de CI en Git; commits separados para cambios significativos. Se usó `plan` antes de crear recursos facturables. |
| **2. Principios de infraestructura en la nube** | Recursos reproducibles y desechables. | La sesión creó la plataforma y la aplicación desde código y luego las destruyó. Se comprobó el estado vacío. La repetición completa en otra sesión queda pendiente. |
| **3. Plataformas de infraestructura** | Cómputo, red y almacenamiento. | EKS y EC2 para cómputo; VPC, subredes, rutas e Internet Gateway para red; S3 para estado y disco EBS del nodo. Redis usó almacenamiento temporal. |
| **4. Definir todo como código** | Configuración declarativa y versionada, con automatización donde el lab restringe el proveedor. | Terraform define la plataforma y los objetos Kubernetes. El bootstrap S3 usa un script idempotente porque una política del lab deniega `s3:GetBucketObjectLockConfiguration`. Los roles IAM son precreados y se pasan como parámetros. |
| **5. Construir stacks como código** | Separar cambios por responsabilidad. | `platform` gestiona AWS; `application` gestiona Kubernetes; cada uno usa su propio estado S3. Los módulos `network`, `eks` y `ecr` reducen duplicación. |
| **6. Construir entornos con stacks** | Reutilizar el mismo código con configuración externa. | Existen archivos [dev](terraform/aws/environments/dev.platform.tfvars) y [prod](terraform/aws/environments/prod.platform.tfvars). Solo `dev` se ejecutó; la paridad con `prod` no se ha demostrado. |
| **7. Configurar instancias de stacks** | Parámetros por entorno y credenciales fuera de Git. | `.tfvars` sin secretos, `TF_VAR_*` para CIDR y ARNs de roles, credenciales temporales de AWS CLI fuera del repositorio. No se implementó OIDC ni un registro central de parámetros. |
| **8. Probar y entregar continuamente** | Validación temprana y progresiva. | El [workflow de CI](.github/workflows/terraform-validate.yml) está configurado para ejecutar `terraform fmt`, `init -backend=false` y `validate`; el despliegue real fue manual. No se verificó una ejecución del workflow ni existe entrega automática a EKS. |
| **9. Probar stacks de infraestructura** | Pruebas estáticas, vista previa y comprobación de resultados. | `fmt` y `validate`; `plan` de ambos stacks; `kubectl` confirmó nodo y pods; HTTP devolvió `200`; `destroy` eliminó los recursos. El Job k6 y el escalado efectivo del HPA no se probaron en AWS. |
| **10. Plataformas de ejecución de aplicaciones** | Empaquetar contenedores, publicarlos y ejecutarlos en un clúster. | Docker construyó las imágenes localmente, ECR las almacenó y EKS las ejecutó. Services y DNS conectaron frontend, backend y Redis. Redis en `dev` usa `emptyDir`, por lo que no se demostró persistencia tras recrear el pod. |

## Límites de la demostración

- Un nodo permitió comprobar el despliegue. No se probó la reparación tras borrar un pod ni la alta disponibilidad entre nodos o zonas.
- El HPA recibió métricas y mostró una réplica; no se ejecutó k6 ni se comprobó una segunda réplica bajo carga.
- `prod` es una configuración de ejemplo; no se desplegó con el crédito del lab.
- El bucket S3 de estado permanece. El gasto principal de EKS y EC2 terminó al destruir la plataforma; el almacenamiento S3 puede seguir generando un costo pequeño.
- No se midieron costos reales ni se implementaron IAM/OIDC, EBS CSI, Redis persistente, balanceador público o una pipeline de despliegue a AWS. Esos puntos dependen de presupuesto, permisos o trabajo adicional.

En una exposición, la afirmación respaldada por la prueba es: **«Definimos y versionamos la infraestructura, revisamos el plan, desplegamos una aplicación real en EKS, verificamos su respuesta y destruimos los recursos con Terraform»**.
