# =============================================================
# key_pair.tf — EC2 SSH キーペア
# Terraform で RSA 鍵を生成し AWS KeyPair に登録。
# 秘密鍵を ansible/keys/ec2_key.pem に保存（.gitignore 対象）。
#
# ※ この鍵は「運用者→EC2 SSH ログイン」用。
#    「master→slave lsyncd rsync」用鍵は Ansible ssh_key_dist role で別途生成。
# =============================================================

resource "tls_private_key" "ec2" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "aws_key_pair" "ec2" {
  key_name   = "${var.project_name}-key"
  public_key = tls_private_key.ec2.public_key_openssh
  tags       = { Name = "${var.project_name}-key" }
}

# 秘密鍵をローカルに保存（パーミッション 0600 必須）
resource "local_sensitive_file" "private_key" {
  content         = tls_private_key.ec2.private_key_pem
  filename        = "${path.module}/../ansible/keys/ec2_key.pem"
  file_permission = "0600"
}
