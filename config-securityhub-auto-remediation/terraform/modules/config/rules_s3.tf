# S3バケットへのパブリック読み取りアクセス禁止ルール
# S3バケットの変更時にトリガーされる変更ドリブン評価
resource "aws_config_config_rule" "s3_public_read_prohibited" {
  name        = "csar-s3-bucket-public-read-prohibited"
  description = "S3バケットのパブリック読み取りACLを禁止する"

  source {
    owner             = "AWS"
    source_identifier = "S3_BUCKET_PUBLIC_READ_PROHIBITED"
  }

  scope {
    compliance_resource_types = ["AWS::S3::Bucket"]
  }

  depends_on = [aws_config_configuration_recorder_status.main]
}

# S3バケットのサーバーサイド暗号化必須ルール
resource "aws_config_config_rule" "s3_bucket_sse_enabled" {
  name        = "csar-s3-bucket-server-side-encryption-enabled"
  description = "S3バケットにSSEが設定されていることを確認する"

  source {
    owner             = "AWS"
    source_identifier = "S3_BUCKET_SERVER_SIDE_ENCRYPTION_ENABLED"
  }

  scope {
    compliance_resource_types = ["AWS::S3::Bucket"]
  }

  depends_on = [aws_config_configuration_recorder_status.main]
}
