variable "name" {
  description = "Name for the ressources"
  type        = string
  default     = "logs-alerts"
}

variable "account_id" {
  description = "AWS account ID"
  type        = string
}

variable "region" {
  description = "AWS region (where to deploy everything)"
  type        = string
  default     = "eu-central-1"
}

variable "slack_settings" {
  description = "Slack channel ID and workplace ID"
  type = object({
    slack_channel_id : string
    slack_workspace_id : string
  })
}

variable "lambda_code_path" {
  description = "Path of the Lambda function code"
  type        = string
  default     = "logs_alerts.py"
}

variable "lambda_runtime" {
  description = "Runtime for the Lambda"
  type        = string
  default     = "python3.8"
}

variable "lambda_handler" {
  description = "Handler for the Lambda"
  type        = string
  default     = "logs_alerts.lambda_handler"
}

variable "lambda_environment_variables" {
  description = "A map that defines environment variables for the Lambda Function."
  type        = map(string)
  default     = {}
}

variable "vpc_subnet_ids" {
  description = "List of subnet IDs when the function should run in a VPC"
  type        = list(string)
  default     = null
}

variable "vpc_security_group_ids" {
  description = "List of security group IDs when the function should run in a VPC"
  type        = list(string)
  default     = null
}
