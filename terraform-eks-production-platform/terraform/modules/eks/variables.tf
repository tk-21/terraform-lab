################################################################################
# EKSモジュール - 変数定義
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

variable "vpc_id" {
  description = "EKSを配置するVPCのID"
  type        = string
}

variable "private_subnet_ids" {
  description = "EKS Node GroupとPodを配置するプライベートサブネットのIDリスト"
  type        = list(string)
}

variable "vpc_cidr_block" {
  description = "VPCのCIDRブロック。セキュリティグループのインバウンドルール設定に使用"
  type        = string
}

# EKSバージョンを変数化する理由：
# マイナーバージョンアップ時にコードを変更せず変数のみで対応できるようにする。
# また、環境ごとに異なるバージョンを使用できる（本番は古いバージョンで安定稼働等）。
variable "cluster_version" {
  description = "EKS Kubernetesバージョン。マイナーバージョンまで指定（例: 1.31）"
  type        = string
  default     = "1.31"
}

# public_access_cidrsを変数化する理由：
# 0.0.0.0/0は禁止（CLAUDE.md参照）。
# 開発者のIPは変動するため環境変数・tfvarsで渡す設計にする。
variable "public_access_cidrs" {
  description = "EKS APIサーバーへのパブリックアクセスを許可するCIDRリスト。0.0.0.0/0は禁止"
  type        = list(string)
}

# インスタンスタイプをリストにする理由：
# Karpenterと組み合わせてスポットインスタンスを使う場合、
# 複数のインスタンスタイプを指定することでスポット枯渇リスクを分散できる。
# Managed Node Groupはクラスターが稼働するための最小限の常駐ノード用。
variable "node_group_instance_types" {
  description = "Managed Node Groupのインスタンスタイプリスト。コスト最適化のため複数指定を推奨"
  type        = list(string)
  default     = ["t3.medium", "t3.large"]
}

variable "node_group_desired_size" {
  description = "Managed Node Groupの希望ノード数。Karpenterが別途スケールするため最小限に"
  type        = number
  default     = 2
}

variable "node_group_min_size" {
  description = "Managed Node Groupの最小ノード数"
  type        = number
  default     = 1
}

variable "node_group_max_size" {
  description = "Managed Node Groupの最大ノード数"
  type        = number
  default     = 3
}

variable "node_group_disk_size" {
  description = "Nodeのルートボリュームサイズ(GB)。コンテナイメージキャッシュを考慮して50GB以上を推奨"
  type        = number
  default     = 50
}
