terraform {
  required_version = ">= 1.10.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.80, < 7.0"
    }
  }
}

variable "region" {
  type    = string
  default = "us-east-1"
}

variable "state_bucket_name" {
  description = "Nombre globalmente único para el bucket de estado"
  type        = string
}

provider "aws" {
  region = var.region
  default_tags {
    tags = {
      Project   = "netflix-lab"
      ManagedBy = "terraform"
      Stack     = "bootstrap"
    }
  }
}

# Este stack usa estado local: el bucket no puede almacenarse en sí mismo.
resource "aws_s3_bucket" "state" {
  bucket = var.state_bucket_name
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket                  = aws_s3_bucket.state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

output "state_bucket_name" {
  value = aws_s3_bucket.state.id
}
