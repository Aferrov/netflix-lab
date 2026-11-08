# Laboratorio Cloud: Arquitectura Resiliente en Kubernetes con Infraestructura como Código (IaC)

**Migración a AWS:** el laboratorio EKS para un crédito AWS Academy de USD 50 se encuentra en [AWS_MIGRACION.md](AWS_MIGRACION.md). La [evidencia por capítulo del libro](EVIDENCIA_IAC_AWS.md) documenta qué se probó en AWS y qué quedó pendiente. La guía de abajo corresponde al entorno local KinD.

Este proyecto implementa una arquitectura de microservicios en **Kubernetes** gestionada de forma 100% declarativa mediante **Terraform (Infraestructura como Código - IaC)**, siguiendo los principios y patrones de diseño del libro *"Infrastructure as Code"* (Kief Morris, 2da Edición).

Incluye autoescalado horizontal (**HPA**), tolerancia a fallos, balanceo de carga en múltiples nodos, almacenamiento persistente (**PVC**), inyección de caos y una suite de pruebas de estrés automáticas con **Grafana k6**.

---

## 🏛️ 1. Arquitectura del Sistema

El sistema se compone de dos capas desacopladas (**Composición de Stacks**):

| Capa / Módulo | Componente | Descripción | Réplicas |
|---|---|---|---|
| **Platform Stack** (`modules/cluster`) | **KinD Cluster** | Clúster multi-nodo local (1 control-plane + 2 workers). | 3 nodos |
| **Platform Stack** (`modules/cluster`) | **metrics-server** | Agente de telemetría para permitir lectura de CPU en el HPA. | 1 |
| **App Stack** (`modules/application`) | **frontend** | Nginx que sirve un Dashboard interactivo de observabilidad y caos. | 2 |
| **App Stack** (`modules/application`) | **backend** | API Node.js (sin dependencias) con RBAC para consultar la API de k8s. | 3 a 10 (HPA) |
| **App Stack** (`modules/application`) | **redis** | Base de datos persistente con volumen `ReadWriteOnce` (PVC). | 1 |
| **Testing** | **k6-stress** | Job de Kubernetes para pruebas de estrés bajo demanda. | 50 VUs |

```
                       [ Navegador / Usuario ]
                                  │
                       :8080 (port-forward)
                                  ▼
                    ┌───────────────────────────┐
                    │     Service: frontend     │
                    │   (Nginx - 2 réplicas)    │
                    └─────────────┬─────────────┘
                                  │ proxy_pass /api/
                                  ▼
                    ┌───────────────────────────┐
                    │     Service: backend      │
                    │  (Node.js - 3 a 10 pods)  │◄─── [ HPA: CPU > 50% ]
                    └──┬─────────────────────┬──┘
                       │                     │
      TCP / RESP direct│                     │ In-cluster RBAC API
                       ▼                     ▼
             ┌──────────────────┐    ┌─────────────────────┐
             │  Service: redis  │    │  Kubernetes API     │
             │   (PVC 100 Mi)   │    │  (Pods, HPA Status) │
             └──────────────────┘    └─────────────────────┘
```

---

## 📋 2. Requisitos Previos

1. **Docker:** Servicio de contenedores activo (`sudo systemctl start docker` o Docker Desktop).
2. **Terraform:** v1.5.0 o superior (`terraform -version`).
3. **kubectl:** CLI de Kubernetes (`kubectl version --client`).
4. **kind:** Kubernetes in Docker (`kind version`).

---

## 🚀 3. Guía de Ejecución desde Cero con Terraform

Toda la infraestructura (creación del clúster, instalación de telemetría, compilación de imágenes Docker y despliegue de microservicios) se orquesta de forma declarativa e idempotente.

### Paso 1: Ingresar a la carpeta de Terraform
```bash
cd terraform
```

### Paso 2: Inicializar el Stack
Descarga los proveedores (`tehcyx/kind`, `hashicorp/kubernetes`, `hashicorp/null`) e inicializa los módulos:
```bash
terraform init
```

### Paso 3: Previsualizar los Cambios (*Speculative Run* - Cap. 9)
```bash
terraform plan -var-file=environments/prod.tfvars
```
*Se mostrarán los 17 recursos que Terraform creará de forma ordenada respetando el grafo de dependencias.*

### Paso 4: Desplegar la Infraestructura (*Apply*)
```bash
terraform apply -var-file=environments/prod.tfvars -auto-approve
```
*Tiempo estimado: ~1.5 a 2 minutos.* Al finalizar imprimirá:
```text
Apply complete! Resources: 17 added, 0 changed, 0 destroyed.
```

---

## 🖥️ 4. Acceso al Dashboard de Observabilidad y Caos

Una vez concluido el despliegue, abre un túnel seguro hacia el frontend:
```bash
kubectl --context kind-netflix-lab -n netflix-lab port-forward svc/frontend 8080:80
```

Abre tu navegador en:
👉 **http://localhost:8080**

### Monitoreo en Tiempo Real (Terminal secundaria)
Deja corriendo en otra terminal:
```bash
# Ver distribución de pods en los distintos workers
kubectl --context kind-netflix-lab -n netflix-lab get pods -o wide -w

# Ver el estado y escala del HPA
kubectl --context kind-netflix-lab -n netflix-lab get hpa -w
```

---

## 🧪 5. Demostraciones Prácticas del Laboratorio

### A. Autoescalado Horizontal (HPA) con Prueba de Carga (k6)
1. En el dashboard o en tu terminal, ejecuta el Job de carga:
   ```bash
   kubectl --context kind-netflix-lab apply -f ../loadtest/k6-job.yaml
   ```
2. Observa la salida en vivo de k6:
   ```bash
   kubectl --context kind-netflix-lab -n netflix-lab logs -f job/k6-stress
   ```
3. **Qué observar:** 
   * k6 eleva la concurrencia a 50 usuarios virtuales quemando CPU en `/api/work?ms=80`.
   * El uso de CPU sobrepasa el **50%**.
   * El HPA escala automáticamente los pods del backend de **3 a hasta 10 réplicas**.
   * Las barras del dashboard muestran la distribución de tráfico entre los nuevos pods.
   * Al finalizar la prueba, tras la ventana de estabilización (60s), el clúster desescala a 3 pods.

### B. Auto-recuperación (Self-Healing)
* Con tráfico activo en el dashboard, haz clic en la **×** de cualquier pod del backend (o ejecuta `kubectl --context kind-netflix-lab -n netflix-lab delete pod <nombre>`).
* El ReplicaSet detecta la desviación del estado deseado y crea inmediatamente un reemplazo sin interrumpir el servicio.

### C. Pruebas de Salud (Liveness & Readiness Probes)
* **Crash:** Clic en *"Tumbar un pod"*. El proceso finaliza con código de error y el kubelet lo reinicia inmediatamente (aumenta el contador de restarts).
* **Liveness Fail:** Clic en *"Pod enfermo"*. `/healthz` responde HTTP 500; tras 3 fallos el kubelet destruye y reinicia el contenedor.
* **Readiness Fail:** Clic en *"Pod no listo"*. `/ready` responde HTTP 503; el pod se mantiene vivo pero el Service lo retira de los endpoints para que no reciba tráfico.

### D. Resiliencia de Datos y Modo Degradado (Redis)
1. Apaga el pod de Redis:
   ```bash
   kubectl --context kind-netflix-lab -n netflix-lab scale deploy redis --replicas=0
   ```
2. El dashboard mostrará *"Redis caído"*, pero el backend no colapsa (funciona en **modo degradado**).
3. Vuelve a encenderlo:
   ```bash
   kubectl --context kind-netflix-lab -n netflix-lab scale deploy redis --replicas=1
   ```
4. El nuevo pod se monta sobre el mismo **PersistentVolumeClaim (PVC)** y el contador de visitas continúa exactamente donde quedó.

### E. Actualización sin Caídas (Zero-Downtime Rolling Update)
```bash
kubectl --context kind-netflix-lab -n netflix-lab rollout restart deploy/backend
kubectl --context kind-netflix-lab -n netflix-lab rollout status deploy/backend
```
Gracias a `maxUnavailable: 0` y `maxSurge: 1`, los pods nuevos alcanzan el estado *Ready* antes de que se apaguen los anteriores.

---

## 🧹 6. Limpieza y Destrucción del Entorno (*Teardown*)

Para liberar todos los recursos de la máquina y cumplir con el ciclo de vida de IaC:
```bash
cd terraform
terraform destroy -var-file=environments/prod.tfvars -auto-approve
```

---

## 📁 7. Estructura del Repositorio

```text
netflix-lab/
├── README.md                            # Guía general de operación
├── EXPLICACION_IAC_PROYECTO.md          # Documento teórico-técnico detallado para el equipo
├── kind-config.yaml                     # Configuración base de KinD (referencia)
├── backend/                             # Microservicio API (Node.js sin dependencias)
│   ├── server.js
│   └── Dockerfile
├── frontend/                            # Dashboard interactivo (Nginx + JS Vanilla)
│   ├── index.html
│   ├── nginx.conf
│   └── Dockerfile
├── loadtest/                            # Script de prueba de carga
│   └── k6-job.yaml
└── terraform/                           # INFRAESTRUCTURA COMO CÓDIGO (IaC)
    ├── versions.tf                      # Providers (kind, kubernetes, null)
    ├── variables.tf                     # Variables de entrada parametrizables
    ├── main.tf                          # Composición de Stacks
    ├── outputs.tf                       # Comandos de acceso generados
    ├── environments/                    # Patrón Stack Configuration Files (Cap. 7)
    │   ├── dev.tfvars                   # Configuración para desarrollo (1 worker, 1 réplica)
    │   └── prod.tfvars                  # Configuración para producción (2 workers, HPA 3-10)
    └── modules/
        ├── cluster/                     # Stack de Plataforma (Cap. 3 y 5)
        │   ├── main.tf                  # Cluster KinD, metrics-server, carga de imágenes
        │   ├── variables.tf
        │   ├── outputs.tf
        │   └── versions.tf
        └── application/                 # Stack de Cargas de Trabajo (Cap. 5)
            ├── namespace.tf             # Namespace aislado con labels
            ├── rbac.tf                  # ServiceAccount, Role, RoleBinding
            ├── redis.tf                 # PVC, Deployment Recreate, Service
            ├── backend.tf               # Deployment RollingUpdate, Service, HPA v2, PDB v1
            ├── frontend.tf              # Deployment, Service
            ├── loadtest.tf              # ConfigMap k6, Job condicional
            ├── variables.tf
            ├── outputs.tf
            └── versions.tf
```
