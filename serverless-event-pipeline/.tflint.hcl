# TFLint 設定ファイル
# CI（ci.yml の lint-terraform ジョブ）で `tflint --init` 実行時に参照される。
# AWS プラグインにより terraform plan では検知できないプロバイダ固有の問題を検出する。
#   - 無効なリソースタイプ・廃止予定の引数
#   - 変数型の不一致・未使用変数
#   - AWS リソースの設定ミス（インスタンスタイプ・リージョン固有ルールなど）

plugin "aws" {
  enabled = true
  version = "0.32.0"
  source  = "github.com/terraform-linters/tflint-ruleset-aws"
}

# Terraform コアルール設定
# deprecated_interpolations: 非推奨の ${var.x} 形式補間を検出する
# terraform_required_version: terraform ブロックの required_version 記述を強制する
# terraform_required_providers: required_providers ブロックの記述を強制する
rule "terraform_deprecated_interpolation" {
  enabled = true
}

rule "terraform_required_version" {
  enabled = true
}

rule "terraform_required_providers" {
  enabled = true
}

rule "terraform_naming_convention" {
  enabled = false
  # プロジェクト固有の命名規則（sep-<env>-<role>）は checkov / カスタムルールで対応する。
  # TFLint のデフォルト命名ルールとの競合を防ぐため無効化する。
}
