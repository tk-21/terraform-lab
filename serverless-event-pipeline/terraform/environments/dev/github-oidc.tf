# GitHub Actions OIDC 設定
# アクセスキーを使用しない CI/CD 認証基盤を構築する。
# GitHub Actions が OIDC トークンを取得し、AssumeRoleWithWebIdentity で IAM ロールを引き受ける。
#
# アクセスキーとの比較:
#   アクセスキー: 永続的な認証情報 → 漏洩リスク・ローテーション管理コストが高い
#   OIDC: 実行ごとに短命トークンを発行 → 漏洩しても自動期限切れ・管理コスト低
#
# GitHub Secrets に保存する値: AWS_ACCOUNT_ID のみ（アクセスキー一切不要）

# ── GitHub Actions OIDC プロバイダ ─────────────────────────────────────

# GitHub Actions OIDC エンドポイントを AWS アカウントの ID プロバイダとして登録する。
# AWS アカウントに 1 つだけ作成する（複数の Terraform 管理環境で共有する）。
#
# ※ OIDC プロバイダが既にアカウントに存在する場合は、この resource ブロックを削除し
#    以下の data source に置き換えること（重複作成エラーを防ぐ）:
#
#    data "aws_iam_openid_connect_provider" "github_actions" {
#      url = "https://token.actions.githubusercontent.com"
#    }
#
#    そして下の aws_iam_role の Principal を data source の ARN に変更する。
resource "aws_iam_openid_connect_provider" "github_actions" {
  url = "https://token.actions.githubusercontent.com"

  # aud クレーム: GitHub Actions が AssumeRoleWithWebIdentity を呼び出す際に
  # 使用するクライアント ID。AWS STS は "sts.amazonaws.com" を要求する。
  client_id_list = ["sts.amazonaws.com"]

  # GitHub Actions OIDC エンドポイントの TLS 証明書サムプリント。
  # 2 つ登録することで GitHub のサムプリントローテーション中も認証が継続できる。
  # 参照: https://docs.github.com/en/actions/deployment/security-hardening-your-deployments/about-security-hardening-with-openid-connect
  thumbprint_list = [
    "6938fd4d98bab03faadb97b34396831e3780aea1", # 旧サムプリント
    "1c58a3a8518e8759bf075b76b750d4f2df264fcd", # 新サムプリント（2023年更新）
  ]

  tags = local.common_tags
}

# ── GitHub Actions IAM ロール ─────────────────────────────────────────

# sep-dev-github-actions-role:
#   GitHub Actions ワークフローが引き受ける IAM ロール。
#   最小権限の原則に基づき、sep-dev-* リソースへの操作のみを許可する。
resource "aws_iam_role" "github_actions" {
  name        = "${var.project}-${var.environment}-github-actions-role"
  description = "GitHub Actions OIDC 用 IAM ロール。sep-dev CI/CD パイプラインで使用する。"
  # セッション有効期限: 3600 秒（1 時間）。apply と統合テストを含む CD ジョブに十分な時間。
  max_session_duration = 3600

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "GitHubActionsOIDCAssumeRole"
        Effect = "Allow"
        Principal = {
          Federated = aws_iam_openid_connect_provider.github_actions.arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            # aud クレーム検証: sts.amazonaws.com 宛てのトークンのみを受け入れる。
            # 他の AWS サービス向けトークンでの AssumeRole を防ぐ。
            "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          }
          StringLike = {
            # sub クレーム検証: 指定リポジトリからの OIDC トークンのみを許可する。
            #
            # 許可する GitHub Actions サブジェクト:
            #   1. "repo:<org>/<repo>:ref:refs/heads/main"
            #      CD ワークフロー（main への push）での Terraform apply に使用する。
            #   2. "repo:<org>/<repo>:pull_request"
            #      CI ワークフロー（PR トリガー）での Terraform plan に使用する。
            #
            # ※ より厳格にする場合（CD のみに限定）:
            #      "repo:${var.github_repository}:ref:refs/heads/main"
            #    ただし CI の terraform-plan ジョブが OIDC 認証できなくなるため、
            #    plan 専用の読み取りロールを別途作成すること。
            "token.actions.githubusercontent.com:sub" = [
              "repo:${var.github_repository}:ref:refs/heads/main",
              "repo:${var.github_repository}:pull_request",
            ]
          }
        }
      }
    ]
  })

  tags = local.common_tags
}

# ── GitHub Actions IAM ポリシー（最小権限）────────────────────────────

# 権限設計の方針:
#   - リソース制限: 全ての Statement で sep-* リソースに限定する（* リソース禁止）
#   - 例外: EventSourceMapping・IAM OIDC・CloudWatch など ARN 制限が効かない API のみ * を使用
#   - アクション: 各サービスで Terraform が必要とする操作のみ許可する

resource "aws_iam_policy" "github_actions_deploy" {
  name        = "${var.project}-${var.environment}-github-actions-deploy-policy"
  description = "GitHub Actions CD 用デプロイ権限（Lambda・S3・DynamoDB・Kinesis・SQS）"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # Lambda 関数・エイリアス・バージョン管理。
        # sep-* 関数のみに限定し、他プロジェクトの Lambda への誤操作を防ぐ。
        Sid    = "LambdaFunctionManagement"
        Effect = "Allow"
        Action = [
          "lambda:CreateFunction",
          "lambda:DeleteFunction",
          "lambda:UpdateFunctionCode",
          "lambda:UpdateFunctionConfiguration",
          "lambda:PublishVersion",
          "lambda:CreateAlias",
          "lambda:UpdateAlias",
          "lambda:DeleteAlias",
          "lambda:GetFunction",
          "lambda:GetFunctionConfiguration",
          "lambda:GetAlias",
          "lambda:ListAliases",
          "lambda:ListVersionsByFunction",
          "lambda:AddPermission",
          "lambda:RemovePermission",
          "lambda:PutFunctionConcurrency",
          "lambda:GetFunctionConcurrency",
          "lambda:PutFunctionEventInvokeConfig",
          "lambda:GetFunctionEventInvokeConfig",
          "lambda:TagResource",
          "lambda:UntagResource",
          "lambda:ListFunctions",
          # CD: カナリアデプロイとロールバックで必要
          "lambda:InvokeFunction",
        ]
        Resource = [
          "arn:aws:lambda:ap-northeast-1:*:function:${var.project}-*",
          # エイリアス・バージョン ARN（function:name:qualifier 形式）
          "arn:aws:lambda:ap-northeast-1:*:function:${var.project}-*:*",
        ]
      },
      {
        # Lambda イベントソースマッピング（ESM）管理。
        # ESM の ARN は uuid 形式で事前に予測できないため Resource: * が必要（AWS の制約）。
        # ただし関数名のフィルタリングは対象関数側の権限で保護される。
        Sid    = "LambdaESMManagement"
        Effect = "Allow"
        Action = [
          "lambda:CreateEventSourceMapping",
          "lambda:UpdateEventSourceMapping",
          "lambda:DeleteEventSourceMapping",
          "lambda:GetEventSourceMapping",
          "lambda:ListEventSourceMappings",
        ]
        Resource = "*"
      },
      {
        # S3 バケット管理（バケットレベル操作）。
        # sep-* バケットのみに限定する。
        Sid    = "S3BucketManagement"
        Effect = "Allow"
        Action = [
          "s3:CreateBucket",
          "s3:DeleteBucket",
          "s3:GetBucketPolicy",
          "s3:PutBucketPolicy",
          "s3:DeleteBucketPolicy",
          "s3:GetBucketNotification",
          "s3:PutBucketNotification",
          "s3:GetBucketVersioning",
          "s3:PutBucketVersioning",
          "s3:GetEncryptionConfiguration",
          "s3:PutEncryptionConfiguration",
          "s3:GetBucketPublicAccessBlock",
          "s3:PutPublicAccessBlock",
          "s3:GetLifecycleConfiguration",
          "s3:PutLifecycleConfiguration",
          "s3:GetBucketTagging",
          "s3:PutBucketTagging",
          "s3:GetBucketAcl",
          "s3:GetBucketLocation",
          "s3:ListBucket",
        ]
        Resource = "arn:aws:s3:::${var.project}-*"
      },
      {
        # S3 オブジェクト操作（Lambda zip・テストデータ・DLQ アーカイブ）。
        Sid    = "S3ObjectManagement"
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:GetObject",
          "s3:DeleteObject",
          "s3:GetObjectVersion",
          "s3:DeleteObjectVersion",
          "s3:GetObjectTagging",
          "s3:PutObjectTagging",
        ]
        Resource = "arn:aws:s3:::${var.project}-*/*"
      },
      {
        # DynamoDB テーブル・GSI・Streams 管理。
        # sep-dev-* テーブルのみに限定する（events / aggregations）。
        Sid    = "DynamoDBManagement"
        Effect = "Allow"
        Action = [
          "dynamodb:CreateTable",
          "dynamodb:DeleteTable",
          "dynamodb:UpdateTable",
          "dynamodb:DescribeTable",
          "dynamodb:DescribeTimeToLive",
          "dynamodb:UpdateTimeToLive",
          "dynamodb:DescribeContinuousBackups",
          "dynamodb:UpdateContinuousBackups",
          "dynamodb:TagResource",
          "dynamodb:UntagResource",
          "dynamodb:ListTagsOfResource",
          # Streams: aggregator ESM の設定確認・テスト用
          "dynamodb:DescribeStream",
          "dynamodb:GetRecords",
          "dynamodb:GetShardIterator",
          "dynamodb:ListStreams",
          # 統合テスト: E2E テストでの DynamoDB 操作
          "dynamodb:PutItem",
          "dynamodb:GetItem",
          "dynamodb:DeleteItem",
          "dynamodb:Query",
          "dynamodb:Scan",
          "dynamodb:BatchWriteItem",
          "dynamodb:UpdateItem",
        ]
        Resource = [
          "arn:aws:dynamodb:ap-northeast-1:*:table/${var.project}-${var.environment}-*",
          "arn:aws:dynamodb:ap-northeast-1:*:table/${var.project}-${var.environment}-*/stream/*",
          "arn:aws:dynamodb:ap-northeast-1:*:table/${var.project}-${var.environment}-*/index/*",
        ]
      },
      {
        # Kinesis Data Streams 管理。
        # sep-dev-events-stream のみに限定する。
        Sid    = "KinesisManagement"
        Effect = "Allow"
        Action = [
          "kinesis:CreateStream",
          "kinesis:DeleteStream",
          "kinesis:DescribeStream",
          "kinesis:DescribeStreamSummary",
          "kinesis:IncreaseStreamRetentionPeriod",
          "kinesis:DecreaseStreamRetentionPeriod",
          "kinesis:StartStreamEncryption",
          "kinesis:StopStreamEncryption",
          "kinesis:EnableEnhancedMonitoring",
          "kinesis:DisableEnhancedMonitoring",
          "kinesis:AddTagsToStream",
          "kinesis:ListTagsForStream",
          "kinesis:ListShards",
          "kinesis:ListStreams",
          # 統合テスト: E2E テストでのレコード投入
          "kinesis:PutRecord",
          "kinesis:PutRecords",
        ]
        Resource = "arn:aws:kinesis:ap-northeast-1:*:stream/${var.project}-${var.environment}-*"
      },
      {
        # SQS キュー管理（メインキュー・DLQ を含む）。
        # sep-dev-* キューのみに限定する。
        Sid    = "SQSManagement"
        Effect = "Allow"
        Action = [
          "sqs:CreateQueue",
          "sqs:DeleteQueue",
          "sqs:SetQueueAttributes",
          "sqs:GetQueueAttributes",
          "sqs:GetQueueUrl",
          "sqs:AddPermission",
          "sqs:RemovePermission",
          "sqs:TagQueue",
          "sqs:UntagQueue",
          "sqs:ListQueueTags",
          "sqs:ListQueues",
          # 統合テスト・dlq-handler: メッセージの送受信
          "sqs:SendMessage",
          "sqs:ReceiveMessage",
          "sqs:DeleteMessage",
        ]
        Resource = "arn:aws:sqs:ap-northeast-1:*:${var.project}-${var.environment}-*"
      },
    ]
  })

  tags = local.common_tags
}

resource "aws_iam_policy" "github_actions_infra" {
  name        = "${var.project}-${var.environment}-github-actions-infra-policy"
  description = "GitHub Actions CI/CD 用インフラ管理権限（IAM・KMS・CloudWatch・X-Ray・EventBridge・SNS・SSM）"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # IAM ロール・ポリシー管理（Lambda 実行ロールの作成・更新・削除）。
        # sep-* ロール/ポリシーのみに限定する。
        Sid    = "IAMRoleAndPolicyManagement"
        Effect = "Allow"
        Action = [
          "iam:CreateRole",
          "iam:DeleteRole",
          "iam:GetRole",
          "iam:UpdateRole",
          "iam:ListRoles",
          "iam:AttachRolePolicy",
          "iam:DetachRolePolicy",
          "iam:ListAttachedRolePolicies",
          "iam:PutRolePolicy",
          "iam:GetRolePolicy",
          "iam:DeleteRolePolicy",
          "iam:ListRolePolicies",
          "iam:TagRole",
          "iam:UntagRole",
          "iam:ListRoleTags",
          "iam:CreatePolicy",
          "iam:DeletePolicy",
          "iam:GetPolicy",
          "iam:GetPolicyVersion",
          "iam:ListPolicyVersions",
          "iam:CreatePolicyVersion",
          "iam:DeletePolicyVersion",
          "iam:TagPolicy",
          "iam:ListPolicyTags",
        ]
        Resource = [
          "arn:aws:iam::*:role/${var.project}-*",
          "arn:aws:iam::*:policy/${var.project}-*",
        ]
      },
      {
        # IAM PassRole: Lambda・Scheduler へのロール付与。
        # iam:PassedToService 条件でロール引き渡し先を Lambda と Scheduler のみに限定する。
        Sid    = "IAMPassRoleToLambdaAndScheduler"
        Effect = "Allow"
        Action = "iam:PassRole"
        Resource = "arn:aws:iam::*:role/${var.project}-*"
        Condition = {
          StringEquals = {
            "iam:PassedToService" = [
              "lambda.amazonaws.com",
              "scheduler.amazonaws.com",
            ]
          }
        }
      },
      {
        # IAM OIDC プロバイダ管理（github-oidc.tf の aws_iam_openid_connect_provider）。
        # OIDC プロバイダの ARN は AWS が生成するため Resource: * が必要（AWS の制約）。
        Sid    = "IAMOIDCProviderManagement"
        Effect = "Allow"
        Action = [
          "iam:CreateOpenIDConnectProvider",
          "iam:GetOpenIDConnectProvider",
          "iam:DeleteOpenIDConnectProvider",
          "iam:ListOpenIDConnectProviders",
          "iam:UpdateOpenIDConnectProviderThumbprint",
          "iam:AddClientIDToOpenIDConnectProvider",
          "iam:RemoveClientIDFromOpenIDConnectProvider",
          "iam:TagOpenIDConnectProvider",
        ]
        Resource = "*"
      },
      {
        # KMS キー管理（Kinesis・S3・SQS の暗号化）。
        # KMS キー ARN は作成前に予測できないため Resource: * を使用する。
        # 暗号化操作（Decrypt/Encrypt）は sep-* リソースへのアクセスに必要な鍵のみで使用される。
        Sid    = "KMSManagement"
        Effect = "Allow"
        Action = [
          "kms:CreateKey",
          "kms:ScheduleKeyDeletion",
          "kms:CancelKeyDeletion",
          "kms:DescribeKey",
          "kms:GetKeyPolicy",
          "kms:PutKeyPolicy",
          "kms:GetKeyRotationStatus",
          "kms:EnableKeyRotation",
          "kms:DisableKeyRotation",
          "kms:CreateAlias",
          "kms:DeleteAlias",
          "kms:UpdateAlias",
          "kms:ListAliases",
          "kms:ListKeys",
          "kms:TagResource",
          "kms:UntagResource",
          "kms:ListResourceTags",
          # Lambda/Kinesis/S3 が暗号化データを読み書きするために必要
          "kms:Encrypt",
          "kms:Decrypt",
          "kms:ReEncryptFrom",
          "kms:ReEncryptTo",
          "kms:GenerateDataKey",
          "kms:GenerateDataKeyWithoutPlaintext",
        ]
        Resource = "*"
      },
      {
        # CloudWatch メトリクス・アラーム・ダッシュボード管理。
        # CloudWatch API はリソース ARN による制限が一部サポートされないため Resource: * を使用する。
        # ただし sep-* アラーム名への命名規則（CLAUDE.md 参照）で論理的に分離している。
        Sid    = "CloudWatchManagement"
        Effect = "Allow"
        Action = [
          "cloudwatch:PutMetricAlarm",
          "cloudwatch:DeleteAlarms",
          "cloudwatch:DescribeAlarms",
          "cloudwatch:DescribeAlarmsForMetric",
          "cloudwatch:PutDashboard",
          "cloudwatch:GetDashboard",
          "cloudwatch:DeleteDashboards",
          "cloudwatch:ListDashboards",
          "cloudwatch:PutMetricData",
          "cloudwatch:GetMetricData",
          "cloudwatch:GetMetricStatistics",
          "cloudwatch:ListMetrics",
        ]
        Resource = "*"
      },
      {
        # CloudWatch Logs グループ管理（Lambda ログ・Log Insights クエリ）。
        # sep-* のログと AWS サービスログのみを操作する。
        Sid    = "CloudWatchLogsManagement"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:DeleteLogGroup",
          "logs:PutRetentionPolicy",
          "logs:DescribeLogGroups",
          "logs:DescribeLogStreams",
          "logs:GetLogEvents",
          "logs:FilterLogEvents",
          "logs:TagLogGroup",
          "logs:TagResource",
          "logs:PutQueryDefinition",
          "logs:DescribeQueryDefinitions",
          "logs:DeleteQueryDefinition",
        ]
        Resource = "*"
      },
      {
        # X-Ray グループ・サンプリングルール管理（observability モジュール）。
        # X-Ray リソースは ARN による制限が一部サポートされないため Resource: * を使用する。
        Sid    = "XRayManagement"
        Effect = "Allow"
        Action = [
          "xray:CreateGroup",
          "xray:UpdateGroup",
          "xray:DeleteGroup",
          "xray:GetGroup",
          "xray:GetGroups",
          "xray:TagResource",
          "xray:UntagResource",
          "xray:ListTagsForResource",
          "xray:CreateSamplingRule",
          "xray:UpdateSamplingRule",
          "xray:DeleteSamplingRule",
          "xray:GetSamplingRules",
          "xray:GetSamplingStatisticSummaries",
        ]
        Resource = "*"
      },
      {
        # EventBridge ルール管理（DLQ アラームトリガー用ルール）。
        # sep-* ルールとデフォルトイベントバスのみに限定する。
        Sid    = "EventBridgeRulesManagement"
        Effect = "Allow"
        Action = [
          "events:PutRule",
          "events:DeleteRule",
          "events:DescribeRule",
          "events:ListRules",
          "events:PutTargets",
          "events:RemoveTargets",
          "events:ListTargetsByRule",
          "events:TagResource",
          "events:UntagResource",
        ]
        Resource = [
          "arn:aws:events:ap-northeast-1:*:rule/${var.project}-${var.environment}-*",
          "arn:aws:events:ap-northeast-1:*:event-bus/default",
        ]
      },
      {
        # EventBridge Scheduler 管理（dlq-handler の定期スケジュール）。
        # sep-dev-* スケジュールとデフォルトスケジュールグループのみに限定する。
        Sid    = "EventBridgeSchedulerManagement"
        Effect = "Allow"
        Action = [
          "scheduler:CreateSchedule",
          "scheduler:DeleteSchedule",
          "scheduler:GetSchedule",
          "scheduler:UpdateSchedule",
          "scheduler:ListSchedules",
          "scheduler:TagResource",
          "scheduler:UntagResource",
          "scheduler:ListTagsForResource",
        ]
        Resource = [
          "arn:aws:scheduler:ap-northeast-1:*:schedule/default/${var.project}-${var.environment}-*",
          "arn:aws:scheduler:ap-northeast-1:*:schedule-group/default",
        ]
      },
      {
        # SNS トピック管理（アラート通知・DLQ 再処理サマリー）。
        # sep-dev-* トピックのみに限定する。
        Sid    = "SNSManagement"
        Effect = "Allow"
        Action = [
          "sns:CreateTopic",
          "sns:DeleteTopic",
          "sns:GetTopicAttributes",
          "sns:SetTopicAttributes",
          "sns:Subscribe",
          "sns:Unsubscribe",
          "sns:GetSubscriptionAttributes",
          "sns:ListSubscriptionsByTopic",
          "sns:TagResource",
          "sns:UntagResource",
          "sns:ListTagsForResource",
          # CD: ロールバック時のアラート送信
          "sns:Publish",
        ]
        Resource = "arn:aws:sns:ap-northeast-1:*:${var.project}-${var.environment}-*"
      },
      {
        # SSM パラメータ管理（Powertools レイヤー ARN・Lambda Insights レイヤー ARN）。
        # sep-* パラメータと AWS 公式公開パラメータへの読み取りのみに限定する。
        Sid    = "SSMParameterManagement"
        Effect = "Allow"
        Action = [
          "ssm:GetParameter",
          "ssm:GetParameters",
          "ssm:PutParameter",
          "ssm:DeleteParameter",
          "ssm:DescribeParameters",
          "ssm:ListTagsForResource",
          "ssm:AddTagsToResource",
        ]
        Resource = [
          "arn:aws:ssm:ap-northeast-1:*:parameter/${var.project}/*",
          # AWS 公式公開パラメータ: /aws/service/lambda-insights/... など
          # Lambda Insights・Powertools レイヤー ARN の取得に必要
          "arn:aws:ssm:ap-northeast-1::parameter/aws/service/*",
        ]
      },
    ]
  })

  tags = local.common_tags
}

# ── IAM ポリシーアタッチ ──────────────────────────────────────────────

# デプロイポリシー（Lambda・S3・DynamoDB・Kinesis・SQS）
resource "aws_iam_role_policy_attachment" "github_actions_deploy" {
  role       = aws_iam_role.github_actions.name
  policy_arn = aws_iam_policy.github_actions_deploy.arn
}

# インフラ管理ポリシー（IAM・KMS・CloudWatch・X-Ray・EventBridge・SNS・SSM）
resource "aws_iam_role_policy_attachment" "github_actions_infra" {
  role       = aws_iam_role.github_actions.name
  policy_arn = aws_iam_policy.github_actions_infra.arn
}
