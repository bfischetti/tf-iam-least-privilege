terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.0"
    }
  }
}

# Region is fixed and credentials are not required for `validate` or for a
# `plan` that only needs to render the config. For a real apply you would
# supply credentials via the usual AWS provider chain (env vars, SSO, profile).
provider "aws" {
  region = "eu-central-1"

  # These let `terraform plan` run with no account and no network calls, so the
  # CI policy check can inspect the planned IAM without deploying anything.
  skip_credentials_validation = true
  skip_requesting_account_id  = true
  skip_metadata_api_check     = true
  access_key                  = "mock"
  secret_key                  = "mock"
}

module "document_processor" {
  source       = "./modules/document-processor"
  service_name = "document-processor"
  aws_region   = "eu-central-1"
  account_id   = "111122223333" # placeholder for plan/validate; real value comes from the account on apply
}

output "role_arn" {
  value = module.document_processor.role_arn
}

output "ingest_bucket" {
  value = module.document_processor.ingest_bucket
}

output "output_bucket" {
  value = module.document_processor.output_bucket
}
