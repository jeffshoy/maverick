terraform {
  backend "s3" {
    bucket = "prod-terraform-state"
    key    = "terraform.tfstate"
    region = "us-east-1"
  }
}
