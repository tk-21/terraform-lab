# ✅Phase 2: Lambda実装（drift-detector / bedrock-analyzer）
# IaC Drift Detective
#
# 【Phase 1 完了済み内容】
# - S3バケット (drift-detective-reports-{accountid}) 作成済み
# - IAMロール 4種作成済み (detector/analyzer/pr-creator/sfn)
# - EventBridge スケジュールルール作成済み
# - SSMパラメータ (github-token / chatwork-api-token) 作成済み
# - CloudWatch Logs グループ 作成済み
#
# 【このフェーズの目的】
# 2つのLambda関数を実装する:
# 1. drift-detector: S3のtfstateと実環境を比較してドリフトを検出
# 2. bedrock-analyzer: ドリフト情報をBedrockで分析し修復HCLを生成
#
# 【実行方法】
# claude < phase2.md
# ============================================================

以下のファイルを作成してください。CLAUDE.mdの設計方針を厳守すること。

## 1. drift-detector Lambda

### lambda/drift_detector/requirements.txt
```
aws-lambda-powertools[tracer]>=2.30.0
boto3>=1.34.0
```

### lambda/drift_detector/drift_scanner.py
```python
"""
ドリフトスキャナー
AWS ConfigとCloudFormation Drift Detection APIを使って
実環境のリソース状態を取得するモジュール
"""

以下の関数を実装:

def get_cloudformation_drifts(cfn_client, stack_names: list[str]) -> list[dict]:
    """
    CloudFormationスタックのドリフト検知を実行し結果を返す
    - DetectStackDrift APIでドリフト検知開始
    - DescribeStackDriftDetectionStatus APIでポーリング（最大60秒）
    - ドリフトしたリソースのリストを返す
    - 検知結果の各リソースは以下の形式:
      {
        "resource_type": str,      # AWS::EC2::Instance など
        "logical_id": str,
        "physical_id": str,
        "drift_status": str,       # MODIFIED / DELETED / NOT_CHECKED
        "expected_properties": dict,  # tfstateの期待値
        "actual_properties": dict,    # 実環境の値
      }
    """

def get_terraform_resources(s3_client, bucket: str, key: str) -> dict:
    """
    S3からtfstateファイルを取得してリソース一覧を解析する
    - tfstateのresourcesセクションをパース
    - リソースタイプ・名前・属性を抽出して返す
    - フォーマット: {resource_address: {type, name, attributes}}
    """
```

### lambda/drift_detector/state_comparator.py
```python
"""
tfstateと実環境の差分比較モジュール
CloudFormation drift APIとtfstateを突き合わせてドリフトを特定する
"""

def compare_states(tf_resources: dict, cfn_drifts: list[dict]) -> list[dict]:
    """
    tfstateのリソースとCloudFormationドリフト結果を比較
    差分があるリソースのみリストとして返す
    各差分は以下の形式:
    {
        "resource_address": str,   # terraform resource address
        "resource_type": str,
        "physical_id": str,
        "drift_type": str,         # PROPERTY_CHANGE / RESOURCE_DELETED / UNEXPECTED_RESOURCE
        "changed_properties": [
            {
                "property_path": str,
                "expected_value": any,
                "actual_value": any,
            }
        ],
        "severity": str,           # HIGH / MEDIUM / LOW
    }
    """

def calculate_severity(drift: dict) -> str:
    """
    ドリフトの重要度を判定する
    HIGH: セキュリティグループ・IAM・暗号化設定の変更
    MEDIUM: インスタンスタイプ・ストレージ設定の変更
    LOW: タグ・説明フィールドの変更
    """
```

### lambda/drift_detector/index.py
```python
"""
drift-detector Lambda ハンドラー
EventBridge → Step Functions から呼び出される

入力: Step Functionsのinput（空でも可）
出力:
{
    "drift_detected": bool,
    "drift_count": int,
    "drifts": [...],           # compare_statesの結果
    "scan_timestamp": str,     # ISO8601
    "monitored_stacks": [...], # スキャンしたCFnスタック名リスト
}
"""

# AWS Lambda Powertoolsを使用:
# - @logger.inject_lambda_context
# - @tracer.capture_lambda_handler
# - structured logging (JSON)

# 環境変数:
# - MONITORED_TFSTATE_BUCKET
# - MONITORED_TFSTATE_KEY
# - MONITORED_CFN_STACKS (カンマ区切り、例: "stack1,stack2")
# - POWERTOOLS_SERVICE_NAME = "drift-detector"
# - LOG_LEVEL = "INFO"

# エラーハンドリング:
# - S3アクセスエラー → ログ出力してraise（Step Functionsのリトライ機構に委ねる）
# - ドリフト検知タイムアウト → WARNING ログを出力し、該当スタックをスキップ
```

## 2. bedrock-analyzer Lambda

### lambda/bedrock_analyzer/requirements.txt
```
aws-lambda-powertools[tracer]>=2.30.0
boto3>=1.34.0
```

### lambda/bedrock_analyzer/prompt_builder.py
```python
"""
Bedrockへ送るプロンプトを構築するモジュール
"""

SYSTEM_PROMPT = """
あなたはAWSインフラストラクチャの専門家です。
Terraformで管理されているAWSリソースと実際の環境の差分（ドリフト）を分析し、
以下の形式で回答してください。必ずJSONのみを返し、それ以外のテキストは一切含めないこと。

{
  "drift_summary": "ドリフトの概要説明（日本語、100文字以内）",
  "root_cause": "推定される原因（日本語、200文字以内）",
  "severity": "HIGH または MEDIUM または LOW",
  "affected_resources": ["リソースアドレスのリスト"],
  "remediation_hcl": "修復用のTerraform HCLコード（完全なresourceブロック）",
  "remediation_steps": ["手動で対応すべき手順のリスト（日本語）"],
  "risk_assessment": "このドリフトを放置した場合のリスク（日本語、150文字以内）"
}
"""

def build_user_prompt(drifts: list[dict]) -> str:
    """
    ドリフト情報からユーザープロンプトを構築する
    - リソースタイプ・変更されたプロパティ・期待値・実際値を構造化して記載
    - 複数ドリフトがある場合は全てを含める
    """
```

### lambda/bedrock_analyzer/analyzer.py
```python
"""
Bedrock Claude Sonnet呼び出しモジュール
"""

MODEL_ID = "anthropic.claude-sonnet-4-20250514-v1:0"
BEDROCK_REGION = "us-east-1"

def analyze_drifts(drifts: list[dict]) -> dict:
    """
    ドリフト情報をBedrockで分析する
    - prompt_builder.pyでプロンプト構築
    - Bedrock InvokeModel API呼び出し（max_tokens=4096）
    - レスポンスのJSONパース
    - CLAUDE.mdのバリデーション5項目チェック
      1. drift_summary が文字列
      2. root_cause が存在
      3. remediation_hcl が存在し "resource" を含む
      4. severity が HIGH/MEDIUM/LOW のいずれか
      5. affected_resources がリスト
    - バリデーション失敗時は ValueError を raise
    """
```

### lambda/bedrock_analyzer/index.py
```python
"""
bedrock-analyzer Lambda ハンドラー
Step Functions から drift-detector の出力を受け取る

入力: drift-detectorの出力（driftsリストを含む）
出力: analyzerの結果 + 入力のdrifts情報をマージした dict
{
    "drift_summary": str,
    "root_cause": str,
    "severity": str,
    "affected_resources": [...],
    "remediation_hcl": str,
    "remediation_steps": [...],
    "risk_assessment": str,
    "original_drifts": [...],  # 入力のdriftsをそのまま引き継ぐ
    "analysis_timestamp": str,
    "report_s3_key": str,      # S3に保存したレポートのキー
}

# S3レポート保存:
# - キー: reports/{YYYY/MM/DD}/drift-report-{timestamp}.json
# - 保存後にreport_s3_keyを出力に含める

# AWS Lambda Powertoolsを使用
# 環境変数:
# - REPORTS_BUCKET
# - BEDROCK_REGION (default: us-east-1)
# - POWERTOOLS_SERVICE_NAME = "bedrock-analyzer"
# - LOG_LEVEL = "INFO"
"""
```

## 3. Terraform: Lambda モジュール

### terraform/modules/drift_detector/main.tf
```hcl
# drift-detector Lambda のTerraformリソース定義
# - aws_lambda_function (runtime: python3.12, arch: arm64)
# - aws_lambda_function_event_invoke_config (最大リトライ: 2)
# - ソースコードはlocal.file_hash でコンテンツハッシュを管理
# 環境変数をvar経由で設定
# IAMロールはPhase1で作成済みのものを参照（新規作成しない）
```

### terraform/modules/bedrock_analyzer/main.tf
```hcl
# bedrock-analyzer Lambda のTerraformリソース定義
# タイムアウト: 300秒（Bedrock呼び出しに時間がかかるため）
# メモリ: 512MB
```

## 完了確認

- [ ] Lambda Powertoolsのデコレータが全ハンドラーに適用されていること
- [ ] バリデーション5項目がanalyzer.pyに実装されていること
- [ ] S3へのレポート保存が実装されていること
- [ ] 環境変数が全てTerraformのaws_lambda_functionリソースに定義されていること
- [ ] コメントが日本語で記載されていること