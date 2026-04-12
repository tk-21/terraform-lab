# Sample Knowledge Index

このディレクトリは、Bedrock Knowledge Base に取り込む原本ドキュメントのサンプル置き場です。

読み方:

- 各 `.md` ファイルは「社内手順書 1 本」を想定しています
- `scripts/upload_knowledge.sh` で S3 に同期し、`scripts/kb_ingest.sh` で KB に再取り込みします
- KB モードでは、ここにある文章が検索対象になります

主なドキュメント一覧:

| ファイル | 主なテーマ | 想定される質問例 |
|---|---|---|
| `onboarding.md` | 入社初週のセットアップ全体像 | 「新入社員が最初にやることは？」 |
| `laptop_setup.md` | 社用 PC の初期設定 | 「新しい PC のセットアップ手順は？」 |
| `vpn_setup.md` | VPN 接続と切り分け | 「VPN 接続方法は？」 |
| `password_reset.md` | パスワード再設定 | 「パスワードを忘れたときは？」 |
| `aws_account_access.md` | AWS 利用申請と初回ログイン | 「AWS アカウント申請方法は？」 |
| `kubernetes_deployment_runbook.md` | Kubernetes デプロイ手順 | 「EKS に新しいイメージを反映する手順は？」 |
| `eks_ingress_troubleshooting.md` | Ingress / ALB 切り分け | 「Ingress の URL を開いても見えないときは？」 |
| `terraform_destroy_runbook.md` | Terraform destroy の後片付け | 「destroy で Subnet や VPC が消えないときは？」 |
| `bedrock_access_troubleshooting.md` | Bedrock モデル利用条件 | 「Bedrock モデルアクセスで失敗するときは？」 |
| `incident_contact.md` | 障害時の連絡順序 | 「インシデント時の連絡先は？」 |
| `security_basics.md` | 基本セキュリティルール | 「機密情報の扱いルールは？」 |
| `device_replacement.md` | 端末交換申請 | 「PC を交換したいときは？」 |
| `attendance_policy.md` | 勤怠ルール | 「遅刻時の連絡方法は？」 |
| `leave_policy.md` | 休暇申請 | 「有休はいつまでに申請する？」 |
| `expense_policy.md` | 経費精算 | 「領収書なしで精算できる？」 |
| `business_trip_policy.md` | 出張申請 | 「国内出張は何日前までに申請？」 |
| `meeting_room_guide.md` | 会議室利用 | 「会議室の予約ルールは？」 |
| `internal_faq.md` | よくある問い合わせ導線 | 「FAQ の入口はどこ？」 |

補足:

- `internal_faq.md` は他ドキュメントへの導線として機能します
- `onboarding.md` は複数の手順書をまたぐ案内役として機能します
- 技術系ランブックを増やすと、MVP モードでも KB モードでも検証質問の幅を広げやすくなります
- 実運用では 1 ファイル 1 テーマを意識すると、検索結果の根拠が分かりやすくなります
