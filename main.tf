locals {
  default_environment_variables = {
    SNS_ARN        = aws_sns_topic.alerts_sns_topic.arn
    DYNAMODB_TABLE = aws_dynamodb_table.logs_errors_table.name
    MAX            = 600
  }

  lambda_environment_variables = merge(local.default_environment_variables, var.lambda_environment_variables)
  lambda_code_path             = var.lambda_code_path == "logs_alerts.py" ? "${path.module}/lambda/logs_alerts.py" : var.lambda_code_path
}

# DynamoDB table (with DynamoDB Stream)
resource "aws_dynamodb_table" "logs_errors_table" {
  name             = "alerts-table"
  hash_key         = "error_message_hash"
  billing_mode     = "PAY_PER_REQUEST"
  stream_enabled   = true
  stream_view_type = "OLD_IMAGE"

  attribute {
    name = "error_message_hash"
    type = "S"
  }

  ttl {
    attribute_name = "ttl"
    enabled        = true
  }
}

# SNS Topic
resource "aws_sns_topic" "alerts_sns_topic" {
  name = "${var.name}-sns-topic"
}

# AWS Chatbot Slack Configuration IAM Role and Policies
data "aws_iam_policy_document" "assume_role_chatbot" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["chatbot.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "chatbot_slack_role" {
  name_prefix        = "${var.name}-chatbot-slack-role-"
  assume_role_policy = data.aws_iam_policy_document.assume_role_chatbot.json
}

data "aws_iam_policy_document" "chatbot_slack_policy" {
  statement {
    actions = [
      "cloudwatch:Describe*",
      "cloudwatch:Get*",
      "cloudwatch:List*",
    ]
    resources = ["arn:aws:cloudwatch:${var.region}:${var.account_id}:*"]
  }
}

resource "aws_iam_role_policy" "chatbot_slack_role_policy" {
  name   = "${var.name}_chatbot_slack_role_policy"
  role   = aws_iam_role.chatbot_slack_role.id
  policy = data.aws_iam_policy_document.chatbot_slack_policy.json
}

# AWS Chatbot Slack Configuration
resource "awscc_chatbot_slack_channel_configuration" "slack_alerts" {
  configuration_name = "${var.name}-chatbot-slack-alerts"
  iam_role_arn       = aws_iam_role.chatbot_slack_role.arn
  slack_channel_id   = var.slack_settings.slack_channel_id
  slack_workspace_id = var.slack_settings.slack_workspace_id
  sns_topic_arns     = [aws_sns_topic.alerts_sns_topic.arn]
}

# Lambda function Roles & Policies
data "aws_iam_policy_document" "assume_role_lambda" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda_role" {
  name_prefix         = "${var.name}-role-"
  assume_role_policy  = data.aws_iam_policy_document.assume_role_lambda.json
  managed_policy_arns = var.vpc_subnet_ids != null && var.vpc_security_group_ids != null ? ["arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"] : null
}

data "aws_iam_policy_document" "lambda_policy" {
  statement {
    actions = [
      "dynamodb:PutItem",
      "dynamodb:UpdateItem",
      "dynamodb:DeleteItem",
      "dynamodb:GetItem",
      "dynamodb:Scan",
      "dynamodb:Query",
    ]
    resources = [aws_dynamodb_table.logs_errors_table.arn]
  }

  statement {
    actions = [
      "dynamodb:GetRecords",
      "dynamodb:GetShardIterator",
      "dynamodb:DescribeStream",
      "dynamodb:ListStreams"
    ]
    resources = ["${aws_dynamodb_table.logs_errors_table.arn}/stream/*"]
  }

  statement {
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.alerts_sns_topic.arn]
  }
}

resource "aws_iam_role_policy" "lambda_policy" {
  name_prefix = var.name
  role        = aws_iam_role.lambda_role.id
  policy      = data.aws_iam_policy_document.lambda_policy.json
}

# Lambda function
data "archive_file" "lambda_zip" {
  type        = "zip"
  source_file = local.lambda_code_path
  output_path = "${path.module}/lambda/build.zip"
}

resource "aws_lambda_function" "lambda" {
  function_name    = var.name
  description      = "Trigger alerts based on Cloudwatch Logs Subscription Filter trigger"
  role             = aws_iam_role.lambda_role.arn
  filename         = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256
  timeout          = 10

  runtime = var.lambda_runtime
  handler = var.lambda_handler

  dynamic "environment" {
    for_each = length(keys(local.lambda_environment_variables)) == 0 ? [] : [true]
    content {
      variables = local.lambda_environment_variables
    }
  }

  dynamic "vpc_config" {
    for_each = var.vpc_subnet_ids != null && var.vpc_security_group_ids != null ? [true] : []
    content {
      security_group_ids = var.vpc_security_group_ids
      subnet_ids         = var.vpc_subnet_ids
    }
  }

  depends_on = [
    aws_dynamodb_table.logs_errors_table,
    aws_sns_topic.alerts_sns_topic,
    aws_iam_role.lambda_role
  ]
}

resource "aws_lambda_permission" "allow_cloudwatch_logs" {
  action         = "lambda:InvokeFunction"
  function_name  = aws_lambda_function.lambda.function_name
  principal      = "logs.amazonaws.com"
  source_account = var.account_id
  source_arn     = "arn:aws:logs:${var.region}:${var.account_id}:log-group:*"
}

resource "aws_lambda_event_source_mapping" "trigger" {
  event_source_arn  = aws_dynamodb_table.logs_errors_table.stream_arn
  function_name     = aws_lambda_function.lambda.function_name
  starting_position = "LATEST"

  filter_criteria {
    filter {
      pattern = "{\"userIdentity\":{\"type\":[\"Service\"],\"principalId\":[\"dynamodb.amazonaws.com\"]}}"
    }
  }
}
