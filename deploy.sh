#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
CLUSTER="${CLUSTER:-netflix-lab}"

docker build -t netflix-lab/backend:1.0 backend
docker build -t netflix-lab/frontend:1.0 frontend

if command -v kind >/dev/null && kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
  kind load docker-image netflix-lab/backend:1.0 netflix-lab/frontend:1.0 --name "$CLUSTER"
elif command -v minikube >/dev/null; then
  minikube image load netflix-lab/backend:1.0
  minikube image load netflix-lab/frontend:1.0
fi

kubectl apply -f k8s/
for d in redis backend frontend; do
  kubectl -n netflix-lab rollout status deploy/$d --timeout=120s
done
echo
echo "Listo. Abre el dashboard con:"
echo "  kubectl -n netflix-lab port-forward svc/frontend 8080:80"
echo "y visita http://localhost:8080"
