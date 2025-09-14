terraform {
  required_version = ">= 1.7"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.60" }
  }
}

########################################
# Provider & Identity
########################################
provider "aws" {
  region = var.region
}

data "aws_caller_identity" "current" {}

locals {
  state_bucket = "${var.project}-tfstate"
  lock_table   = "${var.project}-tf-lock"
  tags_common  = { Project = var.project }
}

########################################
# S3: Terraform remote state bucket
# - versioned
# - encrypted
# - public access blocked
# - deny non-TLS
# - protected from destroy
########################################
resource "aws_s3_bucket" "tfstate" {
  bucket = local.state_bucket
  tags   = merge(local.tags_common, { Purpose = "tfstate" })

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket                  = aws_s3_bucket.tfstate.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Deny any request that isn't using TLS
data "aws_iam_policy_document" "tfstate_policy" {
  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["s3:*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    resources = [
      aws_s3_bucket.tfstate.arn,
      "${aws_s3_bucket.tfstate.arn}/*"
    ]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  policy = data.aws_iam_policy_document.tfstate_policy.json
}

########################################
# DynamoDB: State lock table
# - PAY_PER_REQUEST
# - PITR enabled
# - SSE enabled
# - protected from destroy
########################################
resource "aws_dynamodb_table" "lock" {
  name         = local.lock_table
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }

  point_in_time_recovery {
    enabled = true
  }

  server_side_encryption {
    enabled = true
  }

  tags = merge(local.tags_common, { Purpose = "tf-lock" })

  lifecycle {
    prevent_destroy = true
  }
}

########################################
# GitHub OIDC provider (for keyless CI)
########################################
resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  # Current GitHub Actions root CA thumbprint
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

########################################
# CI Role (GitHub Actions) – OIDC assume
########################################
data "aws_iam_policy_document" "gha_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # Limit to your repo's main branch
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_owner}/${var.github_repo}:ref:refs/heads/main"]
    }
  }
}

resource "aws_iam_role" "gha_terraform" {
  name               = "${var.project}-gha-terraform"
  assume_role_policy = data.aws_iam_policy_document.gha_assume.json
  max_session_duration = 7200  # 2h sessions (handy for long plans/applies)
  tags               = merge(local.tags_common, { Role = "ci" })
}

resource "aws_iam_role_policy_attachment" "gha_admin" {
  role       = aws_iam_role.gha_terraform.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

########################################
# Human Role (local Terraform assumes this)
########################################
data "aws_iam_policy_document" "human_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:user/${var.admin_user_name}"]
    }
  }
}

resource "aws_iam_role" "human_terraform" {
  name                 = "${var.project}-human-terraform"
  assume_role_policy   = data.aws_iam_policy_document.human_assume.json
  max_session_duration = 7200
  tags                 = merge(local.tags_common, { Role = "human" })
}

resource "aws_iam_role_policy_attachment" "human_admin" {
  role       = aws_iam_role.human_terraform.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

########################################
# Outputs
########################################
output "state_bucket" {
  value = aws_s3_bucket.tfstate.bucket
}

output "lock_table" {
  value = aws_dynamodb_table.lock.name
}

output "gha_role_arn" {
  value = aws_iam_role.gha_terraform.arn
}

output "human_role_arn" {
  value = aws_iam_role.human_terraform.arn
}
