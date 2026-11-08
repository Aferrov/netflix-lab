# Laboratorio IaC en AWS (crédito de USD 50)

Esta implementación conserva `terraform/` como laboratorio KinD y añade `terraform/aws/` para EKS. `dev` está pensado para sesiones cortas: dos subredes públicas en distintas zonas, un nodo administrado `t3.medium`, ECR, S3 para estado, métricas de Kubernetes y logs de EKS con retención de siete días. No crea NAT Gateway ni Load Balancer. El dashboard se consulta con `kubectl port-forward`.

**AWS Academy:** el Learner Lab del proyecto permite EKS, pero no crear roles IAM libremente. Este Terraform **no crea roles IAM**: exige `cluster_role_arn` y `node_role_arn` existentes. Los nombres reales de tu cuenta contienen un prefijo y un sufijo alrededor de `LabEksClusterRole` y `LabEksNodeRole`; el ARN debe incluir el nombre completo. Debes poder pasarlos a EKS con `iam:PassRole`. No compartas credenciales ni archivos de sesión.

Para diagnosticar IAM sin crear recursos, ejecuta `aws sts get-caller-identity` y, después de definir las variables de abajo, `aws iam get-role --role-name "$EKS_CLUSTER_ROLE_NAME"` y `aws iam get-role --role-name "$EKS_NODE_ROLE_NAME"`. El rol del clúster debe confiar en `eks.amazonaws.com` y el de nodos en `ec2.amazonaws.com`. Si falta la confianza o `iam:PassRole`, un administrador del laboratorio tendrá que habilitarlo. Un error `AccessDenied` en `eks:CreateCluster` bloquea EKS aun si Terraform es válido.

El ARN de `get-caller-identity` identifica la sesión con la que llamas a AWS; **no** sustituye los roles de servicio de EKS. El rol de nodos debe ser diferente del rol del clúster ([requisito de AWS](https://docs.aws.amazon.com/eks/latest/userguide/create-node-role.html)). La lista exacta de servicios permitidos depende del Learner Lab; consulta **Readme → Service usage and other restrictions** ([guía de AWS Academy](https://d1.awsstatic.com/AWS%20Academy%20Learner%20Lab%20Educator%20Guide.pdf)).

No hay un rol EBS CSI/Pod Identity precreado en este lab. Por eso `dev` usa `emptyDir` para Redis: los datos sobreviven a un reinicio del contenedor dentro del mismo pod, pero se pierden al recrear el pod o destruir el clúster. El laboratorio KinD mantiene su PVC. En una cuenta con un rol EBS CSI compatible, se puede pasar `ebs_csi_role_arn` a la plataforma y activar `redis_persistence_enabled=true` en la aplicación para usar PVC `gp3` cifrado.

## Costo y decisión de arquitectura

En `us-east-1`, una estimación para `dev` es **USD 0,15 por hora**: EKS USD 0,10/h, un `t3.medium` alrededor de USD 0,0416/h, una IPv4 pública USD 0,005/h y aproximadamente USD 0,0022/h de EBS para el disco de 20 GiB del nodo. Ocho horas cuestan cerca de USD 1,20; un mes encendido supera USD 100. Se suman ECR, S3, CloudWatch, transferencia de datos e impuestos si aplican. El crédito **no es un límite automático de gasto**. Destruye el entorno al acabar cada sesión. Los precios y permisos varían por región y cuenta.

Fuentes: [EKS](https://aws.amazon.com/eks/pricing/), [EC2](https://docs.aws.amazon.com/prescriptive-guidance/latest/optimize-costs-microsoft-workloads/right-size-selection.html), [IPv4/NAT](https://aws.amazon.com/vpc/pricing/), [EBS](https://aws.amazon.com/ebs/pricing/) y [limitaciones de Learner Lab](https://d1.awsstatic.com/AWS%20Academy%20Learner%20Lab%20Educator%20Guide.pdf).

Esta topología pública es deliberada para el laboratorio de bajo costo. La variante `prod` es un ejemplo de parametrización, **no** una arquitectura productiva completa: antes de usarla en un sistema real hay que mover los nodos a subredes privadas, diseñar salida de red, balanceo, más zonas y un presupuesto adecuado.

## Requisitos

- Terraform >= 1.10, AWS CLI v2, Docker, `kubectl` y `bash`.
- Credenciales temporales de AWS Academy configuradas en el perfil/entorno de AWS CLI; verifica `aws sts get-caller-identity`.
- Permisos para crear los servicios anteriores y una dirección IPv4 pública de administración.
- Espacio de IP y cuota de EKS/EC2 disponibles en `us-east-1`.

## Despliegue de `dev`

Ejecuta los comandos desde la raíz del repositorio. Sustituye el bucket por un nombre globalmente único y la IP por tu dirección pública real. Los nombres de rol siguientes son los que compartiste; verifica cada carácter en IAM antes de usarlos.

```bash
export AWS_REGION=us-east-1
export STATE_BUCKET=netflix-lab-tfstate-TU_IDENTIFICADOR_UNICO
export TF_VAR_api_access_cidrs='["TU_IP_PUBLICA/32"]'
export ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
export EKS_CLUSTER_ROLE_NAME='c237965a5969465l18246291t1w828868-LabEksClusterRole-tovXmHFhlDty'
export EKS_NODE_ROLE_NAME='c237965a5969465l18246291t1w828868888-LabEksNodeRole-p9TMKVotnj47'
export TF_VAR_cluster_role_arn="arn:aws:iam::$ACCOUNT_ID:role/$EKS_CLUSTER_ROLE_NAME"
export TF_VAR_node_role_arn="arn:aws:iam::$ACCOUNT_ID:role/$EKS_NODE_ROLE_NAME"
```

1. Prepara el bucket de estado. El Learner Lab deniega `s3:GetBucketObjectLockConfiguration`, que el recurso `aws_s3_bucket` de Terraform consulta al leer el bucket aunque Object Lock no esté activado. Por eso el bootstrap usa un script versionado e idempotente con AWS CLI. El script crea el bucket si falta y configura versionado, cifrado, bloqueo de acceso público y propiedad del dueño del bucket. Si un intento anterior de Terraform alcanzó a crear el bucket, el script completa su configuración.

```bash
bash terraform/aws/bootstrap/bootstrap.sh "$STATE_BUCKET"
```

2. Inicializa y aplica la plataforma. El plan permite revisar VPC, EKS, ECR y complementos antes del gasto; no debe incluir recursos `aws_iam_role`.

```bash
terraform -chdir=terraform/aws/platform init \
  -backend-config="bucket=$STATE_BUCKET" \
  -backend-config="key=dev/platform.tfstate" \
  -backend-config="region=$AWS_REGION"
terraform -chdir=terraform/aws/platform plan -var-file=../environments/dev.platform.tfvars
terraform -chdir=terraform/aws/platform apply -var-file=../environments/dev.platform.tfvars
```

3. Publica las imágenes Docker en ECR con un tag derivado de su contenido. Si las imágenes ya existen, el script las reutiliza. La construcción es una fase de empaquetado independiente del `terraform apply` de la aplicación.

```bash
export TF_VAR_image_tag="$(bash scripts/push-images.sh dev)"
```

4. Inicializa y aplica la aplicación. Terraform comprueba que ambas imágenes existan, obtiene el token de EKS con AWS CLI y despliega frontend, backend, Redis, HPA, PDB y RBAC. En `dev`, Redis usa `emptyDir` temporal.

```bash
terraform -chdir=terraform/aws/application init \
  -backend-config="bucket=$STATE_BUCKET" \
  -backend-config="key=dev/application.tfstate" \
  -backend-config="region=$AWS_REGION"
terraform -chdir=terraform/aws/application plan -var-file=../environments/dev.application.tfvars
terraform -chdir=terraform/aws/application apply -var-file=../environments/dev.application.tfvars
```

5. Comprueba el resultado y abre el dashboard. `port-forward` se ejecuta desde tu equipo, así que el servicio sigue siendo privado dentro del clúster.

```bash
aws eks update-kubeconfig --region "$AWS_REGION" --name netflix-lab-dev
kubectl -n netflix-lab get pods,hpa
kubectl -n netflix-lab port-forward svc/frontend 8080:80
```

Abre `http://localhost:8080`. Para probar el HPA, consulta `kubectl -n netflix-lab top pods` y activa el Job de k6 con `terraform -chdir=terraform/aws/application apply -var-file=../environments/dev.application.tfvars -var='enable_loadtest_job=true'`. Al terminar, vuelve a aplicar con `-var='enable_loadtest_job=false'` para quitar el Job. Una réplica de backend en `dev` permite observar escalado, pero no alta disponibilidad real.

## Destrucción y estado

Destruye primero la aplicación y luego la plataforma; conserva el bucket S3 si repetirás el laboratorio. El bucket versionado conserva versiones antiguas de estado, que ocupan espacio.

```bash
terraform -chdir=terraform/aws/application destroy -var-file=../environments/dev.application.tfvars
terraform -chdir=terraform/aws/platform destroy -var-file=../environments/dev.platform.tfvars
```

Comprueba en la consola de AWS que no queden clústeres EKS, instancias EC2, volúmenes EBS o recursos ECR del laboratorio. La desaparición de los nodos no implica que el control plane haya dejado de facturar; espera a que `terraform destroy` termine. **No borres los roles precreados del lab.** El backend S3 usa versionado y bloqueo con archivo `.tflock`; no ejecutes dos `apply` sobre el mismo estado al mismo tiempo.

## Relación con los capítulos 1–10 del libro

La referencia es la [segunda edición de *Infrastructure as Code* de Kief Morris](https://www.oreilly.com/library/view/infrastructure-as-code/9781098114664/). Esta tabla indica qué evidencia deja el proyecto, sin afirmar que cada capítulo esté agotado:

| Capítulos | Concepto aplicado | Evidencia |
|---|---|---|
| 1–2 | Reproducibilidad, recursos desechables y cambios pequeños | `terraform/aws/`, parámetros por entorno y destrucción por sesión |
| 3–4 | Recursos de cómputo, red y almacenamiento definidos como código | Módulos `network`, `eks`, `ecr` y script de bootstrap del bucket de estado |
| 5–6 | Stacks pequeños y entornos con código reutilizable | Bootstrap separado, stacks `platform` y `application`; archivos `dev`/`prod` |
| 7 | Configuración externa y secretos fuera del repositorio | `.tfvars` sin secretos, variables de entorno y roles IAM |
| 8–9 | Validación continua y previsualización de cambios | Workflow `terraform fmt`/`validate`, `terraform plan` antes de `apply` |
| 10 | Empaquetado y ejecución de aplicaciones | Imágenes inmutables en ECR y módulo Kubernetes reutilizado |

Queda pendiente ejecutar `plan`/`apply` con una cuenta Academy que autorice EKS y verificar el comportamiento del clúster real. La validación de CI comprueba sintaxis y esquemas, no sustituye esta prueba de integración.
