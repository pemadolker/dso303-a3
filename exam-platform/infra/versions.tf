terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.80"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.7"
    }
  }

  # Bucket/key/region are passed with -backend-config (see scripts/bootstrap-state.sh)
  backend "s3" {
    use_lockfile = true
    encrypt      = true
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project = var.project
      Course  = "DSO303"
      Managed = "terraform"
    }
  }
}

# CloudFront WAF rules must live in us-east-1 whatever region the rest runs in.
provider "aws" {
  alias  = "use1"
  region = "us-east-1"
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# Only the first two AZs are used. Everything below is built per-AZ.
data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  azs     = slice(data.aws_availability_zones.available.names, 0, 2)
  account = data.aws_caller_identity.current.account_id
  name    = var.project
}
