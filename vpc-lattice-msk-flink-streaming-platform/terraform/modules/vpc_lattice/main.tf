resource "aws_vpclattice_service_network" "main" {
  name      = "${var.name_prefix}-service-network"
  auth_type = "AWS_IAM"
  tags      = var.tags
}

resource "aws_vpclattice_service_network_vpc_association" "main" {
  service_network_identifier = aws_vpclattice_service_network.main.id
  vpc_identifier             = var.vpc_id
  security_group_ids         = [var.sg_vpc_lattice_id]
  tags                       = var.tags
}

resource "aws_vpclattice_service" "msk" {
  name      = "${var.name_prefix}-msk-service"
  auth_type = "AWS_IAM"
  tags      = var.tags
}

resource "aws_vpclattice_service_network_service_association" "msk" {
  service_identifier         = aws_vpclattice_service.msk.id
  service_network_identifier = aws_vpclattice_service_network.main.id
  tags                       = var.tags
}

resource "aws_vpclattice_target_group" "msk" {
  name = "${var.name_prefix}-msk-tg"
  type = "IP"

  config {
    port           = 9098
    protocol       = "TCP"
    vpc_identifier = var.vpc_id
  }

  health_check {
    enabled  = true
    port     = 9098
    protocol = "TCP"
  }

  tags = var.tags
}

resource "aws_vpclattice_listener" "kafka" {
  name               = "${var.name_prefix}-kafka-listener"
  service_identifier = aws_vpclattice_service.msk.id
  protocol           = "TCP"
  port               = 9098

  default_action {
    forward {
      target_groups {
        target_group_identifier = aws_vpclattice_target_group.msk.id
        weight                  = 100
      }
    }
  }

  tags = var.tags
}

resource "aws_vpclattice_auth_policy" "service_network" {
  resource_identifier = aws_vpclattice_service_network.main.arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          AWS = [var.lambda_role_arn, var.flink_role_arn]
        }
        Action   = "vpc-lattice-svcs:Invoke"
        Resource = "*"
      }
    ]
  })
}
