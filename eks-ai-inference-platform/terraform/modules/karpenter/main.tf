locals {
  name_prefix = "${var.project}-${var.environment}"

  # SQSキュー名はURLの最後のパスコンポーネントから取得する
  # KarpenterのinterruptionQueueName設定はキュー名のみを受け取るため
  queue_name = element(split("/", var.karpenter_queue_url), length(split("/", var.karpenter_queue_url)) - 1)
}

# Karpenter Helm Chart
# バージョンを固定することでCluster Autoscaler APIの破壊的変更による影響を防ぐ
resource "helm_release" "karpenter" {
  namespace        = "karpenter"
  create_namespace = true

  name       = "karpenter"
  repository = "oci://public.ecr.aws/karpenter"
  chart      = "karpenter"
  # v0.37.0: Kubernetes 1.30との互換性が確認されているバージョン
  version = "0.37.0"

  values = [
    yamlencode({
      settings = {
        clusterName     = var.cluster_name
        clusterEndpoint = var.cluster_endpoint
        # Spot中断通知をSQS経由で受け取るためにキュー名を指定する
        interruptionQueueName = local.queue_name
      }
      serviceAccount = {
        annotations = {
          # IRSAによりKarpenterコントローラーPodがAWSリソースを操作できるようにする
          # ノードロールARNではなくコントローラー用IRSAロールARNを設定する点に注意
          "eks.amazonaws.com/role-arn" = var.karpenter_controller_irsa_arn
        }
      }
      # システムノード(MNG)にKarpenter自身をスケジュールすることで
      # Karpenterが管理するノードが全停止してもKarpenter自体は動き続ける
      tolerations = []
      affinity = {
        nodeAffinity = {
          requiredDuringSchedulingIgnoredDuringExecution = {
            nodeSelectorTerms = [
              {
                matchExpressions = [
                  {
                    key      = "eks.amazonaws.com/nodegroup"
                    operator = "In"
                    values   = ["${local.name_prefix}-system"]
                  }
                ]
              }
            ]
          }
        }
      }
    })
  ]
}
