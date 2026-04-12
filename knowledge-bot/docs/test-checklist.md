# Test Checklist

このドキュメントは、Knowledge Bot の動作確認で使う質問例を `MVP` モード用と `KB` モード用に分けてまとめたチェックリストです。

## 事前確認

- ローカル UI: `http://localhost:8000/`
- API Docs: `http://localhost:8000/docs`
- API エンドポイント: `POST /ask`

確認したい観点:

- 回答が返るか
- 根拠や引用が返るか
- ナレッジにない質問で推測しないか
- MVP と KB で検索の振る舞いが変わるか

## MVP モード用

前提:

- `RAG_MODE=MVP`
- `docs/sample_knowledge/*.md` をローカル読み込みして検索する
- KB のようなベクトル検索ではなく、ローカル文書に対する簡易検索として動作する

おすすめ質問:

| 質問 | 期待する見え方 |
|---|---|
| `EKS に新しいイメージを反映する手順は？` | `kubernetes_deployment_runbook.md` に寄った回答になる |
| `Ingress の URL を開いても表示されないときは？` | `eks_ingress_troubleshooting.md` に寄った回答になる |
| `terraform destroy で VPC が消えないときは？` | `terraform_destroy_runbook.md` に寄った回答になる |
| `Bedrock モデルアクセスで失敗するときは？` | `bedrock_access_troubleshooting.md` に寄った回答になる |
| `VPNについて教えて` | `vpn_setup.md` に寄った回答になる |
| `EKS のデプロイ手順と VPN ルールを教えて` | 技術系文書と手続き系文書が混ざる可能性がある |
| `パスワードリセット方法は？` | `password_reset.md` に寄った回答になる |

MVP モードで特に見たい点:

- ローカル文書に対する簡易検索なので、KB モードより言い換えには弱い
- `Ingress`、`destroy`、`VPN` など、文書本文に含まれる語だと拾いやすい
- 同じ `docs/sample_knowledge/` を参照しても、KB モードより検索品質は単純

## KB モード用

前提:

- `RAG_MODE=KB`
- `KNOWLEDGE_BASE_ID` が設定済み
- `docs/sample_knowledge/` を S3 同期し、ingestion 済み

### 基本確認

| 質問 | 主に当たってほしい文書 | 期待する見え方 |
|---|---|---|
| `VPNの接続方法を教えて` | `vpn_setup.md` | 接続手順と接続確認が返る |
| `パスワードを忘れたときの対応手順は？` | `password_reset.md` | セルフリセット手順が返る |
| `新しいPCのセットアップ手順を教えて` | `laptop_setup.md` | 初期設定や必須アプリ導入が返る |
| `AWSアカウントの申請方法は？` | `aws_account_access.md` | 申請フローとロール選択目安が返る |
| `EKS に新しいイメージを反映する手順は？` | `kubernetes_deployment_runbook.md` | build/push と deploy の流れが返る |
| `Ingress の URL を開いても表示されないときは？` | `eks_ingress_troubleshooting.md` | internal ALB と port-forward の説明が返る |
| `terraform destroy で VPC が消えないときは？` | `terraform_destroy_runbook.md` | ENI / Security Group の確認手順が返る |
| `Bedrock モデルアクセスで失敗するときは？` | `bedrock_access_troubleshooting.md` | Active / Legacy / inference profile / Marketplace 権限が返る |
| `インシデント発生時の連絡順序は？` | `incident_contact.md` | 連絡優先順位が返る |
| `国内出張は何営業日前までに申請が必要？` | `business_trip_policy.md` | 国内出張の申請期限が返る |
| `休暇申請はいつまでに出せばいい？` | `leave_policy.md` | 計画休暇と当日休暇の期限が返る |
| `経費精算の申請期限は？` | `expense_policy.md` | 支出日から30日以内が返る |

### 言い換え確認

KB は意味検索なので、表現を少し変えても拾えるかを見ます。

| 質問 | 主に当たってほしい文書 | 期待する見え方 |
|---|---|---|
| `VPNをつなぐ手順を知りたい` | `vpn_setup.md` | `VPNの接続方法` とほぼ同じ趣旨で答えられる |
| `新入社員が最初の1週間でやるITセットアップは？` | `onboarding.md` | Day 1-5 の流れが返る |
| `PC交換後に何を設定する？` | `device_replacement.md`, `laptop_setup.md` | 交換後セットアップへの導線が返る |
| `AWSに初回ログインするときの確認事項は？` | `aws_account_access.md` | SSO や `aws sts get-caller-identity` が返る |
| `障害が起きたとき最初の5分でやることは？` | `incident_contact.md` | 初動の5分のチェック項目が返る |
| `EKS で変更を確実に反映するには？` | `kubernetes_deployment_runbook.md` | ユニークタグと rollout 確認が返る |
| `internal ALB だと利用者はどうやってアクセスする？` | `eks_ingress_troubleshooting.md` | VPN や社内 DNS 前提の説明が返る |
| `Claude Sonnet 4 で on-demand エラーが出るのはなぜ？` | `bedrock_access_troubleshooting.md` | inference profile 利用が返る |

### FAQ 導線確認

| 質問 | 主に当たってほしい文書 | 期待する見え方 |
|---|---|---|
| `VPNに接続できません` | `internal_faq.md`, `vpn_setup.md` | FAQ と具体手順の両方が見える |
| `新しいPCに交換したいです` | `internal_faq.md`, `device_replacement.md` | FAQ から申請手順に導かれる |
| `パスワードを忘れました` | `internal_faq.md`, `password_reset.md` | FAQ からセルフリセットへ導かれる |
| `terraform destroy で subnet が消えません` | `terraform_destroy_runbook.md`, `internal_faq.md` | 原因切り分けと確認手順に導かれる |

### ナレッジ外確認

以下は、分からないと安全に返せるかを見るための質問です。

| 質問 | 期待する見え方 |
|---|---|
| `2026年の夏季休暇期間はいつ？` | ナレッジ不足として扱う |
| `営業部の部長は誰？` | ナレッジ不足として扱う |
| `大阪オフィスのWi-Fiパスワードは？` | 推測せず回答拒否またはナレッジ不足になる |
| `今月の出張費予算残高はいくら？` | 文書に無いので答えない |

## API での実行例

```bash
curl -X POST http://localhost:8000/ask \
  -H 'Content-Type: application/json' \
  -d '{"question":"VPNの接続方法を教えて"}'
```

## 合格の目安

- KB モードで、基本確認の質問に対して対応する文書の内容が大筋で返る
- 回答末尾に根拠や引用が付く
- FAQ 系では関連文書へ自然につながる
- ナレッジ外質問では断定や推測をしない
- MVP モードではローカル文書の範囲だけで回答が組み立てられる

## 関連ファイル

- `app/src/main.py`
- `app/src/rag_mvp.py`
- `app/src/rag_kb.py`
- `docs/sample_knowledge/README.md`
- `scripts/upload_knowledge.sh`
- `scripts/kb_ingest.sh`
