# 推論パイプラインの入力データ受け口
# EventBridgeトリガーのソースになるため、バケット通知を有効化
resource "aws_s3_bucket" "input" {
  bucket = "${var.name_prefix}-input-${var.account_id}"
  # 誤削除防止のため本番では force_destroy = false にする
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "input" {
  bucket = aws_s3_bucket.input.id
  # 推論入力データはパブリックアクセス不要
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket" "output" {
  bucket        = "${var.name_prefix}-output-${var.account_id}"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "output" {
  bucket                  = aws_s3_bucket.output.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# S3→EventBridgeの通知を有効化
# SNS/SQS直結より柔軟なルーティングができ、複数ターゲットへの扇状配信も可能
resource "aws_s3_bucket_notification" "input" {
  bucket      = aws_s3_bucket.input.id
  eventbridge = true
}
