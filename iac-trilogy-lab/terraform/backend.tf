# S3バックエンド設定
# 事前に手動作成が必要なリソース:
#   S3バケット   : itl-tfstate-{AWSアカウントID}
#   DynamoDBテーブル: itl-tfstate-lock (パーティションキー: LockID, 型: String)
#
# 作成コマンド例（初回のみ）:
#   aws s3api create-bucket \
#     --bucket itl-tfstate-$(aws sts get-caller-identity --query Account --output text) \
#     --region ap-northeast-1 \
#     --create-bucket-configuration LocationConstraint=ap-northeast-1
#
#   aws dynamodb create-table \
#     --table-name itl-tfstate-lock \
#     --attribute-definitions AttributeName=LockID,AttributeType=S \
#     --key-schema AttributeName=LockID,KeyType=HASH \
#     --billing-mode PAY_PER_REQUEST \
#     --region ap-northeast-1

terraform {
  backend "s3" {
    # bucket は terraform init -backend-config で渡すか、直接書き換えること
    # 例: bucket = "itl-tfstate-123456789012"
    bucket         = "itl-tfstate-REPLACE_WITH_ACCOUNT_ID"
    key            = "iac-trilogy-lab/terraform/terraform.tfstate"
    region         = "ap-northeast-1"
    dynamodb_table = "itl-tfstate-lock"
    # 転送中・保存時暗号化を強制（S3 SSE-S3）
    encrypt = true
  }
}
