# SSHポート (22) への全開放を禁止するルール
# 0.0.0.0/0 または ::/0 からのポート22アクセスを非準拠と判定する
resource "aws_config_config_rule" "restricted_ssh" {
  name        = "csar-restricted-ssh"
  description = "SecurityGroupでSSH (ポート22) が0.0.0.0/0に開放されていないことを確認する"

  source {
    owner             = "AWS"
    source_identifier = "RESTRICTED_INCOMING_TRAFFIC"
  }

  input_parameters = jsonencode({
    blockedPort1 = "22"
  })

  scope {
    compliance_resource_types = ["AWS::EC2::SecurityGroup"]
  }

  depends_on = [aws_config_configuration_recorder_status.main]
}

# RDPポート (3389) への全開放を禁止するルール
resource "aws_config_config_rule" "restricted_rdp" {
  name        = "csar-restricted-rdp"
  description = "SecurityGroupでRDP (ポート3389) が0.0.0.0/0に開放されていないことを確認する"

  source {
    owner             = "AWS"
    source_identifier = "RESTRICTED_INCOMING_TRAFFIC"
  }

  input_parameters = jsonencode({
    blockedPort1 = "3389"
  })

  scope {
    compliance_resource_types = ["AWS::EC2::SecurityGroup"]
  }

  depends_on = [aws_config_configuration_recorder_status.main]
}
