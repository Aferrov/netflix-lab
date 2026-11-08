#!/usr/bin/env bash
set -euo pipefail

bucket="${1:?Uso: bash terraform/aws/bootstrap/bootstrap.sh NOMBRE_DEL_BUCKET}"
region="${AWS_REGION:-us-east-1}"

case "$region" in
  us-east-1|us-west-2) ;;
  *) echo "Región no permitida en Learner Lab: $region" >&2; exit 2 ;;
esac

command -v aws >/dev/null || { echo "Falta aws" >&2; exit 1; }

account="$(aws sts get-caller-identity --query Account --output text)"
if actual_region="$(aws s3api head-bucket --bucket "$bucket" --region "$region" \
    --expected-bucket-owner "$account" --query BucketRegion --output text 2>/dev/null)"; then
  [[ "$actual_region" == "$region" ]] || {
    echo "El bucket existe en $actual_region; se esperaba $region" >&2; exit 1;
  }
  echo "Bucket existente en esta cuenta: $bucket"
else
  create_args=(--bucket "$bucket" --region "$region")
  if [[ "$region" != us-east-1 ]]; then
    create_args+=(--create-bucket-configuration "LocationConstraint=$region")
  fi
  aws s3api create-bucket "${create_args[@]}" >/dev/null
  echo "Bucket creado: $bucket"
fi

aws s3api put-bucket-versioning --bucket "$bucket" --region "$region" \
  --expected-bucket-owner "$account" --versioning-configuration Status=Enabled
aws s3api put-bucket-encryption --bucket "$bucket" --region "$region" \
  --expected-bucket-owner "$account" \
  --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
aws s3api put-public-access-block --bucket "$bucket" --region "$region" \
  --expected-bucket-owner "$account" \
  --public-access-block-configuration \
  'BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true'
aws s3api put-bucket-ownership-controls --bucket "$bucket" --region "$region" \
  --expected-bucket-owner "$account" \
  --ownership-controls '{"Rules":[{"ObjectOwnership":"BucketOwnerEnforced"}]}'

status="$(aws s3api get-bucket-versioning --bucket "$bucket" --region "$region" \
  --expected-bucket-owner "$account" --query Status --output text)"
[[ "$status" == Enabled ]] || { echo "El versionado no quedó activo" >&2; exit 1; }
echo "Estado S3 listo: $bucket ($region, versionado, cifrado y acceso público bloqueado)"
