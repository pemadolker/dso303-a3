data "aws_ec2_managed_prefix_list" "cloudfront" {
  name = "com.amazonaws.global.cloudfront.origin-facing"
}

# ALB: only CloudFront's edge servers may reach it.
resource "aws_security_group" "alb" {
  name        = "${local.name}-alb-sg"
  description = "ALB entry point"
  vpc_id      = aws_vpc.main.id

  # Only CloudFront's edge servers may connect (443 with a domain, 80 without one).
  ingress {
    description     = "CloudFront origin-facing"
    from_port       = local.origin_port
    to_port         = local.origin_port
    protocol        = "tcp"
    prefix_list_ids = [data.aws_ec2_managed_prefix_list.cloudfront.id]
  }
  egress {
    description = "to targets"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [var.vpc_cidr]
  }
}

# API tasks: only the ALB may reach them.
resource "aws_security_group" "app" {
  name        = "${local.name}-app-sg"
  description = "Fargate tasks: port 3000 from ALB only"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "from ALB"
    from_port       = 3000
    to_port         = 3000
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }
  egress {
    description = "outbound (NAT, S3 endpoint, RDS)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "lambda" {
  name        = "${local.name}-lambda-sg"
  description = "VPC lambdas: no inbound"
  vpc_id      = aws_vpc.main.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Database: only the app tier and the VPC lambdas, on 5432.
resource "aws_security_group" "db" {
  name        = "${local.name}-db-sg"
  description = "PostgreSQL from app tier only"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "from API tasks"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.app.id]
  }
  ingress {
    description     = "from worker lambdas"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.lambda.id]
  }
}
