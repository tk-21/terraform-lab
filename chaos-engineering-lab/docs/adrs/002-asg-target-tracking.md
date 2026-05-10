# ADR-002: ASG スケーリングポリシーに Target Tracking (CPU 70%) を採用する

## ステータス

Accepted

## 日付

2026-05-11

## コンテキスト

Auto Scaling Group のスケーリングポリシーとして以下の候補を比較検討した:

| ポリシー種別 | 概要 |
|-------------|------|
| **Target Tracking** | 指定メトリクスを目標値に維持するよう AWS が自動計算 |
| **Simple Scaling** | アラーム発火 → 固定ステップでスケール、クールダウンあり |
| **Step Scaling** | アラーム閾値の超過幅によってスケールステップを変動 |
| **Scheduled Scaling** | 時刻ベースのスケール（夜間縮退など） |

### 前提条件

- カオスエンジニアリング実験で **CPU に直接ストレスを注入**（`stress-ng` by FIS）
- スケールアウト成功の検証がプロジェクトの主目的
- スケールイン（実験後の復元）も自動検証したい
- 実装・運用のシンプルさを優先

## 決定

**Target Tracking Scaling（目標 CPU 使用率: 70%）** を採用する。

```hcl
resource "aws_autoscaling_policy" "cpu_target_tracking" {
  name                   = "cel-dev-cpu-target-tracking"
  autoscaling_group_name = aws_autoscaling_group.main.name
  policy_type            = "TargetTrackingScaling"

  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }
    target_value = 70.0  # CPU 70% を維持目標とする
  }
}
```

## 理由

### 1. FIS 実験シナリオと直接対応

FIS は `stress-ng` で CPU 使用率を意図的に引き上げる。
CPU ベースの Target Tracking ポリシーを採用することで、
「CPU 上昇 → スケールアウト」という因果関係が明確に検証できる。

### 2. AWS が自動でスケール量を計算

Simple/Step Scaling は手動でスケールステップを設定する必要があるが、
Target Tracking は現在の CPU と目標値から AWS が必要インスタンス数を自動計算する。
実験結果に依存した調整が不要なため、ポートフォリオ実装として適切。

### 3. スケールイン（復元）も自動検証できる

FIS 実験終了後に CPU が低下すると、Target Tracking が自動でスケールインを実施。
「実験 → スケールアウト → 実験終了 → スケールイン」というフルサイクルを
追加設定なしで検証できる。

### 4. 設計意図の明示

CPU 70% という閾値は以下を考慮して設定:
- FIS 停止条件（CPU 90% が 10 分継続）より十分低い値
- スケールアウト余裕を確保しつつ、リソース過剰防止

## トレードオフ

| 項目 | 内容 |
|------|------|
| **複合シナリオへの非対応** | SQS キュー深度や HTTP レイテンシとの組み合わせポリシーは別途 Step Scaling が必要 |
| **スケールアウト速度の制御が難しい** | Simple/Step Scaling に比べてスケール速度の細かな調整が困難 |
| **スケジュールスケーリングとの優先順位** | Scheduled Scaling と組み合わせる場合、競合に注意が必要 |

## 将来の拡張

以下のシナリオでは別ポリシーの追加検討が必要:
- ネットワーク遅延注入 → レイテンシベースのメトリクス（Application Load Balancer TargetResponseTime）
- RDS フェイルオーバー検証 → ヘルスチェックベースの Schedule Scaling
- 大量リクエスト負荷テスト → SQS + Step Scaling

## 関連

- `terraform/modules/asg/` — ASG および Target Tracking ポリシーの実装
- `terraform/modules/fis/` — FIS 停止条件（CPU 90%）アラームの実装
- ADR-001: カオスエンジニアリングツールの選定
