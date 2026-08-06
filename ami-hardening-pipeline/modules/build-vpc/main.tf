resource "aws_default_vpc" "default" {
  tags = {
    Name = "DO-NOT-USE-default-vpc"
  }
}

resource "aws_vpc" "build" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "${var.project_name}-${var.environment}-build-vpc"
  }
}

resource "aws_internet_gateway" "build" {
  vpc_id = aws_vpc.build.id

  tags = {
    Name = "${var.project_name}-${var.environment}-build-igw"
  }
}

# Single public subnet — Image Builder build instances are ephemeral and only
# need outbound internet (package repos, SSM, AWS APIs), so a NAT gateway isn't
# worth the recurring cost here.
resource "aws_subnet" "build" {
  vpc_id                  = aws_vpc.build.id
  cidr_block              = var.subnet_cidr
  availability_zone       = var.availability_zone
  map_public_ip_on_launch = true

  tags = {
    Name = "${var.project_name}-${var.environment}-build-subnet"
  }
}

resource "aws_route_table" "build" {
  vpc_id = aws_vpc.build.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.build.id
  }

  tags = {
    Name = "${var.project_name}-${var.environment}-build-rt"
  }
}

resource "aws_route_table_association" "build" {
  subnet_id      = aws_subnet.build.id
  route_table_id = aws_route_table.build.id
}

resource "aws_default_security_group" "default" {
  vpc_id = aws_vpc.build.id

  tags = {
    Name = "DO-NOT-USE-default-sg"
  }
}
