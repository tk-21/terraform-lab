# aws-lsyncd-sync-infra

**Terraform × Ansible × lsyncd** による Web コンテンツリアルタイム同期基盤のハンズオン実装。

master EC2 の `/var/www/html` への変更を inotify で検知し、rsync over SSH で slave EC2 × 2 へ自動同期する **1:N 構成**。

## アーキテクチャ

```
                 ┌──────────────────────────────────────┐
                 │         VPC (10.0.0.0/16)             │
                 │                                        │
┌────────┐ SSH   │  ┌──────────────┐                     │
│ 運用者  │──────▶│  │    master    │                     │
└────────┘       │  │  EC2 t3.micro│                     │
                 │  │ /var/www/html│                     │
                 │  └──────┬───────┘                     │
                 │         │ lsyncd (rsync over SSH)      │
                 │    ┌────┴────┐                         │
                 │    ▼         ▼                         │
                 │ ┌────────┐ ┌────────┐                 │
                 │ │slave-1 │ │slave-2 │                 │
                 │ │ nginx  │ │ nginx  │                 │
                 │ └────────┘ └────────┘                 │
                 └──────────────────────────────────────┘
```

## 技術スタック

| レイヤー | 技術 |
|---|---|
| IaC | Terraform >= 1.7 |
| 構成管理 | Ansible + amazon.aws collection |
| 同期エンジン | lsyncd (inotify + rsync over SSH) |
| Web サーバー | nginx |
| CI/CD | GitHub Actions + OIDC（アクセスキー不使用） |
| インフラ | AWS EC2 t3.micro × 3, VPC, S3, DynamoDB |
| リージョン | ap-northeast-1 (東京) |

## ポートフォリオポイント

- **OIDC 認証**: GitHub Actions で AWS アクセスキーを使わない安全な CI/CD
- **Dynamic Inventory**: EC2 Tag で IP ハードコード排除
- **SSH 鍵2層設計**: 運用者用鍵と lsyncd 専用鍵を分離
- **ADR**: 技術選定の意思決定を文書化
- **日本語コメント**: 設計理由をコード内に明記

## クイックスタート

詳細は [運用手順書](docs/runbook/operations.md) を参照。

```bash
# 1. インフラ構築
cd terraform && terraform init && terraform apply

# 2. ミドルウェア設定
cd ../ansible && ansible-playbook playbooks/site.yml

# 3. 動作確認
bash ../scripts/verify.sh
```

## 月次コスト（概算）

t3.micro × 3台で **約 $32/月**。ハンズオン終了後は `terraform destroy` で削除。

## License

MIT
