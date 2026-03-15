data "aws_ami" "alma9" {
  most_recent = true
  owners      = ["764336703387"] # AlmaLinux OS Foundation (Community AMIs)

  filter {
    name   = "name"
    values = ["AlmaLinux OS 9*"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  filter {
    name   = "root-device-type"
    values = ["ebs"]
  }
}

resource "aws_security_group" "zabbix_server" {
  name        = "${var.name}-sg-zabbix-server"
  description = "Zabbix server SG"
  vpc_id      = var.vpc_id

  # SSH
  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.my_ip_cidr]
  }

  # Web UI
  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = [var.my_ip_cidr]
  }

  # Zabbix Server port
  ingress {
    description = "Zabbix server (10051) from VPC"
    from_port   = 10051
    to_port     = 10051
    protocol    = "tcp"
    cidr_blocks = ["10.10.0.0/16"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.name}-sg-zabbix-server" }
}

resource "aws_security_group" "target" {
  name        = "${var.name}-sg-target"
  description = "Target (agent) SG"
  vpc_id      = var.vpc_id

  # SSH
  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.my_ip_cidr]
  }

  # Zabbix agent port
  ingress {
    description = "Zabbix agent (10050) from VPC"
    from_port   = 10050
    to_port     = 10050
    protocol    = "tcp"
    cidr_blocks = ["10.10.0.0/16"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.name}-sg-target" }
}

resource "aws_instance" "zabbix_server" {
  ami                         = data.aws_ami.alma9.id
  instance_type               = var.instance_type_server
  subnet_id                   = var.subnet_id
  vpc_security_group_ids      = [aws_security_group.zabbix_server.id]
  key_name                    = var.key_name
  associate_public_ip_address = true

  tags = {
    Name = "${var.name}-zabbix-server"
    Role = "zabbix-server"
  }
}

resource "aws_instance" "target" {
  ami                         = data.aws_ami.alma9.id
  instance_type               = var.instance_type_target
  subnet_id                   = var.subnet_id
  vpc_security_group_ids      = [aws_security_group.target.id]
  key_name                    = var.key_name
  associate_public_ip_address = true

  tags = {
    Name = "${var.name}-target-01"
    Role = "zabbix-target"
  }
}
