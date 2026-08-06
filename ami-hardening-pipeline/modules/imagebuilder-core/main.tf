data "aws_caller_identity" "current" {}

# IAM role assumed by Image Builder build instances
resource "aws_iam_role" "imagebuilder" {
  name = "${var.project_name}-${var.environment}-imagebuilder-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "imagebuilder" {
  role       = aws_iam_role.imagebuilder.name
  policy_arn = "arn:aws:iam::aws:policy/EC2InstanceProfileForImageBuilder"
}

# Required alongside EC2InstanceProfileForImageBuilder — without this, the
# instance can't fully register itself as SSM-managed under its own role, so
# this account's SSM Default Host Management Configuration silently takes over
# registration under AWSSystemsManagerDefaultEC2InstanceManagementRole instead,
# which has no Image Builder permissions and causes GetComponent to fail with
# AccessDeniedException (hit 2026-08-04 on the ubuntu2204 build).
resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.imagebuilder.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# EC2InstanceProfileForImageBuilder only covers Image Builder's own default-managed
# bucket, not a custom logs bucket — this extra statement grants write access to ours.
resource "aws_iam_role_policy" "logs_bucket_access" {
  name = "${var.project_name}-${var.environment}-imagebuilder-logs-access"
  role = aws_iam_role.imagebuilder.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "s3:PutObject",
        "s3:GetBucketLocation",
      ]
      Resource = [
        aws_s3_bucket.logs.arn,
        "${aws_s3_bucket.logs.arn}/*",
      ]
    }]
  })
}

resource "aws_iam_instance_profile" "imagebuilder" {
  name = "${var.project_name}-${var.environment}-imagebuilder-profile"
  role = aws_iam_role.imagebuilder.name
}

# S3 bucket for CIS compliance evidence (oscap reports, PowerShell validation transcripts)
resource "aws_s3_bucket" "logs" {
  bucket        = "${var.project_name}-${var.environment}-imagebuilder-logs-${data.aws_caller_identity.current.account_id}"
  force_destroy = false
}

resource "aws_s3_bucket_versioning" "logs" {
  bucket = aws_s3_bucket.logs.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "logs" {
  bucket = aws_s3_bucket.logs.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = var.kms_key_arn != null ? "aws:kms" : "AES256"
      kms_master_key_id = var.kms_key_arn
    }
  }
}

resource "aws_s3_bucket_public_access_block" "logs" {
  bucket                  = aws_s3_bucket.logs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Default build security group — no ingress, egress limited to HTTPS/HTTP for
# SSM/package installs. Only created when var.security_group_id is not set.
resource "aws_security_group" "build" {
  count       = var.security_group_id == null ? 1 : 0
  name        = "${var.project_name}-${var.environment}-imagebuilder-build-sg"
  description = "EC2 Image Builder build instances for ${var.project_name}-${var.environment}. No inbound access needed."
  vpc_id      = var.vpc_id

  egress {
    description = "HTTPS for SSM agent and package updates"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "HTTP for package updates"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-${var.environment}-imagebuilder-build-sg"
  }

  lifecycle {
    create_before_destroy = true
  }
}

locals {
  resolved_security_group_id = var.security_group_id != null ? var.security_group_id : one(aws_security_group.build[*].id)
}
