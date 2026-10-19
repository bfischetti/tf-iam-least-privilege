terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

# ---------------------------------------------------------------------------
# Document-processor service
#
# A Lambda function that reads an uploaded document from the ingest bucket,
# processes it, and writes the result to the output bucket. The point of this
# module is the IAM role: it is scoped to exactly the actions and resources
# this one function needs, and nothing else. No wildcards in actions, no "*"
# resources on data operations.
# ---------------------------------------------------------------------------

variable "service_name" {
  description = "Name of the service, used to prefix every resource."
  type        = string
  default     = "document-processor"
}

variable "log_retention_days" {
  description = "How long to keep the function's CloudWatch logs."
  type        = number
  default     = 14
}

variable "aws_region" {
  description = "Region the service is deployed to. Passed in rather than discovered so the plan and the CI policy check need no live account."
  type        = string
}

variable "account_id" {
  description = "AWS account ID, used to build exact log-group ARNs. Passed in for the same reason as region."
  type        = string
}

locals {
  # Built explicitly so the IAM policy can reference exact ARNs instead of "*".
  log_group_arn = "arn:aws:logs:${var.aws_region}:${var.account_id}:log-group:/aws/lambda/${var.service_name}:*"
}

# --- Storage --------------------------------------------------------------

resource "aws_s3_bucket" "ingest" {
  bucket_prefix = "${var.service_name}-ingest-"
  force_destroy = true
}

resource "aws_s3_bucket" "output" {
  bucket_prefix = "${var.service_name}-output-"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "ingest" {
  bucket                  = aws_s3_bucket.ingest.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_public_access_block" "output" {
  bucket                  = aws_s3_bucket.output.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# --- Logging --------------------------------------------------------------

resource "aws_cloudwatch_log_group" "fn" {
  name              = "/aws/lambda/${var.service_name}"
  retention_in_days = var.log_retention_days
}

# --- Execution role -------------------------------------------------------

# The role the Lambda assumes at runtime. Trust policy is scoped to the Lambda
# service principal only.
resource "aws_iam_role" "fn" {
  name               = "${var.service_name}-exec"
  assume_role_policy = data.aws_iam_policy_document.assume.json
}

data "aws_iam_policy_document" "assume" {
  statement {
    sid     = "LambdaAssume"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

# The permission policy. This is the artifact under review.
#
# Least-privilege choices:
#   - Read is granted ONLY on the ingest bucket's objects (GetObject), not the
#     bucket itself, not the output bucket.
#   - Write is granted ONLY on the output bucket's objects (PutObject), never
#     on ingest. The function cannot overwrite the input it was given.
#   - ListBucket is scoped to the two bucket ARNs, not "*".
#   - Logging is scoped to this function's own log group ARN, not all logs.
#   - No s3:*, no logs:*, no "Resource": "*" on any data action.
data "aws_iam_policy_document" "fn" {
  statement {
    sid       = "ReadIngestObjects"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.ingest.arn}/*"]
  }

  statement {
    sid       = "WriteOutputObjects"
    effect    = "Allow"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.output.arn}/*"]
  }

  statement {
    sid    = "ListOwnBuckets"
    effect = "Allow"
    actions = [
      "s3:ListBucket",
    ]
    resources = [
      aws_s3_bucket.ingest.arn,
      aws_s3_bucket.output.arn,
    ]
  }

  statement {
    sid    = "WriteOwnLogs"
    effect = "Allow"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = [local.log_group_arn]
  }
}

resource "aws_iam_role_policy" "fn" {
  name   = "${var.service_name}-permissions"
  role   = aws_iam_role.fn.id
  policy = data.aws_iam_policy_document.fn.json
}

# --- Function -------------------------------------------------------------

# Inline placeholder package so the module plans without a build step.
data "archive_file" "fn" {
  type        = "zip"
  output_path = "${path.module}/build/function.zip"
  source {
    content  = "exports.handler = async () => ({ ok: true });"
    filename = "index.js"
  }
}

resource "aws_lambda_function" "fn" {
  function_name    = var.service_name
  role             = aws_iam_role.fn.arn
  runtime          = "nodejs20.x"
  handler          = "index.handler"
  filename         = data.archive_file.fn.output_path
  source_code_hash = data.archive_file.fn.output_base64sha256
  timeout          = 30

  environment {
    variables = {
      INGEST_BUCKET = aws_s3_bucket.ingest.id
      OUTPUT_BUCKET = aws_s3_bucket.output.id
    }
  }

  depends_on = [aws_cloudwatch_log_group.fn]
}

# --- Outputs --------------------------------------------------------------

output "function_name" {
  value = aws_lambda_function.fn.function_name
}

output "role_arn" {
  value = aws_iam_role.fn.arn
}

output "ingest_bucket" {
  value = aws_s3_bucket.ingest.id
}

output "output_bucket" {
  value = aws_s3_bucket.output.id
}
