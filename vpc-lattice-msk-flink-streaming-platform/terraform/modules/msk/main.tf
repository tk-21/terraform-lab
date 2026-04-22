# MSK Serverlessクラスター
# aws_msk_serverless_cluster を使用（aws_msk_cluster とは別リソース）
resource "aws_msk_serverless_cluster" "main" {
  cluster_name = "${var.name_prefix}-msk-cluster"

  vpc_config {
    subnet_ids         = var.subnet_ids
    security_group_ids = [var.sg_msk_id]
  }

  client_authentication {
    sasl {
      iam {
        enabled = true
      }
    }
  }

  tags = var.tags
}

# MSKクラスターポリシー（IAMアクセス制御）
# Lambda ProducerにWrite、FlinkにReadを許可
data "aws_iam_policy_document" "msk_cluster_policy" {
  statement {
    sid    = "AllowProducerAccess"
    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = [var.lambda_role_arn]
    }

    actions = [
      "kafka:DescribeCluster",
      "kafka:GetBootstrapBrokers",
      "kafka-cluster:Connect",
      "kafka-cluster:AlterCluster",
      "kafka-cluster:DescribeCluster",
      "kafka-cluster:WriteData",
      "kafka-cluster:WriteDataIdempotently",
      "kafka-cluster:CreateTopic",
      "kafka-cluster:DescribeTopic",
      "kafka-cluster:AlterTopic",
    ]

    resources = [
      aws_msk_serverless_cluster.main.arn,
      "${aws_msk_serverless_cluster.main.arn}/*",
    ]
  }

  statement {
    sid    = "AllowFlinkAccess"
    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = [var.flink_role_arn]
    }

    actions = [
      "kafka:DescribeCluster",
      "kafka:GetBootstrapBrokers",
      "kafka-cluster:Connect",
      "kafka-cluster:DescribeCluster",
      "kafka-cluster:ReadData",
      "kafka-cluster:DescribeTopic",
      "kafka-cluster:DescribeGroup",
      "kafka-cluster:AlterGroup",
    ]

    resources = [
      aws_msk_serverless_cluster.main.arn,
      "${aws_msk_serverless_cluster.main.arn}/*",
    ]
  }
}

resource "aws_msk_cluster_policy" "main" {
  cluster_arn = aws_msk_serverless_cluster.main.arn
  policy      = data.aws_iam_policy_document.msk_cluster_policy.json
}
