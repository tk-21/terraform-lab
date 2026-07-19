# ────────────────────────────────────────────────
# KEDA Helm インストール
# ────────────────────────────────────────────────

resource "helm_release" "keda" {
  namespace        = "keda"
  create_namespace = true

  name       = "keda"
  repository = "https://kedacore.github.io/charts"
  chart      = "keda"
  # バージョン固定: AMP PrometheusスケーラーのSigV4サポートが確認済みのバージョン
  version = "2.14.0"

  values = [
    yamlencode({
      operator = {
        replicaCount = 1
      }
      resources = {
        operator = {
          requests = {
            cpu    = "100m"
            memory = "128Mi"
          }
          limits = {
            cpu    = "500m"
            memory = "512Mi"
          }
        }
      }
      # KEDAオペレーターをGraviton (arm64) ノードに配置する
      # GPU g4dn (amd64) ノードを占有しないよう分離する
      nodeSelector = {
        "kubernetes.io/arch" = "arm64"
      }
      serviceAccount = {
        annotations = {
          # IRSA経由でAMPクエリ権限を付与する
          "eks.amazonaws.com/role-arn" = aws_iam_role.keda_amp_irsa.arn
        }
      }
    })
  ]

  # IAMロールが作成されてからHelmをインストールする
  depends_on = [aws_iam_role_policy.keda_amp_query]
}
