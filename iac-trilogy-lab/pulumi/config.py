"""
共通設定モジュール

Terraform の locals.tf / CDK の props パターンに相当するが、
Pulumi では「ただの Python モジュール」として定義できる点が特徴。
クラスを強制されない（CDK の Construct と対比）。
"""
from typing import Dict

import pulumi

# Pulumi 設定オブジェクト: pulumi config set で管理される値を取得する
# Terraform の terraform.tfvars、CDK の cdk.json に相当するが、
# Pulumi は暗号化 secret を同一インターフェースで扱える点が優れている
config = pulumi.Config()

# 命名プレフィックス: iac-trilogy-lab (itl) + 環境 (dev)
PREFIX: str = "itl-dev"

# 共通タグ: 全リソースに付与
# Terraform: merge(local.common_tags, {...})
# CDK:       cdk.Tags.of(scope).add(key, value)
# Pulumi:    {**COMMON_TAGS, "Name": "..."} — Python の dict 展開がそのまま使える
COMMON_TAGS: Dict[str, str] = {
    "Project": "iac-trilogy-lab",
    "Env": "dev",
    "ManagedBy": "pulumi",   # Terraform/CDK 実装との差別化マーカー
    "CostOwner": "takuya",
}

# ネットワーク設定（infra-spec.md と一致させる）
VPC_CIDR: str = "10.10.0.0/16"
SUBNET_CIDR: str = "10.10.1.0/24"
SUBNET_AZ: str = "ap-northeast-1a"

# 通知先メールアドレス（secret として管理）
# Terraform では terraform.tfvars + .gitignore で管理していた sensitive 値を
# Pulumi はスタック設定に sealed secret として保存する。
# 暗号化は Pulumi Cloud または AWS KMS が担う。
# 設定方法: pulumi config set notificationEmail your@email.com --secret
NOTIFICATION_EMAIL: pulumi.Output[str] = config.require_secret("notificationEmail")

# AWS アカウント ID（S3 バケット名のサフィックスに使用）
# 設定方法: pulumi config set awsAccountId 123456789012
AWS_ACCOUNT_ID: str = config.require("awsAccountId")

# S3 バケット名: グローバルユニーク性を保つためアカウント ID をサフィックスに付与
ARTIFACTS_BUCKET_NAME: str = f"{PREFIX}-artifacts-{AWS_ACCOUNT_ID}"
