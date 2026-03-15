resource "aws_db_subnet_group" "this" {
  name       = "${var.name}-dbsubnet"
  subnet_ids = var.private_subnet_ids
  tags = { Name = "${var.name}-dbsubnet" }
}

resource "aws_security_group" "db" {
  name        = "${var.name}-db-sg"
  description = "RDS SG"
  vpc_id      = var.vpc_id

  ingress {
    from_port                = 3306
    to_port                  = 3306
    protocol                 = "tcp"
    security_groups          = [var.ecs_security_group_id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.name}-db-sg" }
}

resource "aws_db_instance" "this" {
  identifier = "${var.name}-db"

  engine               = "mysql"
  engine_version       = "8.0"
  instance_class       = var.instance_class
  allocated_storage    = 20
  storage_type         = "gp3"

  db_name  = var.db_name
  username = var.db_username
  password = var.db_password

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.db.id]

  publicly_accessible  = false
  multi_az             = false
  skip_final_snapshot  = true
  deletion_protection  = false

  backup_retention_period = 0

  tags = { Name = "${var.name}-db" }
}
