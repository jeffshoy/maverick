terraform {
  backend "s3" {
    bucket = "staging-terraform-state"
    key    = "terraform.tfstate"
    region = "us-east-1"
  }
}
