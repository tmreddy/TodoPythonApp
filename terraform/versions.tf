terraform {
  # 1.5.7 is what this repo was validated against. Newer is fine.
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    # Used to read the EKS OIDC issuer's certificate thumbprint for IRSA.
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }

  # State lives on your workstation by default, which is fine for one person
  # learning. The moment a second person -- or GitHub Actions -- runs apply, you
  # need remote state with locking, or two applies can clobber each other and
  # corrupt the record of what exists.
  #
  # State contains the database password in plain text. An S3 backend must be
  # private and encrypted. See terraform/README.md for the bootstrap steps.
  #
  # backend "s3" {
  #   bucket  = "todo-tfstate-<your-account-id>"
  #   key     = "todo/terraform.tfstate"
  #   region  = "us-east-1"
  #   encrypt = true
  #
  #   # State locking. On Terraform 1.10+ use S3-native locking:
  #   #   use_lockfile = true
  #   # On older versions (including the 1.5.7 this was validated on) you need a
  #   # DynamoDB table with a "LockID" string partition key:
  #   #   dynamodb_table = "todo-tfstate-lock"
  # }
}
