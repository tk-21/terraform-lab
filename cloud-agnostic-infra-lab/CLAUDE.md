# cloud-agnostic-infra-lab

## プロジェクト概要

同一ワークロード（シンプルなHTTP APIサーバー）を AWS / GCP / Azure の3クラウドに
Terraform で構築し、設計判断・コスト・運用差異を比較する。

**目的**: 「AWS一択」という思考の偏りを意図的に破り、
「比較検討した上でAWSを選択できるエンジニア」として面接で説明できるようにする。

---

## ディレクトリ構成

```
cloud-agnostic-infra-lab/
├── CLAUDE.md
├── aws/
│   ├── main.tf
│   ├── variables.tf
│   ├── outputs.tf
│   └── modules/
│       ├── network/
│       ├── compute/
│       └── loadbalancer/
├── gcp/
│   ├── main.tf
│   ├── variables.tf
│   ├── outputs.tf
│   └── modules/
│       ├── network/
│       ├── compute/
│       └── loadbalancer/
├── azure/
│   ├── main.tf
│   ├── variables.tf
│   ├── outputs.tf
│   └── modules/
│       ├── network/
│       ├── compute/
│       └── loadbalancer/
├── comparison/
│   ├── cost.md
│   ├── network-concepts.md
│   ├── iam-concepts.md
│   └── operations.md
└── adr/
    ├── adr-001-why-same-workload.md
    ├── adr-002-terraform-for-all.md
    └── adr-003-why-aws-in-production.md
```

---

## 構築するワークロード（3クラウド共通）

- **VPC / VNet**: パブリック + プライベートサブネット
- **ロードバランサー**: L7 HTTP
- **Computeインスタンス**: 最小スペック（arm64 / Spot 優先）
- **アプリ**: nginx（Hello World レスポンス）
- **セキュリティグループ / Firewall**: HTTP(80)のみ許可

---

## 絶対ルール（MUST）

### コスト
- NAT Gateway は**禁止**（月$32相当の無駄）
- 代替: パブリックサブネット配置 or VPCエンドポイント
- インスタンスは最小スペック（t4g.nano相当）かつ Spot/Preemptible
- GCP: `e2-micro`（無料枠対象）を優先
- Azure: `B1s` を使用

### ファイル命名
- フェーズファイルは `phase1.md`, `phase2.md` のようにシンプルな名前のみ
- モジュール名は `snake_case`

### コードスタイル
- Terraformのコメントはすべて**日本語**で「なぜ」を書く（「何をするか」は書かない）
- `terraform fmt` 適用済みの状態で出力する
- 各リソースに `project` / `env` タグ必須

### IAM / セキュリティ
- 最小権限原則: 必要なポリシーのみ付与
- ハードコードされたクレデンシャル禁止
- クレデンシャルは環境変数 or Secret Manager 経由

### ADR
- `adr/` 配下のファイルの **「判断理由」セクションは必ず自分の言葉で記述**
- AI生成文章をそのまま貼ることは禁止
- ADRは構築完了後に口頭で15分説明できることをゴールとする

---

## タグ規約

```hcl
tags = {
  Project     = "cloud-agnostic-infra-lab"
  Environment = "dev"
  ManagedBy   = "terraform"
  Cloud       = "aws" # or "gcp" / "azure"
}
```

---

## フェーズ一覧

| フェーズ | 内容 |
|---------|------|
| phase1  | AWS 構築（ベースライン） |
| phase2  | GCP 構築 |
| phase3  | Azure 構築 |
| phase4  | 比較レポート生成 |
| phase5  | ADR 執筆 + 口頭説明チェックポイント |

---

## 口頭説明チェックポイント（面接想定）

各フェーズ完了後に以下を自分の言葉で答えられるか確認する：

1. 「なぜこのクラウドはこの設計になっているのか」
2. 「AWSとの概念の違いはどこか」
3. 「このクラウドで本番運用するなら何が課題か」
4. 「結局なぜAWSを選ぶのか（または選ばないのか）」