# Terraform config
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 3.54"
    }

    snowflake = {
      source  = "chanzuckerberg/snowflake"
      version = "~> 0.25.24"
    }
  }

  required_version = ">= 0.14.9"
  experiments      = [module_variable_optional_attrs]
}

locals {
  notification_inputs = {
    for prefix, table in var.prefix_tables : prefix => {
      id            = "Saving ${table} table inputs from ${prefix}"
      topic_arn     = module.snowpipe[prefix].topic_arn
      filter_prefix = prefix
    }
  }
}


data "aws_s3_bucket" "this" {
  bucket = var.bucket_name
}


data "aws_iam_policy_document" "snowflake_integration" {
  statement {
    actions = [
      "s3:GetObject",
      "s3:GetObjectVersion"
    ]

    resources = [
      "${data.aws_s3_bucket.this.arn}/*"
    ]
  }

  statement {
    actions = [
      "s3:ListBucket",
    ]

    resources = [
      data.aws_s3_bucket.this.arn
    ]
  }
}

resource "aws_iam_policy" "snowflake_integration" {
  policy      = data.aws_iam_policy_document.snowflake_integration.json
  path        = "/data/data-feeds/"
  description = "Data snowflake integration policy"
}

data "aws_iam_policy_document" "snowflake_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "AWS"
      identifiers = [var.storage_aws_iam_user_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "sts:ExternalId"

      values = [
        aws_ssm_parameter.storage_aws_external_id.value
      ]
    }
  }
}

resource "aws_iam_role" "snowflake_integration" {
  name               = var.snowflake_role_name
  path               = var.snowflake_role_path
  assume_role_policy = data.aws_iam_policy_document.snowflake_assume_role.json
}

resource "aws_iam_role_policy" "snowflake_integration" {
  name   = var.snowflake_role_name
  role   = aws_iam_role.snowflake_integration.id
  policy = data.aws_iam_policy_document.snowflake_integration.json
}


module "snowpipe" {
  for_each                       = var.prefix_tables
  source                         = "./inner"
  region                         = data.aws_s3_bucket.this.region
  bucket_arn                     = data.aws_s3_bucket.this.arn
  bucket_id                      = data.aws_s3_bucket.this.id
  prefix                         = each.key
  database                       = var.database
  schema                         = var.schema
  table_name                     = each.value
  file_format                    = var.file_format
  storage_aws_iam_user_arn       = var.storage_aws_iam_user_arn
}

resource "aws_s3_bucket_notification" "this" {
  depends_on = [module.snowpipe]

  bucket = var.bucket_id

  dynamic "topic" {
    for_each = local.notification_inputs
    content {
      id            = topic.value["id"]
      topic_arn     = topic.value["topic_arn"]
      events        = ["s3:ObjectCreated:*"]
      filter_prefix = topic.value["filter_prefix"]
    }
  }
}
