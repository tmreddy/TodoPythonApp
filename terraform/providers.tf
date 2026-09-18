provider "aws" {
  region = var.region

  # Tag every taggable resource automatically. This is how you answer "what is
  # this and why am I paying for it?" three weeks from now, and how you find
  # every piece of the stack at teardown time.
  default_tags {
    tags = {
      Project     = var.project
      Environment = var.environment
      ManagedBy   = "terraform"
      Repository  = "tmreddy/TodoPythonApp"
    }
  }
}

provider "random" {}

data "aws_caller_identity" "current" {}

# Only use AZs that actually support the subnets and RDS class we ask for.
# Hardcoding us-east-1a/1b bites you when an AZ is constrained for your account.
data "aws_availability_zones" "available" {
  state = "available"

  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}
