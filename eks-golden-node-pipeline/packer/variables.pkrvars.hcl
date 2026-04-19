# Packer 変数定義ファイル
# GitHub Actions から --var-file で渡される

# AWSリージョン
aws_region = "ap-northeast-1"

# ベースAMI（Amazon Linux 2023 最新版）
# AMI IDは定期的に更新されるため、Data Sourceで動的取得する
base_ami_owner = "137112412989"  # Amazon公式アカウント
base_ami_name  = "al2023-ami-2023.*-kernel-*-arm64"  # arm64版

# インスタンスタイプ（ビルド用）
instance_type = "t4g.medium"  # arm64 Graviton

# EKSバージョン
eks_version = "1.30"

# AMI共有設定（必要な場合はAWSアカウントIDを追加）
ami_regions = ["ap-northeast-1"]
