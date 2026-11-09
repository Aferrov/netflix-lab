# Informe técnico — Netflix Lab

## 1. Objetivo y alcance

El proyecto del curso de Cloud Computing integra una aplicación en contenedores con infraestructura declarativa, pruebas automatizadas y operación de Kubernetes. La aplicación es un laboratorio didáctico: permite observar pods, peticiones, contador de visitas, sondas y HPA desde un dashboard.

La solución ofrece tres formas de trabajo:

1. **Pruebas aisladas:** Node.js y Redis en Compose, sin AWS.
2. **Laboratorio local completo:** Kubernetes con KinD y Terraform.
3. **AWS Learner Lab:** EKS y servicios AWS aprovisionados con Terraform y operados por un coordinador en la computadora del estudiante.

El CI en GitHub valida el código sin credenciales AWS. La entrega a AWS se automatiza desde el equipo local porque el laboratorio usa sesiones temporales y restringe la creación de roles IAM. Esta separación es una decisión del proyecto: no hay despliegue desde runners de GitHub ni sincronización automática de credenciales de Vocareum.

Las instrucciones operativas están en el [README](../README.md); el detalle de ejecución y reportes de testing está en [PRUEBAS.md](PRUEBAS.md).

## 2. Evolución de la solución

### 2.1. Punto de partida

La aplicación ya tenía frontend, backend, Redis y experimentos de Kubernetes. Existían manifiestos YAML y un script imperativo para construir imágenes y ejecutar `kubectl apply`.

El proyecto incorporó un módulo de aplicación compartido y un root Terraform para KinD. Después se añadieron roots AWS separados para plataforma y aplicación, repositorios ECR, estado remoto y parámetros por entorno.

### 2.2. Trabajo realizado durante esta etapa

- Se revisó la compatibilidad de EKS, IAM, S3 y almacenamiento con AWS Academy/Vocareum.
- Se ejecutaron las etapas de Terraform y publicación de imágenes en la cuenta del laboratorio.
- Se incorporaron pruebas unitarias e integración con reportes y cobertura.
- Se amplió GitHub Actions para ejecutar esas pruebas antes de validar Terraform.
- Se habilitó la ejecución manual del CI.
- Se creó un coordinador local con selección de entorno, stack y archivos de parámetros.
- Se ampliaron parámetros de infraestructura y aplicación que estaban fijos.
- Se adaptaron `dev` y `prod` para Redis temporal sin un rol EBS CSI adicional.
- Se diagnosticó y corrigió una colisión de variables de entorno en EKS.
- Se verificó una actualización automatizada real del stack de aplicación de `prod`.
- Se consolidó la documentación y se retiraron artefactos antiguos sustituidos por el flujo declarativo.

## 3. Arquitectura de la aplicación

```text
Navegador
   │ port-forward local
   ▼
Service frontend → pods Nginx
   │ /api/ (proxy)
   ▼
Service backend → pods Node.js
   ├── Service redis → pod Redis → contador visits
   └── API de Kubernetes → información de pods y HPA
```

### Frontend

`frontend/index.html` contiene el dashboard. Nginx sirve los archivos y enruta `/api/` hacia el Service de backend. El proxy usa resolución DNS periódica y conexiones independientes para permitir que Kubernetes distribuya las solicitudes entre réplicas.

El dashboard muestra estado, reinicios, nodo, réplicas y CPU del HPA cuando hay métricas. También permite enviar tráfico y provocar fallos para experimentos. La aplicación se accede por `kubectl port-forward`; no se crea un balanceador público.

### Backend

`backend/server.js` usa módulos incluidos en Node.js, sin dependencias de ejecución externas. Implementa:

| Endpoint | Función |
|---|---|
| `GET /healthz` | Liveness; devuelve 500 tras simular un estado enfermo. |
| `GET /ready` | Readiness; devuelve 503 tras simular indisponibilidad. |
| `GET /api/info` | Identidad del pod, peticiones atendidas, uptime y visitas Redis. |
| `GET /api/work?ms=80` | Trabajo CPU controlado para experimentos de carga. |
| `GET /api/cluster` | Resumen de pods y HPA del namespace. |
| `POST /api/pods/delete?name=...` | Solicita borrar un pod del namespace. |
| `POST /api/crash` | Termina el proceso para experimentar con reinicios. |
| `POST /api/sick` | Hace fallar liveness. |
| `POST /api/unready` | Hace fallar readiness. |

El contador de peticiones atendidas pertenece a cada proceso. El contador de visitas se comparte entre réplicas mediante `INCR` de Redis. Si Redis falla, `/api/info` sigue disponible con `visits: null`; la verificación de despliegue rechaza ese estado degradado como resultado exitoso.

### Redis

El módulo admite PVC o `emptyDir`. En AWS, ambos entornos versionados usan `redis_persistence_enabled = false`. Los datos sobreviven a un reinicio del contenedor en el mismo pod, pero se pierden si se recrea el pod. La opción de append-only utiliza el directorio del volumen; no convierte un `emptyDir` en almacenamiento persistente entre pods.

KinD conserva por defecto un PVC local. Su creación usa `wait_until_bound = false` para evitar que Terraform espere el enlace de un volumen `WaitForFirstConsumer` antes de crear el pod consumidor.

## 4. Infraestructura y patrón de stacks

### 4.1. Diferencia entre módulo, stack y entorno

- Un **módulo** encapsula recursos reutilizables, como red, EKS o aplicación.
- Un **stack AWS** es un root Terraform con ciclo de vida y estado propios.
- Un **entorno** es una instancia configurada de esos stacks, por ejemplo `dev` o `prod`.

En AWS existen dos roots independientes. En KinD, plataforma y aplicación se componen como módulos dentro de un único root y estado. Esta distinción evita confundir separación de archivos con separación real de estados.

### 4.2. Stack platform

`terraform/aws/platform/` define:

- VPC con DNS, Internet Gateway, tabla de rutas y dos subredes públicas en zonas distintas.
- Clúster EKS con endpoint privado y público restringido por CIDR.
- Grupo administrado de nodos EC2.
- Repositorios ECR para backend y frontend.
- Logs de API, auditoría y autenticación de EKS en CloudWatch.
- Metrics Server para métricas de recursos y HPA.
- Complementos EBS/Pod Identity solo si se proporciona un rol compatible.

Los roles de EKS y nodos pertenecen al laboratorio y se reciben como parámetros. El rol del clúster debe confiar en `eks.amazonaws.com`; el de nodos, en `ec2.amazonaws.com`, y deben ser distintos. El coordinador comprueba confianza e identidad de cuenta, pero los permisos efectivos de creación y `PassRole` siguen determinados por AWS.

Los outputs de plataforma incluyen nombre del clúster, endpoint, URLs ECR y VPC. El coordinador consume esos outputs para las siguientes etapas.

### 4.3. Stack application

`terraform/aws/application/` obtiene el clúster e imágenes publicados y utiliza el módulo `terraform/modules/application/` para definir:

- Namespace, Deployments y Services.
- Requests y limits de CPU y memoria.
- Probes de backend/frontend y readiness TCP de Redis.
- ServiceAccount, Role y RoleBinding del backend.
- HPA y PodDisruptionBudget.
- ConfigMap y Job opcional de k6.
- PVC/StorageClass solamente cuando se activa persistencia.

Las imágenes del backend y frontend se fijan mediante digest. El nombre del clúster y los repositorios se reciben del contrato con plataforma; los valores predeterminados conservan compatibilidad con los comandos manuales anteriores.

### 4.4. Parámetros externos y reutilización

| Parámetro | dev | prod |
|---|---|---|
| Región | `us-east-1` | `us-east-1` |
| Red | `10.42.0.0/16` | `10.43.0.0/16` |
| Nodos | 1 × `t3.medium` | 2 × `t3.medium` |
| Disco por nodo | 20 GiB | 20 GiB |
| Retención de logs EKS | 7 días | 7 días |
| Réplicas backend | 1–2 | 2–4 |
| Réplicas frontend | 1 | 2 |
| Objetivo CPU HPA | 50 % de requests | 50 % de requests |
| Redis persistente | No | No |

Estos archivos `.tfvars` instancian la misma definición. También se admiten archivos completos alternativos con `--platform-vars` y `--application-vars`. Cambiar el máximo del HPA actualiza aplicación sin aplicar plataforma; cambiar nodos corresponde a plataforma.

Se parametrizaron además el disco del nodo, retención de logs, objetivo CPU y tamaño Redis. El tamaño Redis solo tiene efecto cuando se usa PVC; `redis_storage_size = "1Gi"` no reserva EBS si la persistencia está desactivada.

### 4.5. Relación con Infrastructure as Code, de Kief Morris

| Concepto aplicado | Implementación |
|---|---|
| Infraestructura definida y versionada | Recursos `.tf`, configuración externa y scripts en Git. |
| Recursos reproducibles y desechables | Creación, actualización y destrucción mediante Terraform. |
| Stacks pequeños | Estados separados para plataforma y aplicación AWS. |
| Stacks reutilizables | Mismos roots/módulos para dev/prod; diferencias en parámetros. |
| Configuración de instancias | `.tfvars`, datos locales de cuenta y credenciales separadas. |
| Validación progresiva | Pruebas, `fmt`, `validate`, `plan`, aplicación y comprobación HTTP. |
| Empaquetado y plataforma de ejecución | Imágenes en ECR y ejecución en EKS. |

La separación reduce el alcance de los cambios y permite distintos ciclos de vida. No implica una transacción entre stacks: si una etapa falla, hay que reanudar o destruir usando los estados existentes. Tampoco demuestra por sí sola alta disponibilidad o paridad operacional entre entornos.

## 5. Estado remoto y bootstrap S3

Cada entorno conserva dos claves:

```text
dev/platform.tfstate       dev/application.tfstate
prod/platform.tfstate      prod/application.tfstate
```

El bucket tiene versionado, cifrado y bloqueo de acceso público. Terraform usa bloqueo mediante `.tflock`; esto requiere Terraform ≥ 1.10. El bucket no se elimina al destruir los stacks, por lo que puede reutilizarse en otra sesión.

Se utiliza `terraform/aws/bootstrap/bootstrap.sh` porque la política del laboratorio observada denegaba `s3:GetBucketObjectLockConfiguration`, una consulta realizada por el recurso de bucket del proveedor. El script AWS CLI crea el bucket cuando falta y converge su configuración sin depender de esa lectura. Comprueba propietario y región y se puede repetir.

Reutilizar el estado correcto es esencial. El coordinador recupera el backend manual anterior cuando puede, admite un bucket explícito y rechaza cambiar silenciosamente un bucket ya registrado. Las inicializaciones locales se separan por cuenta, entorno y stack; no se usa un workspace para representar cada entorno.

## 6. Automatización local del despliegue

### 6.1. Responsabilidades

`scripts/aws-lab.sh` es una entrada Bash que ejecuta `scripts/aws_lab.py`. Python utiliza únicamente su biblioteca estándar y coordina herramientas existentes mediante listas de argumentos, sin construir comandos de shell con datos interpolados.

Las operaciones disponibles son `config`, `bootstrap`, `plan`, `deploy`, `status`, `dashboard` y `destroy`. Se seleccionan entorno y stack mediante flags. El script coordina; Terraform conserva la definición declarativa de los recursos.

### 6.2. Secuencia de deploy

1. Verificar herramientas y versión de Terraform.
2. Autenticar con STS e identificar la cuenta.
3. Recuperar el contexto local y comprobar región, entorno y bucket.
4. Identificar roles existentes y determinar CIDR administrativo.
5. Ejecutar regresiones del coordinador y pruebas del backend.
6. Preparar/reutilizar el bucket S3.
7. Planificar y aplicar plataforma si está seleccionada.
8. Consumir outputs y publicar las imágenes.
9. Planificar y aplicar aplicación si está seleccionada.
10. Esperar los rollouts y verificar frontend/API/Redis.

Los planes guardados se aplican sin una confirmación interactiva adicional. `plan` es la operación de inspección: no crea el bucket, no publica imágenes ni aplica cambios. Para planificar aplicación deben existir plataforma e imágenes; los data sources de AWS no se sustituyen por resultados hipotéticos.

### 6.3. Configuración y precedencia

La configuración compartida va en `.tfvars`. Los datos de cuenta opcionales van en `aws-lab.local.json`, excluido de Git. Las credenciales se mantienen en AWS CLI o en su cadena estándar de proveedores; no se almacenan en esos archivos.

La selección de archivos sigue: flags → JSON local → rutas guardadas por cuenta/entorno → archivos estándar. Los datos de cuenta siguen: flags → JSON local → variables de entorno admitidas → metadatos guardados → detección automática.

Para Terraform se pasa el archivo de entorno y después un JSON de ejecución generado, que fija región/entorno y parámetros dinámicos. Esto evita depender de `TF_VAR_*`, que tiene menor prioridad que un `.tfvars`. No se copian valores de réplicas o nodos dentro del script.

`region` y `environment` deben coincidir entre stacks. El coordinador inspecciona sus literales y el booleano de persistencia; Terraform interpreta el resto del archivo. Si hay varios roles candidatos o no existe permiso para listarlos, deben proporcionarse los ARN explícitos.

### 6.4. Estado local, errores y destrucción

`.aws-lab/<cuenta>/<entorno>/` conserva rutas de parámetros, bucket, roles, tag publicado, kubeconfig y directorios de datos Terraform. Estos metadatos no incluyen claves ni tokens y no sustituyen el estado S3.

El lock local evita operaciones simultáneas desde el mismo checkout. El bloqueo S3 protege cada estado entre equipos. Un fallo detiene la secuencia; no se destruyen automáticamente los recursos creados por etapas anteriores.

La destrucción se hace en orden inverso: aplicación y después plataforma. Se omiten estados sin recursos administrados. No se permite eliminar solo plataforma mientras el estado de aplicación tenga recursos. Si falla la eliminación de aplicación, plataforma permanece para permitir recuperación.

El acceso al dashboard usa un kubeconfig propio y un contexto explícito. Si cambia la IP del equipo, debe actualizarse el acceso de plataforma antes de operar Kubernetes desde esa conexión.

## 7. Contenedores e imágenes

Los Dockerfiles utilizan Node.js 20 Alpine y Nginx Alpine. El backend se ejecuta como usuario `node`. No necesita instalar paquetes de aplicación en la imagen porque usa módulos nativos.

`scripts/push-images.sh` calcula un tag `src-<hash>` a partir del contenido de Dockerfiles y código. Las imágenes se construyen para `linux/amd64`, se publican en ECR y se reutilizan si el tag ya existe. Los repositorios usan tags inmutables y una política para conservar imágenes recientes.

El coordinador pasa las URLs ECR de los outputs de plataforma; el publicador comprueba que correspondan al registro de la cuenta/región actual. Kubernetes consume los digests resueltos por Terraform. Una modificación solo de parámetros Terraform no exige reconstruir imágenes.

La construcción/publicación se separa del `apply` de aplicación: si falla el empaquetado, no se intenta desplegar una referencia inexistente.

## 8. Pruebas automatizadas

### 8.1. Cambios para hacer el backend comprobable

Se introdujo `createBackend()`, que crea servidores con estado independiente. Importar el módulo no abre puertos ni registra señales. Redis, consulta de Kubernetes y namespace se pueden sustituir en pruebas unitarias. La ejecución normal mantiene puerto 8080 y manejo de SIGTERM.

Se añadió validación de `/api/work`: valores no enteros o negativos reciben 400, conservando 50 ms predeterminados y máximo de 1000 ms. Esto evita un trabajo que no termina al recibir `NaN`. El contador también rechaza respuestas Redis malformadas o enteros no seguros.

### 8.2. Trece pruebas unitarias

- Tres sobre el contador: comando INCR, conversión/validación y propagación de errores.
- Dos sobre parámetros CPU: valores válidos/límite y rechazo de entradas inválidas.
- Tres sobre presentación de pods: readiness, reinicios y estados de creación/terminación.
- Una sobre disponibilidad degradada sin Redis.
- Dos sobre respuestas de clúster/HPA con dependencias controladas.
- Dos sobre validación y namespace de borrado de pods.

Se usan `node:test` y `node:assert/strict`, sin framework externo. Los dobles de Kubernetes permiten aislar la lógica; no prueban permisos efectivos contra un EKS real.

### 8.3. Seis pruebas de integración

- Contador compartido entre dos instancias reales del servidor.
- Ocho incrementos concurrentes sin perder visitas.
- Sondas que no inflan el contador de peticiones.
- Readiness/liveness independientes y estado aislado entre servidores.
- Trabajo CPU y errores 400 por parámetros inválidos.
- Respuestas JSON para rutas inexistentes y acceso Kubernetes no disponible.

Las pruebas del contador utilizan HTTP y el cliente TCP del backend contra Redis real. No aceptan `visits: null` como integración exitosa. Se comprobó que fallan cuando Redis no está disponible. Compose mantiene este Redis aislado del despliegue AWS.

### 8.4. Treinta regresiones del coordinador

Python `unittest` comprueba selección de parámetros, coherencia de región/entorno, estados, recuperación de contexto, roles, CIDR, outputs, prioridad de inputs, publicación y orden de operaciones. También cubre credenciales fallidas, fallos de pruebas/aplicación y protección del orden de destrucción.

AWS CLI, Terraform, kubectl y Docker se simulan en estas pruebas. Su resultado demuestra el comportamiento del coordinador bajo escenarios controlados, no la disponibilidad de permisos de una cuenta real.

### 8.5. Reportes

Cada suite Node genera JUnit XML y texto con resultados y cobertura. El ejecutor conserva códigos de salida distintos de cero y genera diagnóstico ante aserciones fallidas. La cobertura nativa incluye archivos de pruebas; se debe revisar la fila de `server.js` y no sumar porcentajes de suites independientes.

No se impuso un mínimo de cobertura. Los resultados Python aparecen en logs; los artefactos JUnit/cobertura corresponden al backend. La guía de pruebas documenta cómo reproducir una ejecución correcta y otra deliberadamente fallida para obtener evidencia de bloqueo.

## 9. Continuous Integration con GitHub Actions

El archivo `.github/workflows/terraform-validate.yml` configura PR, push a `main` y `workflow_dispatch`. El runner prepara Node.js 20, Redis y Python 3.12, instala con `npm ci`, comprueba sintaxis y ejecuta las 49 pruebas.

La subida de reportes usa `always()` y retención de 14 días. El job de Terraform depende de `tests` y valida los roots local, AWS platform y AWS application mediante formato, inicialización sin backend y `validate`. Se verifica además la sintaxis de los scripts Bash.

Una prueba fallida falla el job y omite los jobs dependientes. Bloquear un merge requiere además una regla de protección de rama con checks obligatorios; no se obtiene únicamente por escribir el YAML.

GitHub no hereda `~/.aws/credentials` del equipo del estudiante. El CI no se conecta a AWS, publica imágenes ni crea EKS. El despliegue local vuelve a ejecutar pruebas antes de cambiar recursos. Se puede asociar un commit aprobado por CI con la versión que se despliega, pero el coordinador no consulta ni exige un check remoto aprobado.

## 10. Restricciones y problemas resueltos

### Terraform antiguo en PATH

Se detectaron dos instalaciones: una versión 1.9.8 en el directorio personal precedía a otra más nueva en `/usr/bin`. Se corrigió la resolución de PATH y se utilizó una versión compatible con el backend S3 y `use_lockfile`. Cambiar únicamente la restricción de versión no habría añadido esa funcionalidad.

### Cambios de backend

Durante la inicialización apareció `Backend configuration changed`. Fue necesario confirmar bucket, región y clave antes de reconfigurar. El coordinador separa sus directorios de inicialización y vincula el contexto al bucket para evitar cambios silenciosos de estado.

### Roles y sesiones de Vocareum

Los nombres completos de roles contienen prefijos/sufijos y dependen de la cuenta. La identidad de STS no reemplaza un rol de servicio EKS. Se observaron denegaciones de `iam:ListRoles` asociadas a una política `voc-cancel-cred`; resolver la sesión/restricción es independiente de proporcionar ARN explícitos. `GetRole` y `PassRole` también requieren permisos.

### Repositorios ECR inexistentes

Una imagen pudo construirse localmente, pero su publicación falló porque faltaba el repositorio. Se completó plataforma antes de publicar. El coordinador impone esa dependencia y utiliza outputs reales.

### Persistencia Redis en prod

El perfil inicial activaba PVC en `prod`, pero no se disponía de un rol EBS CSI compatible. Se cambió a Redis temporal mediante un parámetro, manteniendo el mismo módulo, los dos nodos y las réplicas del entorno. No se retiró la validación de persistencia: sigue exigiendo el rol cuando un usuario la activa.

### Colisión REDIS_PORT en Kubernetes

Tras crear la aplicación de `prod`, los pods estaban listos y el frontend respondía, pero la comprobación final rechazaba `visits: null`.

El diagnóstico real mostró `REDIS_PORT=tcp://<cluster-ip>:6379`, una variable que Kubernetes inyecta por el Service `redis`. El backend esperaba un número; `Number(...)` devolvía `NaN`. Una conexión desde el mismo backend al puerto 6379 sí recibió `PONG`, descartando una indisponibilidad del servidor Redis en esa comprobación.

Se declaró `REDIS_PORT=6379` en el Deployment mediante Terraform, evitando la colisión. Se aplicó solo `application`, sin reconstruir imágenes ni aplicar plataforma. Esta incidencia muestra por qué las pruebas locales aisladas no reemplazan una verificación de despliegue real: Compose no inyectaba la variable con formato de Kubernetes.

## 11. Evidencia disponible y límites

| Comprobación | Resultado y alcance |
|---|---|
| Testing local | 13 unitarias, 6 de integración y 30 del coordinador aprobadas. |
| Fallos de testing | Una aserción temporal incorrecta produjo fallo y JUnit; Redis no disponible hizo fallar la integración. |
| Validaciones estáticas | `fmt`, `validate` de los tres roots, `actionlint`, `bash -n` y ShellCheck aprobados localmente. |
| Sesión dev anterior | La documentación previa registraba creación, comprobación HTTP/Kubernetes y destrucción manual de dev. No es un reporte automático de esta etapa. |
| Creación de aplicación prod | La salida real de la sesión mostró `13 added, 0 changed, 0 destroyed`, seguida del fallo inicial de comprobación Redis. |
| Corrección automatizada prod | `deploy --env prod --stack application` aplicó `0 added, 1 changed, 0 destroyed`. |
| Verificación prod | Rollouts de Redis/backend/frontend completos; `/` y `/api/info` pasaron; respuestas adicionales devolvieron visitas 2, 3, 4 y 5. |
| CI remoto | Configurado, pendiente de conservar evidencia de una ejecución de GitHub. |
| Autoscaling bajo carga | Configurado; no se ha documentado una ejecución k6 ni un cambio efectivo de réplicas en AWS. |
| Recuperación Kubernetes | Endpoints/probes implementados; falta evidencia del reinicio o sustitución por kubelet/controladores tras un fallo provocado. |
| Destrucción prod | El coordinador incluye la operación; esta sesión de actualización no acredita su ejecución. |

El HPA podía mostrar CPU desconocida inmediatamente después de reemplazar pods. El código y el estado de un recurso no demuestran que se haya realizado el experimento: es necesario recopilar métricas y resultados de ejecución.

## 12. Observabilidad, seguridad y costos

Metrics Server suministra CPU/memoria actuales y habilita HPA. El dashboard observa pods y HPA mediante RBAC limitado al namespace; el backend puede listar/consultar pods y solicitar su borrado para experimentos, y consultar HPA.

CloudWatch recibe logs del control plane de EKS con retención configurable. No se implementó una recopilación centralizada de logs de los contenedores ni un dashboard histórico de métricas de aplicación. Los logs de EKS no sustituyen a los de Nginx, Node.js o Redis.

Se mantienen credenciales fuera del repositorio, estados cifrados y versionados, bloqueo de acceso público de S3, acceso administrativo por CIDR y kubeconfig/contexto separado. No hay un secreto de aplicación Redis ni integración con Secrets Manager. El RBAC de demostración y los roles precreados deben explicarse de acuerdo con los permisos disponibles en el laboratorio.

EKS, nodos EC2, discos y otros servicios consumen crédito mientras existan. El tamaño de `prod` es mayor que `dev`; no se midieron costos reales en esta etapa. Destruir los stacks elimina los recursos administrados, pero el bucket y versiones de estado permanecen. Finalizar la sesión no equivale a destruirlos.

## 13. Organización y limpieza del repositorio

La documentación operativa quedó en README, las instrucciones de pruebas en `docs/PRUEBAS.md` y las decisiones/resultados en este informe. Se integró el contenido vigente de las guías anteriores y se retiraron planes de migración desactualizados y explicaciones con rutas locales inexistentes o afirmaciones sin evidencia.

Se retiraron el instalador Docker descargado, notas incompletas, el servidor de datos simulados y los manifiestos/script imperativos sustituidos por Terraform. El kubeconfig generado por KinD dejó de versionarse y permanece como archivo local ignorado. Se conserva el Job k6 manual utilizado por el output del laboratorio local, además del Job parametrizado de Terraform.

## 14. Pendientes del proyecto integrador

1. Ejecutar el CI remoto y conservar enlaces, reportes y evidencia del bloqueo ante fallos.
2. Trabajar mediante ramas y PR con checks requeridos cuando los permisos del repositorio lo permitan.
3. Ejecutar k6, observar aumento/reducción del HPA y analizar latencias, errores, CPU y memoria.
4. Demostrar recuperación de contenedores/pods y comportamiento de readiness/liveness en Kubernetes real.
5. Consolidar logs de aplicación, eventos y métricas durante la carga.
6. Registrar costos y evidencia de destrucción de cada entorno utilizado.
7. Justificar ante el curso la separación CI remoto/despliegue local o ampliar la entrega a un pipeline compatible con las restricciones del laboratorio.

Para una demostración de 15 minutos conviene llegar con EKS creado y mostrar un cambio pequeño, el CI, una actualización de aplicación y experimentos preparados. Crear el control plane desde cero puede consumir gran parte del tiempo disponible. Los resultados que aún no se ejecutaron deben presentarse como pendientes, no como evidencia obtenida.
