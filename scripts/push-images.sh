#!/usr/bin/env bash
set -euo pipefail

environment="${1:-dev}"
case "$environment" in dev|prod) ;; *) echo "Entorno inválido: $environment" >&2; exit 2 ;; esac

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
region="${AWS_REGION:-us-east-1}"
for tool in aws sha256sum; do
  command -v "$tool" >/dev/null || { echo "Falta $tool" >&2; exit 1; }
done
if command -v docker >/dev/null && docker info >/dev/null 2>&1; then
  docker_cli=docker
elif command -v docker.exe >/dev/null && docker.exe info >/dev/null 2>&1; then
  docker_cli=docker.exe
  echo "Usando Docker Desktop de Windows mientras WSL Integration no esté disponible." >&2
else
  echo "Docker no responde. Inicia Docker Desktop o activa Settings > Resources > WSL Integration." >&2
  exit 1
fi

account="$(aws sts get-caller-identity --query Account --output text)"
registry="${account}.dkr.ecr.${region}.amazonaws.com"
cd "$repo_root"
tag="src-$(sha256sum \
  backend/Dockerfile backend/server.js \
  frontend/Dockerfile frontend/index.html \
  frontend/nginx.conf | sha256sum | cut -c1-12)"

aws ecr get-login-password --region "$region" | "$docker_cli" login --username AWS --password-stdin "$registry" >&2

for service in backend frontend; do
  if [[ "$service" == backend ]]; then
    image_url="${ECR_BACKEND_URL:-${registry}/netflix-lab-${environment}/backend}"
  else
    image_url="${ECR_FRONTEND_URL:-${registry}/netflix-lab-${environment}/frontend}"
  fi
  [[ "$image_url" == "$registry/"* ]] || { echo "Repositorio fuera de la cuenta/región actual: $image_url" >&2; exit 1; }
  repository="${image_url#"$registry/"}"
  if aws ecr describe-images --region "$region" --repository-name "$repository" \
      --image-ids "imageTag=$tag" >/dev/null 2>&1; then
    echo "Imagen ya publicada: $repository:$tag" >&2
    continue
  fi
  image="${image_url}:${tag}"
  "$docker_cli" build --platform linux/amd64 -t "$image" "$repo_root/$service" >&2
  "$docker_cli" push "$image" >&2
done

# Única salida estándar: el tag de imagen para TF_VAR_image_tag.
printf '%s\n' "$tag"
