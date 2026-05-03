# =============================================================
# ec2.tf — EC2 インスタンス (master × 1, slave × 2)
# Tag: Role を動的 inventory のグループ分類に使用する。
# =============================================================

resource "aws_instance" "master" {
  ami                    = var.ami_id
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.ec2.id]
  key_name               = aws_key_pair.ec2.key_name

  root_block_device {
    volume_type           = "gp3"
    volume_size           = 8
    delete_on_termination = true
    encrypted             = true
  }

  user_data = <<-EOF
    #!/bin/bash
    hostnamectl set-hostname master
  EOF

  tags = {
    Name = "${var.project_name}-master"
    Role = "master" # Ansible dynamic inventory グループ名
  }
}

resource "aws_instance" "slave" {
  count = var.slave_count

  ami                    = var.ami_id
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.ec2.id]
  key_name               = aws_key_pair.ec2.key_name

  root_block_device {
    volume_type           = "gp3"
    volume_size           = 8
    delete_on_termination = true
    encrypted             = true
  }

  user_data = <<-EOF
    #!/bin/bash
    hostnamectl set-hostname slave-${count.index + 1}
  EOF

  tags = {
    Name = "${var.project_name}-slave-${count.index + 1}"
    Role = "slave"
  }
}
