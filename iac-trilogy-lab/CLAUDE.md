# iac-trilogy-lab — CLAUDE.md

## プロジェクト概要

**目的**: 同一AWSインフラを Terraform / AWS CDK / Pulumi の3ツールで実装し、IaC設計哲学の差異を体感・言語化する比較検証ラボ。

**思考の偏りを破る**: 「とりあえずTerraform」「コスト最適化は後回し」という思考パターンを意識的に解体する。

**リポジトリ構造**:
```
iac-trilogy-lab/
├── CLAUDE.md                  # このファイル（自動ロード）
├── infra-spec.md              # 共通インフラ仕様（3実装共通の正解定義）
├── terraform/                 # Phase 1: Terraform実装
├── cdk/                       # Phase 2: AWS CDK (TypeScript)実装
├── pulumi/                    # Phase 3: Pulumi (Python)実装
├── adr/                       # Phase 4: 比較ADR群
│   ├── adr-001-iac-tool-comparison.md
│   ├── adr-002-state-management.md
│   └── adr-003-cost-design-first.md
└── docs/
    └── comparison-matrix.md   # ツール比較マトリクス（最終成果物）
```

---

## 命名規則

| 種別 | ルール | 例 |
|---|---|---|
| プレフィックス | `itl`（iac-trilogy-lab） | `itl-vpc`, `itl-ec2` |
| 環境 | `dev` のみ（検証ラボ） | `itl-dev-vpc` |
| Terraform state bucket | `itl-tfstate-{account_id}` | — |
| CDK stack名 | `ItlDevStack` | — |
| Pulumi stack名 | `itl-dev` | — |

---

## 共通インフラ仕様（3実装で完全に同一にすること）

### ネットワーク
- **VPC CIDR**: `10.10.0.0/16`
- **Public Subnet**: `10.10.1.0/24`（ap-northeast-1a）
- **NAT Gateway**: **使用禁止**（コストゼロ設計）
- **Internet Gateway**: 1個

### コンピューティング
- **EC2**: t4g.nano（arm64 / Graviton2）
- **AMI**: Amazon Linux 2023（arm64）
- **接続方式**: SSM Session Manager のみ（SSH禁止・セキュリティグループにポート22不要）
- **IMDSv2**: 必須（`HttpTokens: required`）

### ストレージ
- **S3バケット**: `itl-dev-artifacts-{account_id}`
- **バージョニング**: 有効
- **パブリックアクセス**: 全ブロック

### コスト監視（Phase 1〜3全実装必須）
- **AWS Budgets**: 月次 $10 アラート（SNS通知）
- **CloudWatch**: EC2 CPU使用率アラート（80%超）

### IAM
- **EC2 Instance Profile**: SSM接続用ポリシーのみ（最小権限）
- **アクセスキー**: 使用禁止（OIDC / Instance Profile のみ）

---

## コスト設計（Cost-First原則）

> コスト最適化は後付けではなく、設計の出発点とする。

| リソース | 月次コスト目安 |
|---|---|
| EC2 t4g.nano（on-demand） | ~$0.68 |
| S3（最小利用） | ~$0.01 |
| CloudWatch | ~$0.10 |
| AWS Budgets | 無料枠 |
| **合計（1実装）** | **~$1/月** |
| **3実装同時起動** | **~$3/月** |

**コスト削減ルール**:
- NAT Gateway禁止（$32/月の節約）
- RDS・ElastiCache 未使用
- 検証完了後は即 `destroy`

---

## 禁止パターン（全フェーズ共通）

```
# ❌ 禁止
- SSHポート(22)のセキュリティグループ許可
- IAMアクセスキーのハードコード
- NAT Gatewayの使用
- IMDSv1の使用（HttpTokens: optional）
- パブリックS3バケット
- コスト監視なしの実装完了
```

---

## インラインコメント規則

**日本語で「なぜ」を書く**（何をするかではなく、なぜその選択をしたか）

```hcl
# Terraform例
resource "aws_instance" "app" {
  instance_type = "t4g.nano"
  # arm64(Graviton2)を選択: x86比較でコスト約20%削減、同等性能
  # t4g.nanoは検証ラボ用途に十分。本番移行時はt4g.smallへスケールアップ検討
}
```

```typescript
// CDK例
new ec2.Instance(this, 'AppInstance', {
  instanceType: ec2.InstanceType.of(ec2.InstanceClass.T4G, ec2.InstanceSize.NANO),
  // Graviton2選択理由: コスト最適化と学習目的（Terraform実装との選択根拠を統一）
});
```

```python
# Pulumi例
instance = aws.ec2.Instance("app-instance",
    instance_type="t4g.nano",
    # Graviton2: arm64アーキテクチャ。Pulumiではinstance_typeを文字列で指定する点がCDKと異なる
)
```

---

## 各フェーズの「問い」（実装前に必ず読む）

### Phase 1（Terraform）
- このインフラをTerraformで書く「当たり前」は何か？
- `for_each` と `count` をどこで使い分けるか、なぜか？

### Phase 2（CDK）
- コンストラクトの抽象化はTerraformのモジュールと何が違うか？
- 型安全性はインフラ設計においてどんな価値を持つか？

### Phase 3（Pulumi）
- Pythonのプログラミングパラダイムがインフラ記述に与える影響は？
- TerraformのHCLに比べてPulumiのOutputが難しい理由は何か？

### Phase 4（ADR）
- 3つのツールを経験した上で、あなたは「今後どのケースでどれを選ぶか」を説明できるか？
- コスト設計ファーストで実装して、後回しとの差を感じたか？

---

## Claude Code実行規則

- `claude < phase-XX-prompt.md` でフェーズごとに実行すること
- 各フェーズ完了後、次フェーズ実行前に手動で動作確認・`terraform plan` / `cdk diff` / `pulumi preview` を実施
- フェーズ間で仕様変更が生じた場合は `infra-spec.md` を更新してから次フェーズを実行
- 生成コードに疑問があれば、実装前に「なぜこの設計か」を15分間口頭説明できるか確認すること