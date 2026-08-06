terraform {
  backend "s3" {
    bucket         = "ami-hardening-pipeline-tfstate-300512157817"
    key            = "dev/ami-hardening-pipeline/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "terraform-state-lock"
    encrypt        = true
  }
}
