################################################################################
# Terraformバックエンド設定
#
# S3をステート保存先、DynamoDBをロック管理に使用する。
# バックエンドリソース（S3バケット・DynamoDB）は自己参照できないため、
# 初回のみ手動またはbootstrapスクリプトで作成する必要がある（README参照）。
#
# バケット名に AWS_ACCOUNT_ID を含める理由：
# S3バケット名はグローバル一意のため、アカウントIDをサフィックスに付与して
# 名前衝突を防ぐ。
################################################################################

terraform {
  backend "s3" {
    # NOTE: AWSアカウントIDはCI/CDの環境変数から動的に解決するか、
    # 初回 `terraform init -backend-config=backend.conf` で渡すこと。
    # ハードコードしてリポジトリにコミットしてはならない。
    # 例: terraform init -backend-config="bucket=terraform-eks-production-platform-prod-tfstate-123456789012"
    bucket = "terraform-eks-production-platform-prod-tfstate-REPLACE_WITH_ACCOUNT_ID"

    # ステートファイルのキーはプロジェクト/環境で階層化する。
    # 将来的に複数環境（staging等）を管理する際に衝突を防ぐ。
    key = "terraform-eks-production-platform/prod/terraform.tfstate"

    region = "ap-northeast-1"

    # DynamoDBによる同時実行ロック。
    # チームで作業する場合に複数人が同時にapplyするのを防ぐ。
    dynamodb_table = "terraform-eks-production-platform-prod-tfstate-lock"

    # ステートファイル自体を暗号化（KMS管理キー使用）。
    # S3バケットレベルの暗号化と二重で保護する。
    encrypt = true
  }
}
