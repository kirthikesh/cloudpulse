terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # Partial config: bucket is passed at init time
  #   terraform init -backend-config="bucket=cloudpulse-tfstate-<ACCOUNT_ID>"
  backend "s3" {
    key          = "cloudpulse/aws/terraform.tfstate"
    region       = "eu-west-1"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = var.project
      ManagedBy = "terraform"
      Repo      = "github.com/kirthikesh/cloudpulse"
    }
  }
}
