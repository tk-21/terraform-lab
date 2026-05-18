# -----------------------------------------------------------------------
# S3 バケット: アーティファクト保存用
# -----------------------------------------------------------------------
resource "aws_s3_bucket" "artifacts" {
  bucket = local.artifacts_bucket_name

  # 検証完了後に destroy する前提のため force_destroy を有効化
  # 本番環境では false にしてオブジェクトの誤削除を防ぐこと
  force_destroy = true

  tags = {
    Name = local.artifacts_bucket_name
  }
}

# バージョニング: 有効化
# オブジェクトの上書き・削除からの復旧を可能にする
# コスト増加はあるが、検証ラボでは学習目的で有効にする
resource "aws_s3_bucket_versioning" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  versioning_configuration {
    status = "Enabled"
  }
}

# パブリックアクセスブロック: 全設定を有効化
# S3バケットポリシーやACLによるパブリック公開を完全に遮断
# 誤設定によるデータ漏洩を防ぐための多層防御
resource "aws_s3_bucket_public_access_block" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# サーバーサイド暗号化: AES-256 (SSE-S3)
# KMS を使わない理由: 検証ラボではコスト最小化優先
# 本番環境では aws:kms + カスタマーキーへの移行を検討すること
resource "aws_s3_bucket_server_side_encryption_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    # バケット内の全オブジェクトに暗号化を強制（暗号化なしのアップロードを拒否）
    bucket_key_enabled = true
  }
}

# バケットオーナーシップ: BucketOwnerEnforced
# ACL を無効化し、バケットポリシーのみでアクセス制御する現代的な設定
resource "aws_s3_bucket_ownership_controls" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}
