# tgw-multi-vpc-lab

## プロジェクト概要
Transit Gateway + VPC Peering を使ったマルチVPCネットワーク設計の実装ハンズオン。
SAP試験で問われるHub-and-Spoke構成・TGWルートテーブルによる通信制御を、手を動かして体得する。

## 構成概要
```
[Spoke-A: Dev VPC] ──┐
                      ├──► [Transit Gateway] ──► [Hub: Shared Services VPC]
[Spoke-B: Prod VPC] ─┘         │
                                └──► [Inspection VPC (NFW)]
```

### VPC一覧
| VPC名 | CIDR | 用途 |
|-------|------|------|
| hub-vpc | 10.0.0.0/16 | Shared Services（DNS, Bastion等） |
| spoke-a-vpc | 10.1.0.0/16 | Dev環境 |
| spoke-b-vpc | 10.2.0.0/16 | Prod環境 |
| inspection-vpc | 10.3.0.0/16 | Network Firewall（集中検査） |

### 通信制御ポリシー
- Spoke-A ↔ Hub: 許可
- Spoke-B ↔ Hub: 許可
- Spoke-A ↔ Spoke-B: **禁止**（TGWルートテーブルで制御）
- 外部通信: Inspection VPC経由でNFWを通過

## ディレクトリ構成
```
tgw-multi-vpc-lab/
├── CLAUDE.md
├── modules/
│   ├── vpc/          # VPCモジュール（再利用可能）
│   ├── tgw/          # Transit Gatewayモジュール
│   ├── tgw-attach/   # TGWアタッチメント + ルートテーブル
│   └── nfw/          # Network Firewallモジュール
├── envs/
│   └── ap-northeast-1/
│       ├── main.tf
│       ├── variables.tf
│       ├── outputs.tf
│       └── terraform.tfvars
├── tests/            # connectivityテスト用スクリプト
├── docs/
│   ├── architecture.md   # Mermaidアーキテクチャ図
│   ├── adr/              # ADR（決定理由は自分で記述）
│   └── runbook.md
└── phase1.md〜phase5.md
```

## Terraform規約

### 必須制約（コスト最適化）
- NATゲートウェイ: **禁止**（VPCエンドポイントで代替）
- インスタンスタイプ: `t4g.nano`（arm64/Graviton2）
- Spot利用: EC2テスト用インスタンスはSpot
- ハードコードシークレット: **禁止**（SSM Parameter Store使用）
- IAMワイルドカード: **禁止**（ARN指定必須）

### コーディング規約
- `for_each` を `count` より優先
- `count` はbool的なon/offのみ許可
- タグ必須: `Project`, `Environment`, `ManagedBy = "terraform"`
- インラインコメント: 日本語で **"なぜ"** を説明（"何をするか"は不要）
- GitHub Actions OIDC認証（アクセスキー禁止）

### モジュール設計方針
- VPCモジュールは汎用設計（hub/spoke/inspection共通）
- TGWアタッチメントとルートテーブルは分離して管理
- `outputs.tf` でattachment IDとroute table IDを必ずexport

## 通知設定
- 通知先: Chatwork
- 認証: SSM Parameter Store (`/chatwork/api_token`)
- HTTPメソッド: POST, `application/x-www-form-urlencoded`, `X-ChatWorkToken` ヘッダー

## ターゲットリージョン
`ap-northeast-1`（東京）

## 各フェーズの完了基準
各フェーズ完了後に口頭説明チェック（15分）を行うこと:
- 「なぜこの設計を選んだか」
- 「TGWルートテーブルで何を制御しているか」
- 「トラブル時にどこを確認するか」

## ADR運用
`docs/adr/` 配下に各設計判断を記録する。
`## 決定理由` セクションは **自分の言葉で記述すること（AI生成禁止）**。

## よく使うコマンド
```bash
# 初期化
terraform -chdir=envs/ap-northeast-1 init

# プランの確認
terraform -chdir=envs/ap-northeast-1 plan

# 適用
terraform -chdir=envs/ap-northeast-1 apply

# 疎通確認（Phase4以降）
bash tests/connectivity_check.sh

# 全リソース削除
terraform -chdir=envs/ap-northeast-1 destroy
```