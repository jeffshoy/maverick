data "aws_ami" "latest_amazon_linux" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}

resource "aws_launch_template" "this" {
  name_prefix   = "enterprise-lt-"
  image_id      = data.aws_ami.latest_amazon_linux.id
  instance_type = var.instance_type

  vpc_security_group_ids = var.security_group_ids

  key_name = var.key_name

  user_data = base64encode(file("${path.module}/userdata.sh"))

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_autoscaling_group" "this" {
  name                = "enterprise-asg"
  desired_capacity    = 1
  max_size            = 3
  min_size            = 1
  vpc_zone_identifier = var.subnet_ids

  launch_template {
    id      = aws_launch_template.this.id
    version = "$Latest"
  }

  tag {
    key                 = "Name"
    value               = "enterprise-ec2"
    propagate_at_launch = true
  }
}
