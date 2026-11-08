#!/usr/bin/env bash
set -euo pipefail

environment="${1:-dev}"
case "$environment" in dev|prod) ;; *) echo "Entorno inválido: $environment" >&2; exit 2 ;; esac

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
region="${AWS_REGION:-us-east-1}"
for tool in aws docker sha256sum; do
  command -v "$tool" >/dev/null || { echo "Falta $tool" >&2; exit 1; }
done
if ! docker info >/dev/null 2>&1; then
  echo "Docker no responde desde WSL. Inicia Docker Desktop y activa Settings > Resources > WSL Integration para esta distribución." >&2
  exit 1
fi

account="$(aws sts get-caller-identity --query Account --output text)"
registry="${account}.dkr.ecr.${region}.amazonaws.com"
cd "$repo_root"
tag="src-$(sha256sum \
  backend/Dockerfile backend/server.js \
  frontend/Dockerfile frontend/index.html \
  frontend/nginx.conf | sha256sum | cut -c1-12)"

aws ecr get-login-password --region "$region" | docker login --username AWS --password-stdin "$registry" >&2

for service in backend frontend; do
  repository="netflix-lab-${environment}/${service}"
  if aws ecr describe-images --region "$region" --repository-name "$repository" \
      --image-ids "imageTag=$tag" >/dev/null 2>&1; then
    echo "Imagen ya publicada: $repository:$tag" >&2
    continue
  fi
  image="${registry}/${repository}:${tag}"
  docker build --platform linux/amd64 -t "$image" "$repo_root/$service" >&2
  docker push "$image" >&2
done

# Única salida estándar: el tag de imagen para TF_VAR_image_tag.
printf '%s\n' "$tag"
