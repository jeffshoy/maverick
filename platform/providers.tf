terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # Recommended: use the same S3/DynamoDB remote state pattern as your
  # existing EC2 remediation Terraform workflows.
  # backend "s3" {
  #   bucket         = "your-tfstate-bucket"
  #   key            = "vdi/platform/terraform.tfstate"
  #   region         = "us-east-1"
  #   dynamodb_table = "your-tflock-table"
  #   encrypt        = true
  # }
}

provider "aws" {
  region = var.aws_region
}
