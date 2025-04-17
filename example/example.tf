data "aws_caller_identity" "current" {}

module "example" {
  source = "../"

  account_id = data.aws_caller_identity.current.account_id
  slack_settings = {
    slack_channel_id   = "00000000000" //Replace with your own channel ID
    slack_workspace_id = "00000000000" //Replace with your own workspace ID
  }
}
