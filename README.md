# Netflix Lab — Cloud Computing

Laboratorio académico de una aplicación cloud-native con frontend Nginx, API Node.js y Redis. Permite observar pods, sondas de salud, réplicas y HPA desde un dashboard.

**El CI se ejecuta en GitHub sin credenciales AWS. El despliegue AWS se automatiza desde tu computadora usando la sesión temporal de Vocareum.** Terraform define los recursos; el coordinador selecciona stacks y parámetros y ejecuta sus operaciones.

- [Informe técnico: arquitectura, evolución, decisiones y resultados](docs/INFORME_TECNICO.md).
- [Pruebas, reportes y funcionamiento del CI](docs/PRUEBAS.md).

## Arquitectura y entornos

```text
Navegador → localhost:8080 (kubectl port-forward)
                         ↓
                  frontend / Nginx
                         ↓ /api/
                  backend / Node.js → Redis (visitas)
                         ↓
                  API de Kubernetes (pods y HPA)

AWS: VPC + EKS/EC2 + ECR + S3 (estado) + CloudWatch (logs de EKS)
Local: KinD + módulo de aplicación compartido
```

| Configuración | Nodos workers | Backend / HPA | Frontend | Redis |
|---|---:|---|---:|---|
| AWS `dev` | 1 × `t3.medium` | 1–2 réplicas | 1 | Temporal (`emptyDir`) |
| AWS `prod` | 2 × `t3.medium` | 2–4 réplicas | 2 | Temporal (`emptyDir`) |
| KinD local, valores predeterminados | 2 | 3–10 réplicas | 2 | PVC local |

`prod` es un perfil de demostración de mayor capacidad, no una arquitectura productiva validada. En AWS se usan dos subredes públicas sin NAT Gateway ni balanceador público. La API de EKS se restringe a los CIDR administrativos. El contador Redis se pierde al recrear su pod.

## 1. Requisitos

Para pruebas con contenedores: **Docker y Docker Compose**. Para el coordinador: **Linux/WSL, Python 3, Bash, Terraform ≥ 1.10, AWS CLI v2 y kubectl**. Node.js 20 es la versión de las imágenes y del CI; no necesitas instalarlo localmente si usas Compose.

Comprueba las herramientas:

```bash
terraform version
aws --version
python3 --version
docker info
docker compose version
kubectl version --client
```

Instalación: [Terraform](https://developer.hashicorp.com/terraform/install), [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html), [Docker](https://docs.docker.com/engine/install/) y [kubectl](https://kubernetes.io/docs/tasks/tools/). KinD solo es necesario para el entorno local completo.

Ejecuta los comandos siguientes desde la raíz del repositorio, `netflix-lab/`.

## 2. Ejecutar pruebas sin AWS

```bash
LOCAL_UID="$(id -u)" LOCAL_GID="$(id -g)" \
  docker compose -f backend/compose.test.yaml up \
  --abort-on-container-exit --exit-code-from tests
```

Ejecuta las 13 pruebas unitarias y las 6 de integración con un Redis dedicado. Los reportes JUnit y de texto/cobertura quedan en `backend/reports/`.

```bash
docker compose -f backend/compose.test.yaml down --volumes
python3 -m unittest discover -s scripts/tests -v
```

El último comando ejecuta las 30 regresiones del coordinador con AWS, Terraform y Docker simulados. No requiere credenciales. Consulta [PRUEBAS.md](docs/PRUEBAS.md) para ejecutar cada suite por separado e interpretar resultados.

## 3. Configurar la sesión de Vocareum

1. Pulsa **Start Lab** y espera a que el laboratorio esté listo.
2. Abre **AWS Details → AWS CLI**.
3. Crea o actualiza `~/.aws/credentials` con los tres valores de la sesión:

```ini
[default]
aws_access_key_id = TU_ACCESS_KEY
aws_secret_access_key = TU_SECRET_KEY
aws_session_token = TU_SESSION_TOKEN
```

Las credenciales se guardan fuera del repositorio. Al expirar, reemplaza los tres valores. Puedes seleccionar un perfil nombrado con `AWS_PROFILE` o `--profile NOMBRE` en el coordinador.

```bash
aws configure list
aws sts get-caller-identity
```

Verifica la cuenta y la procedencia de las credenciales: variables de entorno de otra sesión pueden tomar prioridad sobre el archivo. Cada integrante debe utilizar los roles y el estado correspondientes a su propia cuenta.

El laboratorio debe permitir EKS y disponer de roles compatibles para clúster y nodos, con `iam:PassRole`. El proyecto reutiliza esos roles; no crea roles IAM.

## 4. Desplegar en AWS con un comando

### Elegir configuración

```bash
bash scripts/aws-lab.sh config --env dev
bash scripts/aws-lab.sh --help
```

`config` es offline: muestra los archivos explícitos/predeterminados y las claves de estado, sin consultar AWS. Las operaciones autenticadas también recuperan las rutas guardadas de la cuenta.

Selecciona el entorno para los comandos de esta sección:

```bash
ENVIRONMENT=dev
# Para el perfil de mayor capacidad, utiliza ENVIRONMENT=prod.
```

### Primer uso y bucket de estado

Si ya desplegaste antes, utiliza **el mismo bucket**. El coordinador intenta recuperarlo de la inicialización anterior de Terraform; también admite `STATE_BUCKET`. Puedes fijarlo explícitamente en el primer uso:

```bash
bash scripts/aws-lab.sh deploy --env "$ENVIRONMENT" --stack all \
  --bucket NOMBRE_REAL_DE_TU_BUCKET
```

Para una cuenta sin estado anterior:

```bash
bash scripts/aws-lab.sh deploy --env "$ENVIRONMENT" --stack all
```

El bucket predeterminado es `netflix-lab-tfstate-<cuenta>-dev`, compatible con las primeras sesiones del proyecto. El sufijo `dev` del nombre del bucket no impide usar `prod`: los estados se separan por claves:

```text
dev/platform.tfstate        dev/application.tfstate
prod/platform.tfstate       prod/application.tfstate
```

**`deploy` aplica su plan sin pedir `yes` y crea/actualiza recursos facturables.** El flujo es: verificar sesión y roles → pruebas → preparar S3 → aplicar plataforma → publicar imágenes → aplicar aplicación → esperar rollouts → comprobar frontend/API y contador Redis.

### Roles y configuración local opcional

Si la cuenta permite `iam:ListRoles`, el coordinador busca los roles cuyos nombres contienen `LabEksClusterRole` y `LabEksNodeRole`. Puedes proporcionar sus ARN exactos mediante flags o copiar `aws-lab.example.json` como `aws-lab.local.json` y completar los campos. Ese archivo está excluido de Git y **no debe contener claves ni tokens**.

```bash
bash scripts/aws-lab.sh deploy --env "$ENVIRONMENT" --stack all \
  --cluster-role-arn 'ARN_REAL_DEL_ROL_CLUSTER' \
  --node-role-arn 'ARN_REAL_DEL_ROL_NODOS'
```

Esto usa `iam:GetRole` para verificar confianza. No elimina una denegación explícita de políticas como `voc-cancel-cred`: en ese caso renueva las credenciales y revisa la restricción del laboratorio con el docente. Para fijar el acceso administrativo se admite `api_access_cidrs` en el JSON local o `--api-access-cidrs '["TU_IP/32"]'`; si se omite, se detecta tu IPv4 pública.

### Consultar y abrir el dashboard

```bash
bash scripts/aws-lab.sh status --env "$ENVIRONMENT"
bash scripts/aws-lab.sh dashboard --env "$ENVIRONMENT"
```

Abre **http://localhost:8080** y mantén la terminal abierta. El coordinador utiliza un kubeconfig propio en `.aws-lab/<cuenta>/<entorno>/`; no reemplaza tu configuración global. Detén el port-forward con `Ctrl+C`. Pulsa **Enviar tráfico constante** para observar peticiones y visitas.

## 5. Actualizar parámetros y operar por stack

Los recursos se definen una sola vez y cada entorno aporta sus parámetros:

```text
terraform/aws/environments/dev.platform.tfvars
terraform/aws/environments/dev.application.tfvars
terraform/aws/environments/prod.platform.tfvars
terraform/aws/environments/prod.application.tfvars
```

`platform` configura red, versión EKS, tipo/cantidad de nodos, disco y retención de logs. `application` configura réplicas, CPU objetivo y límites del HPA, Redis y k6.

Después de desplegar, puedes cambiar el `.tfvars` de aplicación y operar únicamente ese stack:

```bash
bash scripts/aws-lab.sh plan --env "$ENVIRONMENT" --stack application
bash scripts/aws-lab.sh deploy --env "$ENVIRONMENT" --stack application
```

Para usar otro conjunto completo de parámetros sin copiar infraestructura:

```bash
bash scripts/aws-lab.sh deploy --env dev --stack application \
  --application-vars terraform/aws/environments/mi-dev.application.tfvars
```

Se admiten `.tfvars` y `.tfvars.json`; ambos stacks deben declarar el mismo `environment` y `region`. `region`, `environment` y el booleano de persistencia deben ser literales. Las rutas seleccionadas se conservan en el contexto local para sesiones posteriores.

Los archivos del entorno se pasan primero a Terraform y el JSON de ejecución generado se pasa después, fijando región/entorno, roles, CIDR, imagen y contrato con plataforma. Los demás parámetros siguen proviniendo del archivo seleccionado. El [informe técnico](docs/INFORME_TECNICO.md) explica la precedencia y la separación de estados.

`plan` no crea el bucket ni publica imágenes. Si aún no existe el estado remoto:

```bash
bash scripts/aws-lab.sh bootstrap --env "$ENVIRONMENT"
bash scripts/aws-lab.sh plan --env "$ENVIRONMENT" --stack platform
```

El plan de aplicación necesita plataforma e imágenes publicadas. Puede usar `--image-tag TAG`; `deploy` calcula/publica el tag del código local. No es posible resolver todos los data sources de aplicación antes de crear su plataforma.

## 6. Destruir y volver a otra sesión

```bash
bash scripts/aws-lab.sh destroy --env "$ENVIRONMENT" --stack all
```

**`destroy` elimina sin confirmación interactiva primero `application` y después `platform`.** Si falla la primera etapa, no continúa con la segunda. No construye imágenes ni crea el bucket. Los roles precreados y el bucket versionado permanecen.

Espera a que termine y comprueba en AWS que no queden recursos facturables del proyecto. EKS y EC2 consumen crédito mientras existen; `prod` consume más que `dev`. Cerrar el navegador, detener el port-forward o finalizar la sesión de Vocareum no garantiza su eliminación. S3 puede conservar un consumo pequeño; su eliminación manual debe realizarse después de destruir los stacks.

En otra sesión renueva las credenciales y reutiliza el mismo entorno, cuenta, perfil y bucket. No hace falta volver a escribir todos los `export`: el contexto local guarda datos no secretos y Terraform conserva el estado en S3. Si tu IP cambió, actualiza el acceso mediante `deploy --stack platform` antes de operar la aplicación. Un fallo parcial se recupera reejecutando la operación con credenciales vigentes o destruyendo los stacks.

## 7. Laboratorio completo local con KinD

Instala [KinD](https://kind.sigs.k8s.io/docs/user/quick-start/) además de Docker, Terraform y kubectl. Este entorno no consume crédito AWS:

```bash
terraform -chdir=terraform init
terraform -chdir=terraform plan
terraform -chdir=terraform apply
kubectl --context kind-netflix-lab -n netflix-lab get pods,hpa
kubectl --context kind-netflix-lab -n netflix-lab port-forward svc/frontend 8080:80
```

Accede a **http://localhost:8080**. Para eliminarlo, detén el port-forward y ejecuta:

```bash
terraform -chdir=terraform destroy
```

Si usaste variables o archivos personalizados, vuelve a pasarlos en los comandos de actualización y destrucción. El kubeconfig generado por KinD es local y no se versiona.

## 8. GitHub Actions y evidencias

El workflow [CI - tests and Terraform](.github/workflows/terraform-validate.yml) se activa con PR, push a `main` o ejecución manual. El botón **Run workflow** requiere que la configuración esté publicada en la rama predeterminada. Un commit local no ejecuta Actions; un push a una rama sin PR tampoco lo activa con los eventos actuales.

Una prueba fallida hace fallar `Backend tests` y omite la validación dependiente de Terraform. Los reportes se descargan en **Actions → ejecución → Artifacts → backend-test-reports** durante 14 días. Para impedir también el merge, configura ese check como obligatorio en las reglas de `main`.

Se verificaron localmente las 49 pruebas y los tres stacks Terraform. En AWS se comprobó una actualización automatizada de `prod`, rollouts y respuestas HTTP con contador creciente. La ejecución remota del CI, la recuperación por kubelet y el escalado efectivo bajo k6 requieren sus propias evidencias. El código del Job k6 está en `terraform/modules/application/loadtest.tf` y se activa con `enable_loadtest_job`; `loadtest/k6-job.yaml` conserva la ejecución manual opcional del laboratorio local.

## Estructura

```text
.github/workflows/             CI sin credenciales AWS
backend/                       API, Dockerfile, pruebas y Compose de testing
frontend/                      Dashboard, Nginx y Dockerfile
scripts/aws-lab.sh              Entrada del coordinador AWS
scripts/aws_lab.py              Operación local de stacks por cuenta/entorno
scripts/push-images.sh          Construcción y publicación ECR
scripts/tests/                 Regresiones del coordinador
terraform/                     Root KinD y módulos compartidos
terraform/aws/bootstrap/       Preparación de S3 con AWS CLI
terraform/aws/platform/        Stack de infraestructura AWS
terraform/aws/application/     Stack de aplicación EKS
terraform/aws/environments/    Parámetros dev/prod
loadtest/                      Job k6 manual opcional para KinD
docs/PRUEBAS.md                Guía de testing y reportes
docs/INFORME_TECNICO.md         Explicación detallada y evidencia
aws-lab.example.json           Referencia de configuración local sin credenciales
```
