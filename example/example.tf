provider "aws" {
  region = "eu-central-1"
}

provider "awscc" {
  region = "eu-central-1"
}

data "aws_caller_identity" "current" {}

module "example" {
  source = "../"

  account_id = data.aws_caller_identity.current.account_id
  region     = "eu-central-1"
  slack_settings = {
    slack_channel_id   = "00000000000" //Replace with your own channel ID
    slack_workspace_id = "00000000000" //Replace with your own workspace ID
  }
}

resource "aws_cloudwatch_log_subscription_filter" "example" {
  name            = "logs-alerts"
  log_group_name  = "/aws/lambda/my-application"
  filter_pattern  = "ERROR"
  destination_arn = module.example.lambda_arn
}
