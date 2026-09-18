# Deliberately insecure module, used only to prove the OPA guardrail fires.
# `make test-bad` plans this and expects conftest to FAIL. If it ever passes,
# the guardrail has regressed.

terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region                      = "eu-central-1"
  skip_credentials_validation = true
  skip_requesting_account_id  = true
  skip_metadata_api_check     = true
  access_key                  = "mock"
  secret_key                  = "mock"
}

# VIOLATION 1: wildcard action + wildcard resource.
resource "aws_iam_role" "bad" {
  name = "over-permissioned"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "bad" {
  name = "too-broad"
  role = aws_iam_role.bad.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "WildcardS3"
        Effect   = "Allow"
        Action   = "s3:*"
        Resource = "*"
      },
      {
        Sid      = "FullAdmin"
        Effect   = "Allow"
        Action   = "*"
        Resource = "*"
      },
    ]
  })
}

# VIOLATION 2: trust policy anyone can assume.
resource "aws_iam_role" "open_trust" {
  name = "world-assumable"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = "*"
    }]
  })
}
