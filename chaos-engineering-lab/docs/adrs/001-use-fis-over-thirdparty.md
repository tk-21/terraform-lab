# ADR-001: カオスエンジニアリングツールに AWS FIS を採用する

## ステータス

Accepted

## 日付

2026-05-11

## コンテキスト

カオスエンジニアリング基盤を構築するにあたり、障害注入ツールを選定する必要があった。
主要候補として以下の 3 ツールを比較検討した:

| ツール | 種別 | 特徴 |
|--------|------|------|
| **AWS FIS** | マネージド (AWS) | AWS ネイティブ、Terraform 対応、追加コストなし |
| **Chaos Monkey** | OSS (Netflix) | EC2 ランダム終了に特化、機能が限定的 |
| **Gremlin** | SaaS (有償) | 高機能・細かい制御が可能、月額 $9,000〜 |

### 検討項目

- **再現性**: 実験設定をコードで管理できるか（IaC 対応）
- **安全性**: 暴走を防ぐ停止条件を設定できるか
- **コスト**: ポートフォリオ用途として許容できるか
- **AWS 統合**: IAM・VPC・CloudWatch と連携できるか
- **即時利用性**: マネージドドキュメントで素早く実験を組めるか

## 決定

**AWS FIS (Fault Injection Simulator)** を採用する。

## 理由

### 1. Terraform による完全 IaC 化（ポートフォリオ訴求点）

`aws_fis_experiment_template` リソースにより、実験テンプレートをコードで管理できる。
実験シナリオがバージョン管理・再現可能になり、ポートフォリオとして技術力を示せる。

```hcl
resource "aws_fis_experiment_template" "cpu_stress" {
  description = "CPU ストレス実験: ASG スケールアウト検証"
  # 停止条件を Terraform で定義
  stop_condition {
    source = "aws:cloudwatch:alarm"
    value  = aws_cloudwatch_metric_alarm.fis_stop.arn
  }
}
```

### 2. AWS ネイティブ統合による設定の簡潔さ

- IAM ロール・VPC 設定が AWS 内で完結し、クロスアカウント認証が不要
- CloudWatch アラームを停止条件として直接指定可能
- SSM マネージドドキュメント `AWSFIS-Run-CPU-Stress` を即時利用可能

### 3. 多層安全弁が標準機能

- **停止条件**: `CPUUtilization > 90%` が 10 分継続したら自動停止
- **IAM 最小権限**: FIS 実行ロールに必要最小限の権限のみ付与
- **対象フィルタ**: 「ASG 内インスタンスの 50%」のような割合指定が可能

### 4. 追加コストなし

FIS 自体に料金はなく、EC2・SSM の使用コストのみで実験可能。
Gremlin（月額 $9,000〜）との比較でポートフォリオ用途に適している。

## トレードオフ

| 項目 | 内容 |
|------|------|
| **Gremlin と比べた制限** | ネットワーク遅延の細かな制御（パケットロス率・遅延分布など）は FIS では限定的 |
| **Chaos Monkey と比べた複雑さ** | FIS は設定項目が多く、初期学習コストがやや高い |
| **マルチクラウド非対応** | FIS は AWS 専用のため、GCP/Azure リソースへの障害注入は別ツールが必要 |

## 関連

- [AWS FIS ドキュメント](https://docs.aws.amazon.com/fis/)
- `terraform/modules/fis/` — FIS 実験テンプレートの実装
- ADR-002: ASG スケーリングポリシーの選定
