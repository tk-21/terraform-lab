# Phase 4 — Lambda@Edge + 攻撃検知 Chatwork 通知

## 前フェーズの確認

以下が完了していること：
- WAF カスタムルールが動作している
- WAF ログが S3 に届いている
- Athena でブロックリクエストがクエリできる

---

## このフェーズの目的

Lambda@Edge でリクエスト検証を強化し、
WAF のブロック数が閾値を超えた際に Chatwork へ通知するパイプラインを構築する。
「守る → 検知 → 通知」のフルサイクルを完成させる。

## 完了条件

- [ ] Lambda@Edge（viewer_request）がデプロイされている
- [ ] CloudFront を経由しないリクエストが弾かれる（カスタムヘッダー検証）
- [ ] CloudWatch Alarm が WAF ブロック数に設定されている
- [ ] Alarm トリガー → EventBridge → Lambda → Chatwork 通知が動作する
- [ ] Chatwork に攻撃検知メッセージが届く

---

## 作成するファイル一覧

```
lambda/
├── edge/
│   └── viewer_request.js
└── alert_notifier/
    ├── main.py
    └── requirements.txt
terraform/modules/
└── alert/
    ├── main.tf
    ├── variables.tf
    └── outputs.tf
```

---

## 実装指示

### lambda/edge/viewer_request.js

**重要な制約**（Lambda@Edge の制限）：
- メモリ: 最大 128 MB
- タイムアウト: 最大 5 秒（viewer request）
- 外部 HTTP 呼び出し: **禁止**（タイムアウトリスクがあるため）
- 環境変数: **使用不可**（Lambda@Edge 固有の制約）
- ランタイム: Node.js（CloudFront は Python Lambda@Edge 非対応）

```javascript
'use strict';

// CloudFront が付与するカスタムヘッダーの期待値
// 環境変数が使えないため、SSM ではなくデプロイ時に Terraform で埋め込む
const EXPECTED_SECRET = process.env.CLOUDFRONT_SECRET || '__REPLACE_AT_DEPLOY__';

exports.handler = async (event) => {
  const request = event.Records[0].cf.request;
  const headers = request.headers;

  // 1. CloudFront カスタムヘッダー検証
  //    CloudFront を経由しないリクエストはこのヘッダーを持たない
  const cfSecret = headers['x-cloudfront-secret'];
  if (!cfSecret || cfSecret[0].value !== EXPECTED_SECRET) {
    return {
      status: '403',
      statusDescription: 'Forbidden',
      body: 'Access Denied',
    };
  }

  // 2. Host ヘッダー検証（ホストヘッダーインジェクション対策）
  const host = headers['host'];
  if (!host) {
    return {
      status: '400',
      statusDescription: 'Bad Request',
      body: 'Missing Host Header',
    };
  }

  // 3. リクエストをそのままオリジンへ
  return request;
};
```

**Terraform 側での Secret 埋め込み**：
```hcl
# Lambda@Edge は環境変数が使えないため、
# zip 化前にファイル内の placeholder を SSM の値で置換する
resource "null_resource" "embed_secret" {
  triggers = {
    secret_version = data.aws_ssm_parameter.cloudfront_secret.version
  }

  provisioner "local-exec" {
    command = <<-EOT
      sed 's/__REPLACE_AT_DEPLOY__/${data.aws_ssm_parameter.cloudfront_secret.value}/' \
        ${path.module}/../../lambda/edge/viewer_request.js \
        > /tmp/viewer_request_embed.js
    EOT
  }
}
```

### lambda/alert_notifier/main.py

```python
"""
WAF ブロック数閾値超過 → Chatwork 通知 Lambda
Lambda Powertools でログ・トレーシング
"""
import os
import json
import urllib.request
import urllib.parse

from aws_lambda_powertools import Logger, Tracer
from aws_lambda_powertools.utilities.typing import LambdaContext

logger = Logger()
tracer = Tracer()

CHATWORK_TOKEN_PARAM = os.environ["CHATWORK_TOKEN_PARAM"]
CHATWORK_ROOM_ID     = os.environ["CHATWORK_ROOM_ID"]


def get_ssm_parameter(name: str) -> str:
    import boto3
    ssm = boto3.client("ssm", region_name="ap-northeast-1")
    response = ssm.get_parameter(Name=name, WithDecryption=True)
    return response["Parameter"]["Value"]


@tracer.capture_lambda_handler
@logger.inject_lambda_context
def handler(event: dict, context: LambdaContext) -> dict:
    logger.info("WAF alarm triggered", extra={"event": event})

    alarm_name   = event["detail"]["alarmName"]
    state        = event["detail"]["state"]["value"]
    reason       = event["detail"]["state"]["reason"]
    region       = event["region"]

    token = get_ssm_parameter(CHATWORK_TOKEN_PARAM)

    # Chatwork メッセージ本文
    message = (
        f"[info][title]⚠️ WAF 攻撃検知アラート[/title]"
        f"アラーム名: {alarm_name}\n"
        f"状態: {state}\n"
        f"理由: {reason}\n"
        f"リージョン: {region}\n"
        f"コンソール: https://console.aws.amazon.com/wafv2/homev2/web-acls"
        f"[/info]"
    )

    url  = f"https://api.chatwork.com/v2/rooms/{CHATWORK_ROOM_ID}/messages"
    data = urllib.parse.urlencode({"body": message}).encode("utf-8")
    req  = urllib.request.Request(
        url,
        data=data,
        headers={
            "X-ChatWorkToken": token,
            "Content-Type": "application/x-www-form-urlencoded",
        },
        method="POST",
    )

    with urllib.request.urlopen(req) as resp:
        logger.info("Chatwork notified", extra={"status": resp.status})

    return {"statusCode": 200}
```

### modules/alert/main.tf

**CloudWatch Alarm**（WAF ブロック数監視）：
```hcl
resource "aws_cloudwatch_metric_alarm" "waf_block_high" {
  alarm_name          = "wcsl-${var.env}-waf-block-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "BlockedRequests"
  namespace           = "AWS/WAFV2"
  period              = 300   # 5 分
  statistic           = "Sum"
  threshold           = 100   # 5 分で 100 ブロックを超えたら通知

  dimensions = {
    Rule    = "ALL"
    WebACL  = var.webacl_name
    Region  = "us-east-1"   # CloudFront スコープのメトリクスは us-east-1
  }

  alarm_description = "WAF が 5 分間で 100 リクエスト以上ブロックした場合に通知"
  alarm_actions     = [aws_cloudwatch_event_rule.waf_alarm.arn]
}
```

**EventBridge ルール → Lambda 起動**：
```hcl
resource "aws_cloudwatch_event_rule" "waf_alarm" {
  name        = "wcsl-${var.env}-waf-alarm-trigger"
  description = "WAF ブロック数アラーム発火時に Lambda を起動"

  event_pattern = jsonencode({
    source      = ["aws.cloudwatch"]
    detail-type = ["CloudWatch Alarm State Change"]
    detail = {
      alarmName = ["wcsl-${var.env}-waf-block-high"]
      state     = { value = ["ALARM"] }
    }
  })
}

resource "aws_cloudwatch_event_target" "lambda" {
  rule = aws_cloudwatch_event_rule.waf_alarm.name
  arn  = aws_lambda_function.alert_notifier.arn
}
```

**Lambda 関数**（alert_notifier）：
```hcl
resource "aws_lambda_function" "alert_notifier" {
  function_name = "wcsl-${var.env}-alert-notifier"
  runtime       = "python3.12"
  architectures = ["arm64"]   # Graviton2
  handler       = "main.handler"
  role          = aws_iam_role.alert_lambda.arn
  filename      = data.archive_file.alert_notifier.output_path
  timeout       = 30

  environment {
    variables = {
      CHATWORK_TOKEN_PARAM = "/${var.project}/${var.env}/chatwork-token"
      CHATWORK_ROOM_ID     = var.chatwork_room_id
      POWERTOOLS_LOG_LEVEL = "INFO"
      POWERTOOLS_SERVICE_NAME = "waf-alert-notifier"
    }
  }

  tracing_config {
    mode = "Active"   # X-Ray トレーシング有効
  }
}
```

**IAM ロール**（alert_lambda）：
- SSM Parameter Store の特定パス（`/wcsl/*/chatwork-token`）の `GetParameter` のみ
- CloudWatch Logs への書き込み
- X-Ray への書き込み
- ワイルドカード禁止

---

## 動作確認手順

```bash
# 1. 攻撃シミュレーションでアラームを発火させる
CF_DOMAIN=$(terraform output -raw cloudfront_domain_name)

# 連続リクエストで WAF ブロックを量産（100 件超）
for i in $(seq 1 120); do
  curl -s "https://${CF_DOMAIN}/?id=1' OR '1'='1" > /dev/null
done

# 2. CloudWatch Alarm の状態確認
aws cloudwatch describe-alarms \
  --alarm-names "wcsl-dev-waf-block-high" \
  --query 'MetricAlarms[0].StateValue'
# → "ALARM" になること

# 3. Lambda ログ確認
aws logs tail /aws/lambda/wcsl-dev-alert-notifier --since 5m

# 4. Chatwork に通知が届いていること確認

# 5. Lambda@Edge 動作確認（ALB に直接アクセスして 403 を確認）
ALB_DNS=$(terraform output -raw alb_dns_name)
curl -I https://${ALB_DNS}
# → 403 Forbidden（CloudFront ヘッダーがないため）
```

---

## 口頭説明チェック（フェーズ 4 完了後）

1. **Lambda@Edge が環境変数を使えない理由と回避策**
   - Edge ロケーションへのデプロイの仕組み
   - Secret を埋め込む方法のリスクと対策

2. **WAF メトリクスのリージョンが us-east-1 になる理由**
   - CloudFront スコープ WAF のメトリクスの特殊性
   - CloudWatch Alarm を ap-northeast-1 に置けない制約

3. **アラーム閾値（100 ブロック/5 分）の根拠**
   - 本番での閾値設計の考え方
   - False Positive アラームを減らす工夫

4. **EventBridge vs SNS のアラーム通知選択**
   - SNS → Lambda より EventBridge の方が柔軟な理由
   - イベントパターンフィルタリングの活用

---

## 次フェーズへの引き継ぎ情報

Phase 5（最終フェーズ）での確認事項：
- Lambda@Edge ログは CloudFront エッジロケーションに記録される
  → `us-east-1` の CloudWatch Logs を確認すること
- ADR 4 本を自分の言葉で記述すること（AI 生成禁止）