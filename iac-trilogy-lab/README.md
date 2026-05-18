# iac-trilogy-lab

> 思考の偏りを破る IaC比較検証ラボ

同一AWSインフラを **Terraform / AWS CDK / Pulumi** の3ツールで実装し、
IaC設計哲学の差異を体感・言語化するハンズオン比較プロジェクト。

---

## このハンズオンで得られること

このラボを完走すると、以下を**自分の言葉で説明できるようになる**。

### 技術的理解

| テーマ | 具体的に得られるもの |
|---|---|
| **Terraform** | `count` vs `for_each` の危険性の理由、`default_tags` のトレードオフ、IMDSv2強制の技術的根拠 |
| **AWS CDK** | L1/L2/L3 Constructの抽象化レベルの差、L1エスケープハッチが必要になる場面、23リソースが5行に隠蔽される仕組み |
| **Pulumi** | `Output[T]` 型がなぜ存在するか、`apply()` が必要な場面と不要な場面の判断基準、Pulumi stateとTerraform stateの根本的な違い |
| **IaC設計全般** | State管理の3通りのアプローチ、「コスト設計ファースト」の実践、最小権限IAMの設計パターン |

### 思考の変化

- **Before**: 「とりあえずTerraform」 — 理由を問われると答えられない
- **After**: 「このケースはTerraformを選ぶ。なぜなら〜」と根拠を述べられる

3ツールを経験することで、**「当たり前に使っていたが根拠がなかったもの」** が浮き彫りになる。

### 副産物として身につくもの

- NAT Gatewayを使わない低コスト VPC 設計（月 $32 節約）
- SSH不要のSSM Session Manager接続パターン
- IMDSv2によるSSRF攻撃対策の実装方法
- Graviton2 (arm64) EC2の選定理由の言語化

---

## 動機

「とりあえずTerraform」という思考の偏りを意識的に解体するため、
あえて慣れていないツールで同じインフラを構築し、設計判断の差異を記録した。

---

## インフラ構成

```
Internet
    │
    ▼
Internet Gateway (itl-dev-igw)
    │
    ▼
VPC: 10.10.0.0/16 (itl-dev-vpc)
    │
    └── Public Subnet: 10.10.1.0/24 (itl-dev-public-1a / ap-northeast-1a)
              │
              ▼
          EC2: t4g.nano / Amazon Linux 2023 / arm64 (itl-dev-app)
          ├── IMDSv2 強制（SSRF対策）
          ├── IAM Instance Profile（SSM接続専用・最小権限）
          └── SSH禁止（SG: Egress のみ）

S3: itl-dev-artifacts-{account_id}（バージョニング有効・パブリックアクセス全ブロック）
AWS Budgets: $10/月 アラート（SNS → Email）
CloudWatch Alarm: EC2 CPU 80% 超 → SNS → Email
```

**設計原則**:
- NAT Gateway 不使用（$32/月 節約）
- SSH 禁止（SSM Session Manager のみ）
- IMDSv2 必須（`http_tokens = "required"`）
- IAMアクセスキー 禁止（Instance Profile / OIDC のみ）

---

## 実装フェーズ

| Phase | ツール | ディレクトリ | ADR |
|---|---|---|---|
| 1 | Terraform (HCL) | [`terraform/`](terraform/) | [ADR-001](adr/adr-001-terraform-baseline.md) |
| 2 | AWS CDK (TypeScript) | [`cdk/`](cdk/) | [ADR-002](adr/adr-002-cdk-vs-terraform.md) |
| 3 | Pulumi (Python) | [`pulumi/`](pulumi/) | [ADR-003](adr/adr-003-pulumi-vs-hcl.md) |
| 4 | 比較ADR・総括 | [`adr/`](adr/) [`docs/`](docs/) | [ADR-004](adr/adr-004-iac-selection-guide.md) |

---

## コスト設計

| リソース | 月次コスト目安 |
|---|---|
| EC2 t4g.nano × 1実装 | ~$0.68 |
| S3（最小利用） | ~$0.01 |
| CloudWatch Alarm | ~$0.10 |
| AWS Budgets | 無料枠 |
| **1実装あたり合計** | **~$1/月** |
| **3実装同時起動** | **~$3/月** |

NAT Gateway 不使用により **$32/月 を節約**。

---

## ハンズオン実行手順

### 前提条件

#### 必要ツール

| ツール | 最低バージョン | 確認コマンド |
|---|---|---|
| Terraform | >= 1.6.0 | `terraform version` |
| Node.js | >= 18.x | `node --version` |
| AWS CDK CLI | >= 2.100.0 | `npx cdk --version` |
| Python | >= 3.11 | `python3 --version` |
| Pulumi CLI | >= 3.x | `pulumi version` |
| AWS CLI | >= 2.x | `aws --version` |

#### AWS認証の確認

```bash
# 現在の認証情報を確認（アカウントIDも取得できる）
aws sts get-caller-identity

# 出力例:
# {
#     "UserId": "AIDA...",
#     "Account": "123456789012",   ← このアカウントIDを以降の手順で使用する
#     "Arn": "arn:aws:iam::123456789012:user/takuya"
# }
```

#### 必要なIAM権限

ハンズオン実行ユーザーには以下のサービスへの権限が必要:
`EC2`, `IAM`, `S3`, `SNS`, `CloudWatch`, `Budgets`, `SSM`, `DynamoDB`

---

### 0. 事前準備（3フェーズ共通）

Terraform の State バックエンドは手動で作成する必要がある。
CDK Bootstrap と Pulumi ログインも事前に実施すること。

#### 0-1. Terraform State 用 S3 バケット & DynamoDB テーブルの作成

```bash
export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export AWS_REGION="ap-northeast-1"

# S3 バケット作成（State 保存用）
aws s3api create-bucket \
  --bucket "itl-tfstate-${AWS_ACCOUNT_ID}" \
  --region "${AWS_REGION}" \
  --create-bucket-configuration LocationConstraint="${AWS_REGION}"

# バージョニング有効化（State ファイルの誤削除対策）
aws s3api put-bucket-versioning \
  --bucket "itl-tfstate-${AWS_ACCOUNT_ID}" \
  --versioning-configuration Status=Enabled

# 暗号化有効化
aws s3api put-bucket-encryption \
  --bucket "itl-tfstate-${AWS_ACCOUNT_ID}" \
  --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'

# パブリックアクセスブロック
aws s3api put-public-access-block \
  --bucket "itl-tfstate-${AWS_ACCOUNT_ID}" \
  --public-access-block-configuration \
  "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"

echo "✅ S3 バケット作成完了: itl-tfstate-${AWS_ACCOUNT_ID}"
```

```bash
# DynamoDB テーブル作成（State ロック用）
aws dynamodb create-table \
  --table-name "itl-tfstate-lock" \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --region "${AWS_REGION}"

echo "✅ DynamoDB テーブル作成完了: itl-tfstate-lock"
```

#### 0-2. CDK Bootstrap（CDK 用の準備リソース作成）

```bash
# CDK が CloudFormation デプロイに使う S3・ECR などを自動作成する
# 同一アカウント・リージョンで 1 回だけ実行すれば OK
npx cdk bootstrap "aws://${AWS_ACCOUNT_ID}/ap-northeast-1"

# 成功すると CDKToolkit スタックが CloudFormation に作成される
```

#### 0-3. Pulumi ログイン

```bash
# Pulumi Cloud を使う場合（無料アカウントで OK）
pulumi login

# ローカルファイルに state を保存する場合（アカウント不要）
pulumi login --local

# S3 に state を保存する場合（推奨: Terraform と同じバケットを使い回せる）
pulumi login "s3://itl-tfstate-${AWS_ACCOUNT_ID}"
```

---

### Phase 1: Terraform

#### Step 1-1. バックエンド設定の書き換え

`terraform/backend.tf` のバケット名をアカウントIDに合わせて書き換える:

```bash
cd terraform

# アカウントIDを確認
aws sts get-caller-identity --query Account --output text
```

`backend.tf` を開き、`REPLACE_WITH_ACCOUNT_ID` を実際のアカウントIDに書き換える:

```hcl
# 書き換え前
bucket = "itl-tfstate-REPLACE_WITH_ACCOUNT_ID"

# 書き換え後（例）
bucket = "itl-tfstate-123456789012"
```

#### Step 1-2. 変数ファイルの設定

`terraform/terraform.tfvars` を開き、値を書き換える:

```hcl
aws_account_id     = "123456789012"        # 自分のAWSアカウントID
notification_email = "your@email.com"      # アラート通知先メールアドレス
```

#### Step 1-3. 初期化・検証・プラン

```bash
# Terraform 初期化（プロバイダーのダウンロード・バックエンド設定）
terraform init

# 構文チェック
terraform fmt -check
terraform validate

# プランの確認（変更内容を事前に確認する）
terraform plan

# SSH(22) が含まれていないことを確認
terraform plan -out=tfplan.binary
terraform show -json tfplan.binary | \
  python3 -c "
import json, sys
data = json.load(sys.stdin)
text = json.dumps(data)
if '\"22\"' in text:
    print('❌ ポート22が検出されました。確認が必要です。')
else:
    print('✅ SSH(22)なし — 問題ありません')
"
```

#### Step 1-4. デプロイ（ユーザー自身が実行）

```bash
# インフラを作成する
terraform apply
```

> **確認プロンプト**: `Do you want to perform these actions?` が表示されたら `yes` と入力する。

#### Step 1-5. 動作確認

```bash
# 出力値の確認（EC2 インスタンスID・SSM 接続コマンドなど）
terraform output

# SSM 接続コマンドをそのまま実行できる
terraform output -raw ssm_connect_command
# → aws ssm start-session --target i-xxxxxxxxx --region ap-northeast-1
```

```bash
# SSM でEC2に接続（ブラウザのセッションが開く）
aws ssm start-session \
  --target "$(terraform output -raw ec2_instance_id)" \
  --region ap-northeast-1
```

EC2接続後、以下を確認する:

```bash
# IMDSv2 強制の確認（401が返ればOK — IMDSv1 がブロックされている）
curl -s -o /dev/null -w "%{http_code}" http://169.254.169.254/latest/meta-data/
# → 401

# S3 アクセスの確認（Instance Profile 経由で書き込める）
echo "test" | aws s3 cp - s3://itl-dev-artifacts-$(aws sts get-caller-identity --query Account --output text)/test.txt
aws s3 ls s3://itl-dev-artifacts-$(aws sts get-caller-identity --query Account --output text)/
# → 2026-xx-xx xx:xx:xx  5 test.txt

# SSM エージェントの稼働確認
systemctl status amazon-ssm-agent
```

#### Step 1-6. ADR-001 の記入

`terraform apply` が成功したら、実装を振り返り ADR-001 に自分の言葉で記入する:

```
adr/adr-001-terraform-baseline.md
```

記入すべき問い:
- このTerraformコードをなぜこう書いたか
- `for_each` を使うべき理由を数値で説明できるか
- `default_tags` のトレードオフは何か

---

### Phase 2: AWS CDK

#### Step 2-1. 依存パッケージのインストール

```bash
cd ../cdk
npm install
```

#### Step 2-2. 環境変数の設定

CDK はデプロイ時に `CDK_DEFAULT_ACCOUNT` と `CDK_DEFAULT_REGION` を参照する:

```bash
export CDK_DEFAULT_ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
export CDK_DEFAULT_REGION="ap-northeast-1"

# 通知先メール（cdk.json の context または環境変数で渡す）
export NOTIFICATION_EMAIL="your@email.com"
```

#### Step 2-3. TypeScript コンパイルチェック

```bash
# 型エラーがないことを確認
npx tsc --noEmit

# エラーがなければ以下が出力される（何も出ない = OK）
```

#### Step 2-4. CloudFormation テンプレートの生成・確認

```bash
# CDK が生成する CloudFormation テンプレートを確認する
npx cdk synth

# 生成されるリソース数を確認（Terraform の 22 と比較してみる）
npx cdk synth | grep "Type: AWS::" | wc -l
# → 23 前後（Terraform より多い。なぜか？ → ADR-002 で言語化する）

# SSH(22) が含まれていないことを確認
npx cdk synth | grep -E '"FromPort": 22|"ToPort": 22' && echo "❌ 要確認" || echo "✅ SSHなし"
```

#### Step 2-5. デプロイ前の差分確認

```bash
# 現在の AWS 環境との差分を確認（初回はすべて新規作成）
npx cdk diff
```

#### Step 2-6. デプロイ（ユーザー自身が実行）

```bash
# CloudFormation スタックをデプロイする
npx cdk deploy
```

> **確認プロンプト**: IAM リソースの変更について確認が求められたら `y` を入力する。

#### Step 2-7. 動作確認

```bash
# CloudFormation スタック出力の確認
aws cloudformation describe-stacks \
  --stack-name ItlDevStack \
  --query "Stacks[0].Outputs" \
  --output table

# EC2 インスタンス ID を取得して SSM 接続
INSTANCE_ID=$(aws cloudformation describe-stacks \
  --stack-name ItlDevStack \
  --query "Stacks[0].Outputs[?OutputKey=='Ec2InstanceId'].OutputValue" \
  --output text)

aws ssm start-session --target "${INSTANCE_ID}" --region ap-northeast-1
```

#### Step 2-8. 隠蔽リソースの確認（学習ポイント）

```bash
# CDK が生成した CloudFormation テンプレートをローカルで確認
cat cdk.out/ItlDevStack.template.json | \
  python3 -c "
import json, sys
data = json.load(sys.stdin)
resources = data.get('Resources', {})
print(f'CloudFormation リソース数: {len(resources)}')
for name, res in resources.items():
    print(f'  {res[\"Type\"]:50s} {name}')
"
# → Terraform のコード上の宣言数（約22）と比較して、
#   CDK が内部で生成したリソース数を把握する
```

#### Step 2-9. ADR-002 の記入

```
adr/adr-002-cdk-vs-terraform.md
```

記入すべき問い:
- L2 Construct が便利だった場面・不便だった場面はどこか
- L1エスケープハッチが必要になった理由を自分の言葉で説明できるか
- TypeScript の型安全性がインフラ設計に何をもたらしたか

---

### Phase 3: Pulumi

#### Step 3-1. Python 仮想環境のセットアップ

```bash
cd ../pulumi

# venv が未作成の場合
python3 -m venv ../.venv
source ../.venv/bin/activate

# 依存パッケージのインストール
pip install -r requirements.txt

# インストール確認
pulumi version
python3 -c "import pulumi; import pulumi_aws; print('OK')"
```

#### Step 3-2. スタック設定

```bash
# Pulumi スタックを選択（なければ作成）
pulumi stack select itl-dev --create

# AWS リージョンを設定
pulumi config set aws:region ap-northeast-1

# 通知先メールを Secret として設定（暗号化して state に保存される）
pulumi config set --secret notificationEmail "your@email.com"

# AWS アカウントID を設定
pulumi config set awsAccountId "$(aws sts get-caller-identity --query Account --output text)"

# 設定内容の確認（Secret は暗号化されて表示される）
pulumi config
```

#### Step 3-3. プレビュー（変更内容の確認）

```bash
# Terraform の plan、CDK の diff に相当する
pulumi preview

# 作成されるリソース一覧を整形して表示
pulumi preview --json 2>/dev/null | python3 -c "
import json, sys
data = json.load(sys.stdin)
steps = data.get('steps', [])
creates = [s for s in steps if s.get('op') == 'create']
print(f'作成リソース数: {len(creates)}')
for s in creates:
    urn = s.get('urn', '')
    name = urn.split('::')[-1] if '::' in urn else urn
    print(f'  + {name}')
"

# SSH(22) が含まれていないことを確認
pulumi preview --json 2>/dev/null | python3 -c "
import json, sys
data = json.load(sys.stdin)
text = json.dumps(data)
if 'port.*22' in text.lower() or '\"22\"' in text:
    print('❌ ポート22が検出 — 確認が必要です')
else:
    print('✅ SSH(22)なし — 問題ありません')
"
```

#### Step 3-4. デプロイ（ユーザー自身が実行）

```bash
# インフラを作成する
pulumi up
```

> **確認プロンプト**: `Do you want to perform this update?` が表示されたら `yes` を選択する。

#### Step 3-5. 動作確認

```bash
# Stack Outputs の確認（Terraform の terraform output に相当）
pulumi stack output

# SSM 接続
INSTANCE_ID=$(pulumi stack output instance_id)
aws ssm start-session --target "${INSTANCE_ID}" --region ap-northeast-1
```

#### Step 3-6. Pulumi State の確認（学習ポイント）

```bash
# State の内容を確認（Terraform の terraform state list に相当）
pulumi stack --show-urns

# State のエクスポート（JSON 形式）
pulumi stack export | python3 -c "
import json, sys
data = json.load(sys.stdin)
resources = data.get('deployment', {}).get('resources', [])
print(f'管理リソース数: {len(resources)}')
for r in resources:
    print(f'  {r[\"type\"]:60s} {r[\"id\"][:40] if \"id\" in r else \"\"}')
"
# → URN 形式の識別子（Terraform の resource_type.name と対比する）
```

#### Step 3-7. ADR-003 の記入

```
adr/adr-003-pulumi-vs-hcl.md
```

記入すべき問い:
- `Output[T]` 型で最初に詰まった場面とその解決の理解
- Python の表現力が HCL より優れていた場面・逆に不便だった場面
- Pulumi State と Terraform State の根本的な違い

---

### Phase 4: 比較ADR・総括の記入

Phase 4 は Claude Code に内容を書かせない。**Takuya 自身が書くフェーズ**。

#### Step 4-1. ADR-004 の記入

```
adr/adr-004-iac-selection-guide.md
```

3実装を経験した上で、以下を自分の言葉で記入する:
- 「とりあえずTerraform」という思考の偏りをどう発見・解体したか
- 各ツールの「良かった点・不便だった点」の実体験
- 「このケースでどのツールを選ぶか」のフレームワーク
- コスト設計ファーストを実践した感想

#### Step 4-2. 比較マトリクスの記入

```
docs/comparison-matrix.md
```

各ツールの主観評価欄（書いていて気持ちいい、デバッグのしやすさ等）と
リソース数・コードボリュームを実測値で記入する。

#### Step 4-3. 最終確認

以下を 15 分間口頭で説明できれば Phase 4 完了:

- 「なぜこのケースでは Terraform を選ぶか・選ばないか」
- 「CDK の L1エスケープハッチはなぜ存在するか」
- 「Pulumi の `Output[T]` 型はなぜ Terraform にないのか」

---

### クリーンアップ（コスト発生を止める）

**検証完了後は必ず destroy を実行すること。** 放置すると ~$3/月 の費用が発生し続ける。

```bash
# Phase 1: Terraform
cd terraform
terraform destroy

# Phase 2: CDK
cd ../cdk
npx cdk destroy

# Phase 3: Pulumi
cd ../pulumi
source ../.venv/bin/activate
pulumi destroy
```

State バックエンドのリソースは自動削除されないため、手動で削除する:

```bash
export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

# S3 バケットを空にしてから削除
aws s3 rm "s3://itl-tfstate-${AWS_ACCOUNT_ID}" --recursive
aws s3api delete-bucket --bucket "itl-tfstate-${AWS_ACCOUNT_ID}"

# DynamoDB テーブルを削除
aws dynamodb delete-table --table-name itl-tfstate-lock

echo "✅ クリーンアップ完了"
```

---

## トラブルシューティング

### Terraform: `NoSuchBucket` エラー

```
Error: Failed to get existing workspaces: S3 bucket does not exist.
```

→ 「0. 事前準備」の Step 0-1 で S3 バケットを作成してから `terraform init` を実行する。

### CDK: `Unable to resolve AWS account`

```
Unable to resolve AWS account to use. It must be either configured when you define your CDK Stack,
or through the environment
```

→ `CDK_DEFAULT_ACCOUNT` 環境変数を設定してから `cdk deploy` を実行する。

```bash
export CDK_DEFAULT_ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
```

### Pulumi: `error: Missing required configuration variable`

```
error: Missing required configuration variable 'itl-trilogy-lab:notificationEmail'
```

→ `pulumi config set --secret notificationEmail "your@email.com"` を実行する。

### SSM 接続: `TargetNotConnected`

```
An error occurred (TargetNotConnected) when calling the StartSession operation
```

→ EC2 の user_data で SSM エージェントが起動していない可能性がある。
EC2 コンソールでシステムログを確認し、1〜2 分待ってから再試行する。

---

## 学んだこと

[adr/adr-004-iac-selection-guide.md](adr/adr-004-iac-selection-guide.md) を参照。

---

## 比較ドキュメント

- [ARCHITECTURE.md](ARCHITECTURE.md) — インフラ構成・3実装の設計比較・全ファイル解説
- [比較マトリクス](docs/comparison-matrix.md) — 客観的比較 + Takuyaの主観評価
- [ADR-004: IaCツール選定ガイド](adr/adr-004-iac-selection-guide.md) — 総括と選定フレームワーク

---

## 参考リンク

- [Terraform 公式ドキュメント](https://developer.hashicorp.com/terraform)
- [AWS CDK 公式ドキュメント](https://docs.aws.amazon.com/cdk/)
- [Pulumi 公式ドキュメント](https://www.pulumi.com/docs/)
- [共通インフラ仕様](infra-spec.md)
