resource "aws_ecs_cluster" "main" {
  name = "deepdive-ecs"

  setting {
    name  = "containerInsights"
    value = "enabled"
    # Container Insights で CPU/Memory/ネットワーク使用量を CloudWatch に送信
    # Phase 4 の ECS vs EKS 比較ダッシュボードで使用する
  }
}

resource "aws_ecs_cluster_capacity_providers" "main" {
  cluster_name = aws_ecs_cluster.main.name

  capacity_providers = ["FARGATE", "FARGATE_SPOT"]

  default_capacity_provider_strategy {
    capacity_provider = "FARGATE"
    base              = 1
    # base=1: 最初の 1 タスクは必ず通常 Fargate で起動
    # Spot 中断が発生しても最低 1 タスクは安定稼働を保証
    weight = 1
  }

  default_capacity_provider_strategy {
    capacity_provider = "FARGATE_SPOT"
    base              = 0
    weight            = 4
    # weight 比 1:4 = Fargate 20% : Spot 80%
    # base 消化後の追加タスクは weight 比率で分配される
    #
    # タスク数別の分配例:
    # 1 タスク  → Fargate:1  Spot:0  （base=1 を優先消化）
    # 2 タスク  → Fargate:1  Spot:1
    # 5 タスク  → Fargate:1  Spot:4
    # 10 タスク → Fargate:2  Spot:8  （残り 9 を 1:4 で → F:1.8→2, S:7.2→8）
  }
}
