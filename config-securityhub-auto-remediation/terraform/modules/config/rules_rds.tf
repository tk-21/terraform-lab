# RDSストレージ暗号化必須ルール
# 暗号化はインプレース変更不可のため、違反時はスナップショット経由の対応が必要
resource "aws_config_config_rule" "rds_storage_encrypted" {
  name        = "csar-rds-storage-encrypted"
  description = "RDSインスタンスのストレージが暗号化されていることを確認する"

  source {
    owner             = "AWS"
    source_identifier = "RDS_STORAGE_ENCRYPTED"
  }

  scope {
    compliance_resource_types = ["AWS::RDS::DBInstance"]
  }

  depends_on = [aws_config_configuration_recorder_status.main]
}

# RDSパブリックアクセス禁止ルール
# PubliclyAccessible=true のインスタンスは非準拠と判定される
resource "aws_config_config_rule" "rds_public_access_check" {
  name        = "csar-rds-instance-public-access-check"
  description = "RDSインスタンスがパブリックにアクセス可能でないことを確認する"

  source {
    owner             = "AWS"
    source_identifier = "RDS_INSTANCE_PUBLIC_ACCESS_CHECK"
  }

  scope {
    compliance_resource_types = ["AWS::RDS::DBInstance"]
  }

  depends_on = [aws_config_configuration_recorder_status.main]
}
