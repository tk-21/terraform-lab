################################################################################
# VPCモジュール - 変数定義
################################################################################

variable "project_name" {
  description = "プロジェクト名。リソース命名に使用する"
  type        = string
}

variable "environment" {
  description = "環境名（prod, staging, dev）"
  type        = string
}

variable "common_tags" {
  description = "すべてのリソースに付与する共通タグ"
  type        = map(string)
}

# VPC CIDRを /16 にする理由：
# サブネット分割の柔軟性を確保するため。/24 を最小単位として
# Public×2 + Private×2 + Isolated×2 の6サブネットを収容しつつ、
# 将来的なAZ追加や用途別サブネット増設に対応できるよう /16 を採用。
variable "vpc_cidr" {
  description = "VPC全体のCIDRブロック。/16を推奨"
  type        = string
  default     = "10.0.0.0/16"
}

# AZをリストで持つ理由：
# ap-northeast-1a と ap-northeast-1c の2AZ構成。
# AZを変数化することで環境ごとのAZ差異に対応できる。
variable "availability_zones" {
  description = "使用するAZのリスト。2AZ構成を推奨"
  type        = list(string)
  default     = ["ap-northeast-1a", "ap-northeast-1c"]
}

# Publicサブネットは /24 で十分な理由：
# ALBとNAT GatewayのみデプロイするためIPアドレス消費が少ない。
# ALBは最大で数十のIPを消費するが、/24（254アドレス）で十分。
variable "public_subnet_cidrs" {
  description = "パブリックサブネットのCIDRリスト。AZと同じ順番で指定"
  type        = list(string)
  default     = ["10.0.0.0/24", "10.0.1.0/24"]
}

# Privateサブネットを /23 にする理由：
# EKSはPodにもVPC IPを消費する（VPC CNI）。
# t3.medium は最大17Pod。Node 10台想定で170IP必要なため
# /23（510IP）を確保。将来のスケールアウトに備え余裕を持たせる。
variable "private_subnet_cidrs" {
  description = "プライベートサブネットのCIDRリスト。EKS Node/Pod用に /23 を推奨"
  type        = list(string)
  default     = ["10.0.10.0/23", "10.0.12.0/23"]
}

# Isolatedサブネットを /24 にする理由：
# RDS・ElastiCacheはインスタンス数が少なくIPを多く消費しないため
# /24 で十分。Private より小さくしてIPアドレスを節約する。
variable "isolated_subnet_cidrs" {
  description = "分離サブネットのCIDRリスト。RDS・ElastiCache等のマネージドサービス用"
  type        = list(string)
  default     = ["10.0.20.0/24", "10.0.21.0/24"]
}

# NAT Gatewayを各AZに配置する理由：
# Single NAT GatewayはコストはAZ障害時に全AZのアウトバウンドが停止するリスクがある。
# 本番環境では高可用性を優先してAZごとにNAT Gatewayを配置する。
# 検証環境でコストを削減する場合は false にして1つのAZのみ使用する。
variable "enable_nat_gateway_per_az" {
  description = "AZごとにNAT Gatewayを作成するか。trueで高可用性、falseでコスト削減（検証用）"
  type        = bool
  default     = true
}
