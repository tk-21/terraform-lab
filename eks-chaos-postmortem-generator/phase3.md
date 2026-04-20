# ✅Phase 3: Step Functions・データ収集・Bedrock分析パイプライン

## Phase 1・2の実装サマリー（必ず読むこと）

**Phase 1完了**:
- VPC（10.0.0.0/16、ap-northeast-1）
- EKSクラスター（eks-chaos-postmortem-dev、Kubernetes 1.30）
- ノードグループ×2（baseline/chaos、ChaosTargetタグで区別）
- サンプルアプリ（chaos-targetネームスペース、nginx×3）

**Phase 2完了**:
- FIS実験テンプレート×4（pod-kill/node-termination/network-latency/cpu-stress）
- EventBridgeルール（FIS実験完了イベント検知）
- Orchestrator Lambda（fis-event-handler）→ DynamoDB冪等性チェック → Step Functions起動
- DynamoDBテーブル（eks-chaos-postmortem-experiments-dev）

## プロジェクト設計（必ず読むこと）

CLAUDE.mdを読み、命名規則・タグ戦略・Bedrock出力バリデーション6項目・禁止パターンを確認すること。

---

## Phase 3で実装するもの

### 1. Step Functionsワークフロー（terraform/modules/step_functions/）

**ワークフロー名**: `eks-chaos-postmortem-postmortem-workflow-dev`

`postmortem_workflow.asl.json`（Amazon States Language）:

```
States:
  ① CollectData         → data-collector Lambda呼び出し
  ② AnalyzeWithBedrock  → bedrock-analyzer Lambda呼び出し
  ③ FormatReport        → report-formatter Lambda呼び出し
  ④ Notify              → notifier Lambda呼び出し
  ⑤ Done                → 成功終了

エラーハンドリング:
  - 各ステートにRetry設定（最大3回、指数バックオフ）
  - 最終失敗時はCatch → ErrorNotify → DLQ記録
```

Step Functions IAMロール:
- Lambda: InvokeFunction（4つのLambda関数のみ）
- CloudWatch Logs: 実行ログ出力
- X-Ray: トレーシング

---

### 2. data-collector Lambda（lambda/data-collector/）

FIS実験に関連するデータを複数ソースから収集し、構造化して返す。

**main.py の処理フロー**:

```python
# 入力: Step Functionsから渡されたexperiment情報
# {
#   "experiment_id": "EXP-xxxxx",
#   "experiment_type": "pod-kill",
#   "start_time": "2026-04-18T10:00:00Z",
#   "end_time": "2026-04-18T10:05:00Z"
# }

# 収集ソース（並列実行でタイムアウト対策）:
# 1. CloudWatch Logs - Pod/Nodeのログ（障害開始時刻±10分）
# 2. Container Insights メトリクス（CPU/Memory/Network）
# 3. CloudTrail（実験期間中のAWS API操作履歴）
# 4. EKS Events（kubectl get events相当、EKS APIサーバー経由）
```

**実装の詳細**:

① CloudWatch Logs収集:
- ロググループ: `/aws/eks/eks-chaos-postmortem-dev/cluster`
- フィルタ: 障害開始時刻の-5分〜終了時刻の+5分
- キーワードフィルタ: `Error|Warning|OOMKill|Evicted|Failed`
- 最大1,000行（トークン数制限のため）

② Container Insightsメトリクス:
- メトリクス名前空間: `ContainerInsights`
- 取得メトリクス: `node_cpu_utilization`, `node_memory_utilization`, `pod_cpu_utilization`, `pod_memory_utilization`
- 期間: 実験前後10分、Period: 60秒
- 統計: Average, Maximum

③ CloudTrail収集:
- LookupEvents APIを使用
- 期間: 実験期間±5分
- フィルタ: EKS・EC2・FIS関連のAPIコール
- 最大50件

④ K8s Events収集:
- EKS API Serverへのkubernetes clientアクセス
- namespace: chaos-target, kube-system
- type: Warning のみ
- 実験期間±10分のイベント
- IRSAで認証（Lambda実行ロールにeks:DescribeClusterを付与）

**出力**（bedrock-analyzerへの入力）:
```json
{
  "experiment_id": "EXP-xxxxx",
  "experiment_type": "pod-kill",
  "start_time": "...",
  "end_time": "...",
  "duration_seconds": 300,
  "collected_data": {
    "cloudwatch_logs": [...],
    "metrics_summary": {...},
    "cloudtrail_events": [...],
    "k8s_events": [...]
  },
  "data_collection_timestamp": "..."
}
```

**IRSA設定（terraform/modules/eks/内に追記）**:
- data-collector Lambda用IRSAロール
- EKS APIアクセス用ServiceAccount

**IAMロール権限**:
- CloudWatch Logs: `logs:FilterLogEvents`, `logs:GetLogEvents`
- CloudWatch: `cloudwatch:GetMetricStatistics`, `cloudwatch:GetMetricData`
- CloudTrail: `cloudtrail:LookupEvents`
- EKS: `eks:DescribeCluster`（kubeconfigのエンドポイント取得）
- X-Ray・Powertools

**requirements.txt**:
```
aws-lambda-powertools>=2.0.0
boto3>=1.34.0
kubernetes>=28.1.0
```

---

### 3. bedrock-analyzer Lambda（lambda/bedrock-analyzer/）

収集データをBedrock Claude Sonnet 3.5に渡してポストモーテムを生成する。

**main.py の処理フロー**:

```python
# 設計意図:
# 収集データをBedrockへの入力に整形し、構造化されたポストモーテムを生成する。
# 出力は6項目の存在チェックを通過してから次ステップへ渡す。
```

**Bedrockへのプロンプト設計**:

```
System:
あなたはSREエンジニアです。
Kubernetes障害のポストモーテムを日本語で作成してください。
必ず以下の6項目をJSON形式で返してください。
JSON以外の文字列（説明文・マークダウン）は絶対に含めないでください。

{
  "summary": "障害の概要（2-3文）",
  "timeline": [
    {"time": "HH:MM:SS", "event": "発生したこと"}
  ],
  "root_cause": "根本原因の詳細説明",
  "impact": {
    "duration_minutes": 数値,
    "affected_pods": 数値,
    "affected_services": ["サービス名"]
  },
  "prevention": [
    {
      "title": "対策タイトル",
      "description": "対策の説明",
      "code_example": "TerraformまたはKubernetes YAMLのコード例"
    }
  ],
  "action_items": [
    {"priority": "high|medium|low", "task": "タスク内容", "owner": "担当チーム"}
  ]
}

User:
実験種別: {experiment_type}
実験ID: {experiment_id}
障害期間: {start_time} 〜 {end_time}（{duration_seconds}秒）

【CloudWatch Logsから検出したエラー】
{cloudwatch_logs_summary}

【Container Insightsメトリクス（最大値）】
{metrics_summary}

【CloudTrail APIコール】
{cloudtrail_summary}

【Kubernetes Events（Warning）】
{k8s_events_summary}
```

**Bedrock API設定**:
- モデル: `anthropic.claude-3-5-sonnet-20241022-v2:0`
- max_tokens: 4096
- temperature: 0（再現性重視）

**6項目バリデーション（CLAUDE.md準拠）**:
```python
# 必須6項目が全て存在することを確認してから次ステップへ
REQUIRED_KEYS = ["summary", "timeline", "root_cause", "impact", "prevention", "action_items"]

def validate_postmortem(result: dict) -> bool:
    # 全キーの存在確認
    # timelineが空でないことを確認
    # action_itemsが空でないことを確認
```

**IAMロール権限**:
- `bedrock:InvokeModel`（claude-3-5-sonnetのみ）
- X-Ray・Powertools

**requirements.txt**:
```
aws-lambda-powertools>=2.0.0
boto3>=1.34.0
```

---

### 4. report-formatter Lambda（lambda/report-formatter/）

ポストモーテムJSONをHTMLレポートに変換してS3に保存する。

**main.py の処理**:
- 入力: bedrock-analyzerの出力JSON
- HTMLテンプレートでレポート生成（インラインCSS使用）
- S3保存パス: `reports/{experiment_type}/{experiment_id}/postmortem.html`
- presigned URL生成（有効期限: 7日間）

**HTMLレポートのデザイン**:
- ヘッダー: プロジェクト名、実験ID、生成日時
- セクション別のカード表示（概要・タイムライン・根本原因・再発防止策・アクションアイテム）
- タイムラインは時系列テーブル表示
- コードブロックはシンタックスハイライト（インラインCSS）
- レスポンシブデザイン（モバイル対応）
- フッター: `Generated by Amazon Bedrock Claude Sonnet 3.5`

**IAMロール権限**:
- `s3:PutObject`, `s3:GetObject`（reportsバケットのみ）
- X-Ray・Powertools

---

### 5. S3バケット（terraform/modules/s3/）

- バケット名: `eks-chaos-postmortem-reports-{account_id}-dev`
- パブリックアクセスブロック: 全て有効
- バージョニング: 有効
- ライフサイクルルール: 90日後にGlacierへ移行
- CORS設定: presigned URLのブラウザアクセス用
- タグ: 必須5タグ

---

### 6. Lambdaモジュール更新（terraform/modules/lambda/）

Phase 2のfis-event-handlerに加え、以下4つのLambdaをTerraformで管理：

共通設定（全Lambda）:
- runtime: python3.12
- architecture: arm64
- timeout: 300秒
- memory_size: 512MB
- environment変数: PROJECT_NAME, ENVIRONMENT, AWS_ACCOUNT_ID
- X-Ray tracing: Active
- CloudWatch Logs: 30日間保持

各Lambda固有の設定:
- `data-collector`: timeout=300（CloudTrail・K8sアクセスに時間がかかるため）
- `bedrock-analyzer`: timeout=120（Bedrock推論時間）
- `report-formatter`: timeout=60
- `notifier`: timeout=30

---

## 実装上の注意事項

1. data-collectorのKubernetes clientはIRSAで認証。kubeconfigファイルは使用しない
2. Bedrockへのプロンプトはトークン数を計算し、8,000トークン以下に収める
3. ログ収集はPython concurrent.futuresで並列実行（タイムアウト対策）
4. S3のpresigned URLはreport-formatterで生成し、notifierに渡す
5. 全Lambdaにaws_lambda_function_event_invoke_configを設定（最大リトライ回数=2）

## 完了確認

- [ ] terraform/modules/step_functions/main.tf, postmortem_workflow.asl.json
- [ ] terraform/modules/s3/main.tf, outputs.tf
- [ ] terraform/modules/lambda/main.tf（全5 Lambda定義）
- [ ] lambda/data-collector/main.py, requirements.txt
- [ ] lambda/bedrock-analyzer/main.py, requirements.txt
- [ ] lambda/report-formatter/main.py, requirements.txt
- [ ] CLAUDE.mdのBedrock出力バリデーション6項目が実装されていること
- [ ] CLAUDE.mdの命名規則・タグ戦略と一致していること