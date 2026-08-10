############################################
# VPC dedicated to the VDI / WorkSpaces platform
############################################

resource "aws_vpc" "vdi" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(var.tags, {
    Name = "${var.project_name}-vpc"
  })
}

# --- Subnets: one per AZ, private (no direct IGW route) ---

resource "aws_subnet" "workspaces" {
  count             = length(var.workspaces_subnet_cidrs)
  vpc_id            = aws_vpc.vdi.id
  cidr_block        = var.workspaces_subnet_cidrs[count.index]
  availability_zone = var.availability_zones[count.index]

  tags = merge(var.tags, {
    Name = "${var.project_name}-workspaces-${var.availability_zones[count.index]}"
  })
}

# --- Egress: NAT Gateway per AZ so WorkSpaces can reach AWS endpoints / patch sources ---
# Outbound only, no inbound internet exposure. If your org routes egress through an
# existing inspected proxy/firewall, replace this NAT with a route to that appliance instead.

resource "aws_eip" "nat" {
  count  = length(var.workspaces_subnet_cidrs)
  domain = "vpc"

  tags = merge(var.tags, {
    Name = "${var.project_name}-nat-eip-${count.index}"
  })
}

resource "aws_internet_gateway" "vdi" {
  vpc_id = aws_vpc.vdi.id

  tags = merge(var.tags, {
    Name = "${var.project_name}-igw"
  })
}

resource "aws_subnet" "public" {
  count                   = length(var.workspaces_subnet_cidrs)
  vpc_id                  = aws_vpc.vdi.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, count.index + 100)
  availability_zone       = var.availability_zones[count.index]
  map_public_ip_on_launch = false

  tags = merge(var.tags, {
    Name = "${var.project_name}-public-${var.availability_zones[count.index]}"
  })
}

resource "aws_nat_gateway" "vdi" {
  count         = length(var.workspaces_subnet_cidrs)
  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id

  tags = merge(var.tags, {
    Name = "${var.project_name}-nat-${count.index}"
  })

  depends_on = [aws_internet_gateway.vdi]
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.vdi.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.vdi.id
  }

  tags = merge(var.tags, {
    Name = "${var.project_name}-public-rt"
  })
}

resource "aws_route_table_association" "public" {
  count          = length(aws_subnet.public)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "workspaces" {
  count  = length(var.workspaces_subnet_cidrs)
  vpc_id = aws_vpc.vdi.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.vdi[count.index].id
  }

  # Route to on-prem AD/resources over VPN/Direct Connect, if applicable.
  dynamic "route" {
    for_each = var.onprem_ad_cidr != null ? [var.onprem_ad_cidr] : []
    content {
      cidr_block = route.value
      # Replace with your actual VPN Gateway / Transit Gateway attachment ID.
      # gateway_id = aws_vpn_gateway.onprem.id
      gateway_id = "REPLACE_WITH_VGW_OR_TGW_ID"
    }
  }

  tags = merge(var.tags, {
    Name = "${var.project_name}-workspaces-rt-${count.index}"
  })
}

resource "aws_route_table_association" "workspaces" {
  count          = length(aws_subnet.workspaces)
  subnet_id      = aws_subnet.workspaces[count.index].id
  route_table_id = aws_route_table.workspaces[count.index].id
}

############################################
# Security Group for WorkSpaces ENIs
############################################

resource "aws_security_group" "workspaces" {
  name        = "${var.project_name}-workspaces-sg"
  description = "Security group for WorkSpaces network interfaces"
  vpc_id      = aws_vpc.vdi.id

  # PCoIP
  egress {
    description = "PCoIP TCP to WorkSpaces gateway"
    from_port   = 4172
    to_port     = 4172
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "PCoIP UDP to WorkSpaces gateway"
    from_port   = 4172
    to_port     = 4172
    protocol    = "udp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # DCV (if using DCV protocol bundles)
  egress {
    description = "DCV HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "DCV WebSocket"
    from_port   = 4195
    to_port     = 4195
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Directory Service: DNS, Kerberos, LDAP
  egress {
    description = "DNS TCP"
    from_port   = 53
    to_port     = 53
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    description = "DNS UDP"
    from_port   = 53
    to_port     = 53
    protocol    = "udp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    description = "Kerberos"
    from_port   = 88
    to_port     = 88
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    description = "LDAP"
    from_port   = 389
    to_port     = 389
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    description = "SMB"
    from_port   = 445
    to_port     = 445
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  # General HTTPS egress for AWS API endpoints, updates, SSM
  egress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, {
    Name = "${var.project_name}-workspaces-sg"
  })
}
