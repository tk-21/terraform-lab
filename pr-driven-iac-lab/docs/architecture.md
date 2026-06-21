# アーキテクチャ概要

## 図1: Atlantis フロー（Self-hosted on ECS Fargate）

```mermaid
sequenceDiagram
    participant Dev as 開発者
    participant GH as GitHub
    participant Atlantis as Atlantis<br>(ECS Fargate)
    participant AWS as AWS

    Dev->>GH: PR open (terraform変更)
    GH->>Atlantis: webhook送信
    Atlantis->>AWS: terraform plan 実行
    Atlantis->>GH: planコメント投稿
    Dev->>GH: atlantis apply コメント投稿
    GH->>Atlantis: webhook送信
    Atlantis->>AWS: terraform apply 実行
    Atlantis->>GH: apply結果コメント投稿
```

## 図2: Terraform Cloud フロー

```mermaid
sequenceDiagram
    participant Dev as 開発者
    participant GH as GitHub
    participant GHA as GitHub Actions
    participant TFC as Terraform Cloud
    participant AWS as AWS

    Dev->>GH: PR open (terraform変更)
    GH->>GHA: workflow trigger
    GHA->>TFC: plan run 作成
    TFC->>AWS: terraform plan 実行
    TFC->>GHA: plan結果返却
    GHA->>GH: planコメント投稿
    Dev->>GH: PR approve + merge
    GH->>GHA: workflow trigger (push to main)
    GHA->>Dev: GitHub Environment 承認要求
    Dev->>GHA: production 環境を承認
    GHA->>TFC: apply run 作成
    TFC->>AWS: terraform apply 実行
```

## コンポーネント説明

| コンポーネント | 役割 |
|---|---|
| GitHub | PRレビュー・承認・マージの起点 |
| Atlantis (ECS Fargate) | Self-hosted PR automation。webhookを受けてplan/applyを実行 |
| Terraform Cloud | SaaS型PR automation。State管理・UI・監査ログが付属 |
| S3 + DynamoDB | Terraformリモートステートの保存とロック |

---

## Atlantis vs Terraform Cloud 比較

> この表はTakuya本人が体験に基づいて記述すること。AIによる補完禁止。

| 観点 | Atlantis | Terraform Cloud |
|------|----------|-----------------|
| ホスティング | | |
| セットアップ難易度 | | |
| IAM権限管理 | | |
| State管理 | | |
| ワークフローのトリガー | | |
| apply の承認フロー | | |
| 監査ログ | | |
| コスト | | |
| カスタマイズ性 | | |
| チーム向け機能 | | |
| 学習コスト | | |
| 自社導入のしやすさ | | |
