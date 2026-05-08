module "networking" {
  source = "./modules/networking"

  vpc_cidr = var.vpc_cidr
}

module "kms" {
  source = "./modules/kms"

  environment = var.environment
}

module "s3" {
  source = "./modules/s3"

  bucket_name = var.bucket_name
}

module "ec2_asg" {
  source = "./modules/ec2-asg"

  instance_type      = var.instance_type
  subnet_ids         = var.subnet_ids
  security_group_ids = var.security_group_ids
  key_name           = var.key_name
}

module "eks" {
  source = "./modules/eks"

  cluster_name       = var.cluster_name
  subnet_ids         = var.subnet_ids
  security_group_ids = var.security_group_ids
}
