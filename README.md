# CloudWatch Logs Enhanced Alerts & Notifications

Terraform module that turns CloudWatch Logs into **deduplicated, rate-limited Slack alerts**.
Instead of one notification per matching log line, the module applies an exponential
back-off per unique error so a noisy failure does not flood your channel: you get an
immediate alert, then a single summary once the error stops or the back-off window closes.

## 📝 Medium Article
For more information about this module, check out this article: [https://medium.com/@louis-fiori/cloudwatch-logs-enhanced-alerts-a50ea08d0845](https://medium.com/@louis-fiori/cloudwatch-logs-enhanced-alerts-a50ea08d0845)

## 🏗️ How it works

1. A CloudWatch Logs **Subscription Filter** forwards matching log events to the Lambda.
2. The Lambda hashes `message + log_group` and looks it up in a **DynamoDB** table:
   - **New error** → notification sent immediately.
   - **Same error, back-off window elapsed** → re-alert (with the count accumulated since
     the last notification) and the window is widened.
   - **Same error, within the window** → counted silently (no notification).
3. Each tracking item has a **TTL**. When it expires, a **DynamoDB Stream** re-invokes the
   Lambda; if errors were counted during the window, a summary notification is published.
4. Notifications go to an **SNS topic** wired to **AWS Chatbot**, which posts to Slack.

> ⚠️ DynamoDB TTL deletions can be delayed by AWS (up to ~48h), so summary notifications
> are best-effort rather than precisely timed.

## 🚀 Usage

```hcl
module "logs_alerts" {
  source = "github.com/louis-fiori/terraform-aws-cloudwatch-logs-enhanced-alarms-notifications"

  account_id = "123456789012"
  region     = "eu-central-1"
  slack_settings = {
    slack_channel_id   = "C0XXXXXXX"
    slack_workspace_id = "T0XXXXXXX"
  }
}

resource "aws_cloudwatch_log_subscription_filter" "app" {
  name            = "logs-alerts"
  log_group_name  = "/aws/lambda/my-application"
  filter_pattern  = "ERROR"
  destination_arn = module.logs_alerts.lambda_arn
}
```

See [`example/example.tf`](example/example.tf) for a complete, runnable example.

## 🔗 Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.9.5 |
| <a name="requirement_aws"></a> [aws](#requirement\_aws) | >= 4.0.0 |
| <a name="requirement_awscc"></a> [awscc](#requirement\_awscc) | >= 0.2 |

## ➡️ Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_account_id"></a> [account\_id](#input\_account\_id) | AWS account ID | `string` | n/a | yes |
| <a name="input_slack_settings"></a> [slack\_settings](#input\_slack\_settings) | Slack channel ID and workspace ID | <pre>object({<br>    slack_channel_id : string<br>    slack_workspace_id : string<br>  })</pre> | n/a | yes |
| <a name="input_name"></a> [name](#input\_name) | Name for the resources | `string` | `"logs-alerts"` | no |
| <a name="input_region"></a> [region](#input\_region) | AWS region (where to deploy everything) | `string` | `"eu-central-1"` | no |
| <a name="input_lambda_code_path"></a> [lambda\_code\_path](#input\_lambda\_code\_path) | Path of the Lambda function code | `string` | `"logs_alerts.py"` | no |
| <a name="input_lambda_environment_variables"></a> [lambda\_environment\_variables](#input\_lambda\_environment\_variables) | A map that defines environment variables for the Lambda Function. | `map(string)` | `{}` | no |
| <a name="input_lambda_handler"></a> [lambda\_handler](#input\_lambda\_handler) | Handler for the Lambda | `string` | `"logs_alerts.lambda_handler"` | no |
| <a name="input_lambda_runtime"></a> [lambda\_runtime](#input\_lambda\_runtime) | Runtime for the Lambda | `string` | `"python3.12"` | no |
| <a name="input_lambda_timeout"></a> [lambda\_timeout](#input\_lambda\_timeout) | Timeout (in seconds) for the Lambda function | `number` | `10` | no |
| <a name="input_vpc_security_group_ids"></a> [vpc\_security\_group\_ids](#input\_vpc\_security\_group\_ids) | List of security group IDs when the function should run in a VPC | `list(string)` | `null` | no |
| <a name="input_vpc_subnet_ids"></a> [vpc\_subnet\_ids](#input\_vpc\_subnet\_ids) | List of subnet IDs when the function should run in a VPC | `list(string)` | `null` | no |

## ⬅️ Outputs

| Name | Description |
|------|-------------|
| <a name="output_lambda_arn"></a> [lambda\_arn](#output\_lambda\_arn) | ARN of the Lambda function (use it with CloudWatch Logs Subscription Filter) |
| <a name="output_sns_topic_arn"></a> [sns\_topic\_arn](#output\_sns\_topic\_arn) | ARN of the SNS topic (if you need to setup other notifications than Slack) |
