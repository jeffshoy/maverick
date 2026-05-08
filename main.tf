module "networking" {
  source = "./modules/networking"
}

module "kms" {
  source = "./modules/kms"
}

module "s3" {
  source = "./modules/s3"
}

module "ec2_asg" {
  source = "./modules/ec2-asg"
}

module "eks" {
  source = "./modules/eks"
}
