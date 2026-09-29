# Laboratorio Kubernetes: frontend, backend, Redis y pruebas de estrés

Cuatro piezas en un clúster local:

| Pieza | Qué es | Réplicas |
|---|---|---|
| `frontend` | nginx con un dashboard que muestra pods, HPA y tráfico en vivo | 2 |
| `backend` | API en Node.js (sin dependencias) que además consulta la API de Kubernetes | 3 (hasta 10 con HPA) |
| `redis` | contador de visitas persistente (PVC) | 1 |
| `k6-stress` | Job de Kubernetes que genera la prueba de carga | bajo demanda |

## Requisitos

Docker, `kubectl` y un clúster local: `kind` (recomendado, permite varios nodos) o `minikube`.

## 1. Crear el clúster

```bash
# kind: 1 control-plane + 2 workers (para ver pods repartidos entre nodos)
kind create cluster --name netflix-lab --config kind-config.yaml

# metrics-server: necesario para que el HPA lea el CPU
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
kubectl patch -n kube-system deployment metrics-server --type=json \
  -p '[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'

# minikube en su lugar:  minikube start --nodes 3 && minikube addons enable metrics-server
```

## 2. Construir y desplegar

```bash
./deploy.sh
kubectl -n netflix-lab port-forward svc/frontend 8080:80
```

Abre http://localhost:8080. En otra terminal deja corriendo:

```bash
kubectl -n netflix-lab get pods -o wide -w
```

## 3. Demos

### A. Cómo Kubernetes gestiona los contenedores
```bash
kubectl -n netflix-lab get deploy,rs,pods,svc,hpa
kubectl -n netflix-lab describe deploy backend       # réplicas, estrategia, probes
kubectl -n netflix-lab get endpoints backend         # IPs de los pods que reciben tráfico
```
En el dashboard, activa "Enviar tráfico constante": las barras muestran cómo el Service reparte peticiones entre los pods del backend.

### B. Tolerancia a fallos
1. Con tráfico activo, borra un pod con la × del dashboard (o `kubectl delete pod <nombre>`). El ReplicaSet crea otro y el tráfico casi no se interrumpe.
2. **Crash:** botón "Tumbar un pod". El proceso termina con error y el kubelet reinicia el contenedor (sube el contador de reinicios).
3. **Liveness:** botón "Pod enfermo". `/healthz` devuelve 500; tras 3 fallos el kubelet lo reinicia.
4. **Readiness:** botón "Pod no listo". El pod sigue vivo pero sale de `kubectl get endpoints backend`, así que no recibe tráfico.
5. **Redis caído:** `kubectl -n netflix-lab scale deploy redis --replicas=0`. El backend sigue respondiendo (modo degradado, el dashboard dice "Redis caído"). Al volver a 1, el contador continúa donde estaba gracias al volumen persistente.
6. **Nodo caído:** `kubectl drain <worker> --ignore-daemonsets --delete-emptydir-data`. Los pods se mueven a otro nodo y el PodDisruptionBudget garantiza al menos 2 réplicas del backend. Al final: `kubectl uncordon <worker>`.

### C. Escalabilidad
```bash
kubectl -n netflix-lab scale deploy backend --replicas=6    # manual
kubectl -n netflix-lab get hpa -w                           # automática
```

### D. Prueba de estrés
Ligera, desde el dashboard: mueve el control "Usuarios de estrés".

Seria, con k6 dentro del clúster (2.5 minutos, hasta 50 usuarios virtuales):
```bash
kubectl apply -f loadtest/k6-job.yaml
kubectl -n netflix-lab logs -f job/k6-stress
```
Mientras corre, mira `kubectl -n netflix-lab get hpa -w` y el dashboard: el CPU sube por encima del 50%, el HPA aumenta las réplicas (hasta 10) y la latencia se estabiliza. Al terminar, tras ~1 minuto, vuelve a 3 réplicas. k6 imprime al final si pasaron los umbrales (menos de 1% de errores, p95 < 1.5 s).

Para repetirla: `kubectl -n netflix-lab delete job k6-stress` y aplica de nuevo.

### E. Actualización sin caídas (rolling update)
Con tráfico activo:
```bash
kubectl -n netflix-lab rollout restart deploy/backend
kubectl -n netflix-lab rollout status deploy/backend
kubectl -n netflix-lab rollout undo deploy/backend    # volver atrás
```
`maxUnavailable: 0` + readiness probe hacen que los pods nuevos entren antes de que salgan los viejos.

## Limpieza
```bash
kind delete cluster --name netflix-lab
```

## Notas
- El backend tiene permisos (RBAC) para listar y borrar pods de su namespace, solo para el laboratorio.
- Si el HPA muestra `<unknown>` en CPU, espera 1-2 minutos o revisa `kubectl -n kube-system get pods` (metrics-server).
- Si cambias el código, reconstruye con `./deploy.sh` y ejecuta `kubectl -n netflix-lab rollout restart deploy/backend deploy/frontend`.
