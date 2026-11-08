# Documento Explicativo del Proyecto: Transformación a Infraestructura como Código (IaC)

> Este documento describe el laboratorio local KinD y su contexto original. Para los conceptos demostrados en AWS EKS, consulta [EVIDENCIA_IAC_AWS.md](EVIDENCIA_IAC_AWS.md).

**Curso:** Computación en la Nube (Cloud Computing)  
**Referencia Teórica:** *Infrastructure as Code: Dynamic Systems for the Cloud Age* (Kief Morris, 2da Edición) - Capítulos 3 al 9.  
**Proyecto:** Laboratorio de Resiliencia, Autoescalado (HPA) y Pruebas de Carga en Kubernetes.

---

## 🎯 1. Objetivo y Contexto del Proyecto

El objetivo de este proyecto es demostrar cómo diseñar, aprovisionar y operar una arquitectura en la nube de alta disponibilidad y autoescalado, aplicando las mejores prácticas de **Infraestructura como Código (IaC)**.

### El punto de partida (Antes de IaC)
Originalmente, el laboratorio operaba de manera **imperativa**:
* El clúster KinD se creaba con comandos de consola sueltos en terminal (`kind create cluster`).
* El parche de `metrics-server` se aplicaba manualmente con `kubectl patch`.
* El despliegue dependía de un script de Bash (`deploy.sh`) que ejecutaba `docker build`, `kind load` y `kubectl apply -f k8s/` de forma secuencial.

**Limitaciones académicas de este enfoque (según Kief Morris):**
* **Falta de Idempotencia:** Si el script fallaba a mitad de camino, dejaba el sistema en un estado inconsistente.
* **Antipatrón Copy-Paste Environments:** Si se requería un entorno de desarrollo (`dev`) y otro de producción (`prod`), la única opción era duplicar y editar los archivos YAML a mano, provocando **deriva de configuración (*Configuration Drift*)**.
* **Ausencia de Previsualización:** No existía forma de predecir el impacto de un cambio sin aplicarlo directamente en el clúster.

### El estado actual (Con IaC y Terraform)
Toda la infraestructura (plataforma + microservicios + observabilidad + pruebas de estrés) se gestiona de forma **declarativa**, **modular** e **idempotente** usando **Terraform**.

---

## 📚 2. Mapeo Teórico con el Libro de Kief Morris (Capítulos 3 al 9)

A continuación se detalla cómo cada capítulo del libro fue implementado directamente en el código del proyecto:

```
┌────────────────────────────────────────────────────────────────────────┐
│                   MAPA DE CONCEPTOS DE KIEF MORRIS                     │
├────────────────────────────────────────────────────────────────────────┤
│ Cap. 3: Infrastructure Platforms   ──► KinD Multi-Nodo + metrics-server│
│ Cap. 4: Everything as Code         ──► HCL Declarativo e Idempotente   │
│ Cap. 5: Infrastructure Stacks      ──► modules/cluster + application   │
│ Cap. 6: Environments with Stacks   ──► Patrón Reusable Stack           │
│ Cap. 7: Configuring Instances      ──► dev.tfvars vs prod.tfvars       │
│ Cap. 8: Continuously Test          ──► Pirámide de Pruebas de IaC      │
│ Cap. 9: Testing Stacks             ──► Plan + k6 Ephemeral Test Stack  │
└────────────────────────────────────────────────────────────────────────┘
```

---

### Capítulo 3: Infrastructure Platforms (Plataformas de Infraestructura)
Morris establece que todo sistema en la nube tiene tres capas:
1. **Infrastructure Platform (IaaS):** Recursos primitivos de cómputo, red y almacenamiento.
2. **Application Runtimes (PaaS / CaaS):** Entornos de ejecución de aplicaciones (como clusters de Kubernetes).
3. **Applications:** El software de negocio.

**En nuestro proyecto:**  
Creamos el módulo `modules/cluster/` que actúa como la **Plataforma**. Este módulo aprovisiona los nodos de cómputo en KinD (1 nodo control-plane y 2 nodos workers para simular máquinas separadas) e instala las primitivas base requeridas (el agente de telemetría `metrics-server`).

---

### Capítulo 4: Core Practice: Define Everything as Code (Definir Todo como Código)
* **Declarativo vs. Imperativo:** Pasamos del *cómo* (el script bash imperativo `deploy.sh`) al *qué* (el estado deseado expresado en archivos `.tf` de Terraform).
* **Idempotencia:** Al ejecutar `terraform apply`, Terraform compara el estado real con el código y solo realiza las acciones mínimas necesarias para converger al estado deseado, sin duplicar recursos ni fallar por ejecuciones consecutivas.
* **Trazabilidad y Visibilidad:** Toda la topología queda versionada en Git, actuando como documentación ejecutable.

---

### Capítulo 5: Building Infrastructure Stacks as Code (Construcción de Stacks)
Morris advierte fuertemente contra el antipatrón del **Monolithic Stack (Stack Monolítico)**, donde toda la red, clúster y aplicaciones se definen en un solo archivo inmenso con un radio de explosión (*Blast Radius*) muy peligroso.

**Solución aplicada (Composición de Stacks):**  
Dividimos la infraestructura en dos stacks desacoplados:
1. **Stack de Plataforma (`modules/cluster/`):** Gestiona el ciclo de vida del clúster KinD y las imágenes Docker.
2. **Stack de Aplicación (`modules/application/`):** Gestiona los microservicios (`frontend`, `backend`, `redis`, `rbac`, `hpa`).
3. **Stack Composition (`main.tf`):** El archivo principal orquesta ambos stacks; el módulo de aplicación recibe de forma limpia los endpoints y certificados emitidos por el módulo de clúster.

---

### Capítulo 6: Building Environments with Stacks (Construcción de Entornos)
* **Antipatrón evitado:** *Copy-Paste Environments*. No duplicamos carpetas de código para cada entorno.
* **Patrón aplicado:** **Reusable Stack (Stack Reutilizable)**. Tenemos **una sola base de código** de infraestructura parametrizada, capaz de instanciarse en cualquier entorno garantizando la **Paridad de Entornos (*Environment Parity*)**.

---

### Capítulo 7: Configuring Stack Instances (Configuración de Instancias)
* **Patrón aplicado:** **Stack Configuration Files**. Los parámetros variables se desacoplan del código y se almacenan en archivos versionados:
  * [`environments/dev.tfvars`](file:///home/chuancao26/Documents/unsa2026_B/cloud/netflix-lab/terraform/environments/dev.tfvars): Entorno liviano para el desarrollo diario (1 nodo worker, 1 réplica de backend, HPA al 70%).
  * [`environments/prod.tfvars`](file:///home/chuancao26/Documents/unsa2026_B/cloud/netflix-lab/terraform/environments/prod.tfvars): Entorno de alta disponibilidad y estrés (2 nodos workers, 3 a 10 réplicas de backend, HPA al 50%).
* **Principio *Keep Parameters Simple*:** Solo parametrizamos lo estrictamente necesario (nodos, réplicas, umbrales de CPU) sin introducir lógica condicional innecesaria.

---

### Capítulo 8 y 9: Testing Infrastructure Stacks (Pruebas del Stack)
Morris define la **Pirámide de Pruebas de IaC** y el ciclo de validación:

1. **Nivel 1: Verificación Sintáctica y Linting Offline:**
   * `terraform fmt -check`: Verifica el estilo y legibilidad del código.
   * `terraform validate`: Valida que los esquemas de tipos, argumentos y dependencias sean válidos antes de tocar el clúster.
2. **Nivel 2: Previsualización Especulativa (*Speculative Run*):**
   * `terraform plan`: Genera un grafo de ejecución para contrastar el código contra el estado real y prever exactamente qué recursos se crearán, modificarán o destruirán.
3. **Nivel 3: Pruebas Dinámicas y el Patrón *Ephemeral Test Stack*:**
   * El proyecto permite desplegar un stack efímero bajo demanda, ejecutar el Job de **k6** para verificar que el sistema responda en SLAs (menos de 1% de errores y latencia p95 < 1.5s), y luego destruir el entorno (`terraform destroy`), garantizando cero costos ociosos y eliminación de deriva de configuración.

---

## 🛠️ 3. Retos Técnicos Reales Encontrados y Solucionados

Durante la migración de los manifiestos de Kubernetes a Terraform surgieron dos problemas avanzados de ingeniería de software en la nube:

### Reto 1: Restricción de Esquema en Kubernetes HPA v2 (`selectPolicy`)
* **Problema:** Al aplicar el HPA con la política de desescalado rápido (`stabilizationWindowSeconds: 60`), la API de Kubernetes v2 rechazó el manifiesto con:
  `Unsupported value: "": supported values: "Disabled", "Max", "Min"`.
* **Causa:** En la especificación oficial de Kubernetes `autoscaling/v2`, cuando se definen políticas (`policy`) dentro del bloque `scale_down`, el atributo `select_policy` es obligatorio para que el controlador sepa si debe elegir el valor mínimo o máximo de reducción de pods.
* **Solución:** Se configuró explícitamente `select_policy = "Max"` en el bloque de comportamiento del HPA en [`modules/application/backend.tf`](file:///home/chuancao26/Documents/unsa2026_B/cloud/netflix-lab/terraform/modules/application/backend.tf#L144-L154).

### Reto 2: Interbloqueo (*Deadlock*) del PVC de Redis con `WaitForFirstConsumer`
* **Problema:** Durante el `terraform apply`, la creación del PersistentVolumeClaim se quedaba bloqueada durante 5 minutos (`Still creating... [4m50s elapsed]`) hasta que fallaba por timeout (`context deadline exceeded`).
* **Causa:** El clúster KinD utiliza la clase de almacenamiento local `rancher.io/local-path` con el modo:
  `volumeBindingMode: WaitForFirstConsumer`.
  Esto significa que Kubernetes **se niega a enlazar el volumen hasta que exista un pod que lo reclame**. Sin embargo, Terraform por defecto espera a que el PVC esté enlazado (`wait_until_bound = true`) **antes** de pasar a crear el pod de Redis. Ambos componentes se esperaban mutuamente, produciendo un interbloqueo (*deadlock*).
* **Solución:** Se configuró `wait_until_bound = false` en [`modules/application/redis.tf`](file:///home/chuancao26/Documents/unsa2026_B/cloud/netflix-lab/terraform/modules/application/redis.tf#L2-L4). Con esto, Terraform crea el PVC de inmediato, avanza a crear el Deployment de Redis, y en el instante en que el pod de Redis es programado, el volumen se enlaza exitosamente.

---

## 🎤 4. Guion Rápido para la Exposición con el Equipo y el Profesor

Si te toca explicar el proyecto ante tus compañeros o el profesor, puedes estructurar tu presentación en 4 partes clave:

1. **Introducción:**
   > *"Originalmente teníamos una aplicación en Kubernetes desplegada con un script bash y manifiestos sueltos. Siguiendo el libro de Kief Morris de Infraestructura como Código, transformamos todo el proyecto en una arquitectura declarativa gestionada con Terraform."*

2. **Modularidad y Stacks (Cap. 5 y 6):**
   > *"Separamos la infraestructura en dos stacks: el Stack de Plataforma en `modules/cluster`, que crea los nodos en KinD e instala metrics-server, y el Stack de Aplicación en `modules/application`, que despliega los microservicios. Aplicamos el patrón Reusable Stack: con el mismo código podemos desplegar `dev` o `prod` mediante archivos `.tfvars`, evitando el antipatrón de copiar y pegar código."*

3. **Prueba de Carga y Resiliencia (Cap. 8 y 9):**
   > *"Para validar el sistema usamos una pirámide de pruebas: validación estática con `terraform validate`, previsualización con `terraform plan`, y pruebas dinámicas con Grafana k6 mediante un Job de Kubernetes. Cuando k6 inyecta 50 usuarios virtuales quemando CPU, demostramos que el HPA reacciona escalando de 3 a 10 réplicas y manteniendo la latencia bajo los SLAs establecidos."*

4. **Demostración en Vivo:**
   > *Mostrar el dashboard en `localhost:8080`, abrir una terminal con `kubectl get pods -o wide`, lanzar el Job de k6 y mostrar cómo los pods se balancean automáticamente entre los workers.*
