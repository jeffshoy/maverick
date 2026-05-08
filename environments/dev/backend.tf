terraform {
  backend "s3" {
    bucket = "dev-terraform-state"
    key    = "terraform.tfstate"
    region = "us-east-1"
  }
}
