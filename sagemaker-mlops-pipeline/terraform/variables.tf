variable "environment" {
  description = "デプロイ環境名"
  type        = string
  default     = "dev"
}

variable "model_approval_threshold" {
  description = "モデル評価の合格閾値（精度）"
  type        = number
  default     = 0.8
}

variable "training_spot_instance" {
  description = "学習ジョブにスポットインスタンスを使用するフラグ"
  type        = bool
  default     = true
}

variable "endpoint_instance_type" {
  description = "推論エンドポイントのインスタンスタイプ（テスト: ml.t2.medium、本番: ml.m5.large）"
  type        = string
  default     = "ml.t2.medium"
}

variable "endpoint_model_name" {
  description = "初期デプロイ用SageMakerモデル名。初回Pipeline実行・モデル承認後に設定する。空文字の場合はEndpointを作成しない"
  type        = string
  default     = ""
}

variable "powertools_layer_version" {
  description = "AWS Lambda Powertools managed layerのバージョン（arm64）"
  type        = number
  default     = 79
}
