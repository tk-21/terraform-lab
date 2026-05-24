# 運用比較

## デプロイ・更新方法

| 操作 | AWS | GCP | Azure |
|------|-----|-----|-------|
| インスタンス更新 | Launch Template新バージョン → ASGローリング | Instance Templateを新規作成 → MIG更新 | VMSS model更新 → rolling upgrade |
| LB設定変更 | ALBリスナー/ルール更新 | URL Map更新 | LB Rule更新 |
| ログ確認 | CloudWatch Logs | Cloud Logging | Azure Monitor Logs |
| SSHアクセス | Session Manager | IAP Tunnel | Azure Bastion |

## 障害対応の観点

| 観点 | AWS | GCP | Azure |
|------|-----|-----|-------|
| インスタンス自動回復 | ASG Auto Healing | MIG Auto Healing | VMSS Auto Repair |
| AZ/Zone障害時 | ASGがAZ間で再均衡 | MIGがゾーン間で自動分散 | VMSS Availability Zones |
| メトリクス標準 | CloudWatch（粒度1分） | Cloud Monitoring（粒度1分） | Azure Monitor（粒度1分） |

## 所感（自分の言葉で書くこと）

<!-- AI生成禁止 -->

### 「本番でこのクラウドを選ぶなら運用上これが課題になる」と感じたこと（クラウドごとに記述）

**AWS:**
（ここに記述）

**GCP:**
（ここに記述）

**Azure:**
（ここに記述）
