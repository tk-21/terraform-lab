# ✅Phase 4: 動作検証・ADR・ドキュメント整備

## このフェーズの目標

- Phase 1〜3 で構築した多層防御の **実際の動作を検証スクリプトで確認する**
- 各設計判断の根拠を **ADR（Architecture Decision Record）** として言語化する
- アーキテクチャ全体を図示した `architecture.md` を作成する
- GitHub 公開・Zenn 投稿に耐えるポートフォリオ品質に仕上げる

---

## 生成対象ファイル

### scripts/test_connectivity.sh

```bash
#!/bin/bash
# 疎通確認スクリプト
# 使用方法: ./scripts/test_connectivity.sh {EC2_INSTANCE_ID} {ALB_DNS}
#
# このスクリプトは SSM Send Command を使って EC2 から各種通信を試み、
# 期待通りに許可・拒否されることを確認する。

set -euo pipefail

INSTANCE_ID="${1:-}"
ALB_DNS="${2:-}"
REGION="ap-northeast-1"

if [[ -z "$INSTANCE_ID" ]]; then
  echo "Usage: $0 <instance-id> <alb-dns>"
  exit 1
fi

run_ssm() {
  local description="$1"
  local command="$2"
  local expect_success="${3:-true}"

  echo "=== TEST: $description ==="
  result=$(aws ssm send-command \
    --instance-id "$INSTANCE_ID" \
    --document-name "AWS-RunShellScript" \
    --parameters "commands=[\"$command\"]" \
    --region "$REGION" \
    --query "Command.CommandId" \
    --output text)

  sleep 5

  status=$(aws ssm get-command-invocation \
    --command-id "$result" \
    --instance-id "$INSTANCE_ID" \
    --region "$REGION" \
    --query "Status" \
    --output text)

  if [[ "$expect_success" == "true" && "$status" == "Success" ]]; then
    echo "✅ PASS: $description"
  elif [[ "$expect_success" == "false" && "$status" == "Failed" ]]; then
    echo "✅ PASS (expected failure): $description"
  else
    echo "❌ FAIL: $description (status: $status)"
  fi
}

echo "======================================"
echo "Network Security Lab - 疎通確認テスト"
echo "======================================"

# ---- Network Firewall ドメインフィルタリング ----
run_ssm "許可ドメイン: example.com (通るはず)" \
  "curl -s -o /dev/null -w '%{http_code}' https://example.com --max-time 10"

run_ssm "拒否ドメイン: evil-site.test (タイムアウトするはず)" \
  "curl -s -o /dev/null https://evil-site.test --max-time 10" \
  "false"

# ---- WAF 動作確認 ----
if [[ -n "$ALB_DNS" ]]; then
  run_ssm "正常リクエスト: ALB アクセス (200 OK のはず)" \
    "curl -s -o /dev/null -w '%{http_code}' http://${ALB_DNS}/ --max-time 10"

  run_ssm "WAF ブロック: sqlmap UA (403 のはず)" \
    "curl -s -o /dev/null -w '%{http_code}' -H 'User-Agent: sqlmap/1.0' http://${ALB_DNS}/ --max-time 10"

  run_ssm "WAF ブロック: SQLi クエリ (403 のはず)" \
    "curl -s -o /dev/null -w '%{http_code}' 'http://${ALB_DNS}/?id=1+UNION+SELECT+1,2,3--' --max-time 10"
fi

echo "======================================"
echo "テスト完了。CloudWatch Logs でブロックログを確認してください。"
echo "  NFW Alert: amf-nfw-alert"
echo "  WAF Log:   aws-waf-logs-amf-alb"
echo "======================================"
```

---

### scripts/attack_simulation.sh

```bash
#!/bin/bash
# 模擬攻撃スクリプト（WAF・Network Firewall のブロック動作確認用）
# 使用方法: ./scripts/attack_simulation.sh {ALB_DNS}
#
# ⚠️  自分が所有するリソースに対してのみ実行すること

set -euo pipefail

ALB_DNS="${1:-}"
if [[ -z "$ALB_DNS" ]]; then
  echo "Usage: $0 <alb-dns>"
  exit 1
fi

BASE_URL="http://${ALB_DNS}"

echo "=== SQL インジェクション試行 ==="
curl -s -o /dev/null -w "Status: %{http_code}\n" \
  "${BASE_URL}/?id=1' OR '1'='1"
curl -s -o /dev/null -w "Status: %{http_code}\n" \
  "${BASE_URL}/?q=SELECT+*+FROM+users"

echo "=== XSS 試行 ==="
curl -s -o /dev/null -w "Status: %{http_code}\n" \
  "${BASE_URL}/?name=<script>alert(1)</script>"

echo "=== ディレクトリトラバーサル試行 ==="
curl -s -o /dev/null -w "Status: %{http_code}\n" \
  "${BASE_URL}/../../../etc/passwd"

echo "=== スキャナー UA 試行 ==="
curl -s -o /dev/null -w "Status: %{http_code}\n" \
  -H "User-Agent: Nikto/2.1.6" "${BASE_URL}/"
curl -s -o /dev/null -w "Status: %{http_code}\n" \
  -H "User-Agent: sqlmap/1.7" "${BASE_URL}/"

echo ""
echo "全て 403 が返れば WAF が正常に動作しています。"
echo "CloudWatch Logs で詳細なブロック理由を確認してください。"
```

---

### docs/adr/001_nacl_vs_sg.md

```markdown
# ADR 001: NACL と Security Group の役割分担

## ステータス
承認済み

## コンテキスト
VPC 内のアクセス制御手段として NACL と Security Group の 2 つが存在する。
どちらも使えるが、それぞれ特性が異なるため適切に使い分ける必要がある。

## 決定
- **Security Group**: リソース（EC2/ALB）レベルの細粒度制御に使用
- **NACL**: サブネットレベルの粗粒度制御・明示的な拒否ルールに使用

## 根拠

### Security Group を主軸にする理由
1. **ステートフル**: 戻りトラフィックを自動許可するため、エフェメラルポートを気にしなくてよい
2. **SG 間参照**: インスタンスの役割（Web/App/DB）を参照で表現できる
3. **管理コスト低**: NACL のようにルール番号の管理が不要

### NACL を補完的に使う理由
1. **明示的な拒否**: NACL は DENY ルールを書ける（SG は DENY が書けない）
2. **サブネット境界の制御**: SG がついていないリソース（ALB など）も保護
3. **多層防御**: SG の設定ミスを NACL でカバーできる

## トレードオフ
- NACL はステートレスのためエフェメラルポート（1024-65535）の明示的許可が必要
- ルール数が多くなると管理が煩雑になる（最大 40 ルール/NACL）
```

---

### docs/adr/002_network_firewall_placement.md

```markdown
# ADR 002: Network Firewall の配置場所と AZ 数

## ステータス
承認済み

## コンテキスト
AWS Network Firewall を VPC に導入する際、
配置する AZ 数（1AZ vs 全AZ）とルートテーブルのパターンを決定する必要がある。

## 決定
- **ハンズオン環境**: 1AZ（ap-northeast-1a）のみ Firewall Subnet を使用
- **本番環境**: 全稼働 AZ に Firewall Endpoint を配置する

## 根拠

### Firewall Subnet を専用サブネット（/28）にする理由
Firewall Endpoint は AWS が管理する ENI（Elastic Network Interface）を
各 AZ に 1 つ配置する。そのため /28（16 IP）で十分。
他のリソードと混在させると管理が複雑になるため専用サブネットを切る。

### ハンズオンで 1AZ にする理由
- Firewall Endpoint のコスト: 約 $0.395/時間/AZ
- 2AZ で稼働させると月額 $570 超になりハンズオン目的に見合わない
- 学習目的では動作確認ができれば十分

### 本番で全 AZ が必要な理由
Firewall Endpoint は AZ をまたいだルーティングができない。
1AZ に集約すると、そのAZが障害になった際に全トラフィックが断絶する。

## トレードオフ
| | ハンズオン（1AZ） | 本番（全AZ） |
|---|---|---|
| コスト | 低 | 高 |
| 可用性 | 低 | 高 |
| 学習効果 | 十分 | - |
```

---

### docs/adr/003_waf_rule_strategy.md

```markdown
# ADR 003: WAF ルールの優先度戦略と COUNT モードの活用

## ステータス
承認済み

## コンテキスト
WAF の設計では「何をブロックするか」だけでなく「ルールの優先順位と
運用ステージの切り替え方」を設計する必要がある。

## 決定
優先度の設計:
1. (10) ブロック IP セット — 既知の悪意ある IP を最初に弾く
2. (20) AWS マネージドルール CRS — 一般的な攻撃を幅広くカバー
3. (30) Known Bad Inputs — 既知の悪意あるペイロード
4. (40) レートベース — DDoS 的なアクセスを制限
5. (50) カスタム UA ブロック — スキャナーツールを排除

マネージドルール導入時は一時的に COUNT モードで運用する。

## 根拠

### IP セットを最優先にする理由
既知の悪意ある IP からのリクエストは詳細分析不要。最初に弾くことで
後続のルール評価コスト（WCU）を節約できる。

### COUNT モードを使う理由
マネージドルールを BLOCK で直接有効化すると、正規ユーザーを
誤ってブロックするリスクがある（誤検知）。
COUNT で一定期間観察し、誤検知がないことを確認してから BLOCK に切り替える。

### レートベースルールの閾値（2000/5分）の根拠
正常なユーザーが 5 分間に 2000 リクエスト（=6.7 req/秒）を送ることは
通常ありえない。この閾値を超えるのはスクレイピングか DDoS と判断できる。

## トレードオフ
- マネージドルールは WCU を消費する（1 WebACL あたり 1500 WCU まで無料）
- ルールが多いほど評価コストが上がりレイテンシに影響する
```

---

### docs/architecture.md

以下の内容で `architecture.md` を作成する:

```markdown
# アーキテクチャ概要: aws-multilayer-firewall-terraform

## 多層防御の全体像

```
Internet
   │
   ▼
[Internet Gateway]
   │
   ▼ (IGW Route Table → Firewall Endpoint)
[AWS Network Firewall Endpoint]   ← L3/L4/L7 フィルタリング
   │ ドメインフィルタリング
   │ IPS ルール（SQLi/XSS/スキャナー）
   │
   ▼ (Firewall Subnet → IGW へ)
[Public Subnet]
   │
   ▼
[ALB]
   │ ← WAF WebACL アタッチ
   │ SQLi/XSS/レートベース/Bot 対策
   │
   ▼ (Security Group: amf-sg-web)
[EC2 in Private Subnet]
   │
   ▼ (Security Group: amf-sg-ssm)
[SSM Session Manager] ← SSH 不要
```

## セキュリティコントロールの比較

| コントロール | レイヤー | ステート | スコープ | 主な用途 |
|---|---|---|---|---|
| NACL | L3/L4 | ステートレス | サブネット | 明示的拒否・サブネット境界 |
| Security Group | L3/L4 | ステートフル | インスタンス | 役割ベースのアクセス制御 |
| Network Firewall | L3-L7 | ステートフル | VPC 全体 | ドメイン・IPS・集中制御 |
| WAF | L7 | ステートフル | ALB/CF | SQL/XSS/Bot・アプリ直前 |
```

---

### docs/runbook.md

以下を含む運用手順書を作成する:

1. **環境の起動・停止手順**（コスト節約のため使わないときは destroy）
2. **Session Manager アクセス手順**
3. **WAF ルールの追加手順**（新しいブロック IP の追加方法）
4. **CloudWatch Logs でブロックログを確認する手順**
5. **Network Firewall のドメイン許可リスト更新手順**
6. **月次コスト確認手順**（Cost Explorer のフィルタ設定）

---

### README.md

以下の構成で README を作成する:

```markdown
# aws-multilayer-firewall-terraform

## 概要
AWS のネットワークセキュリティ機能（NACL / Security Group / 
AWS Network Firewall / WAF）を Terraform で段階的に構築し、
実際の通信制御・ブロック動作を確認するハンズオン。

## アーキテクチャ
（architecture.md の図を転記）

## 学べること
- NACL vs Security Group の使い分け（ステートフル vs ステートレス）
- AWS Network Firewall によるドメインフィルタリングと IPS
- WAF によるアプリケーション層の多層防御
- 多層防御の設計パターンと各レイヤーの役割分担

## 構成
（ディレクトリ構造）

## 実行手順
（terraform init / plan / apply の手順）

## コスト目安
- Network Firewall: ~$0.40/時間（ハンズオン後は destroy 推奨）
- ALB: ~$0.008/時間
- EC2 t4g.nano: ~$0.006/時間
- **合計目安**: ~$10〜15/月（常時稼働時）

## 設計判断
- [ADR 001: NACL vs SG](docs/adr/001_nacl_vs_sg.md)
- [ADR 002: Network Firewall 配置](docs/adr/002_network_firewall_placement.md)
- [ADR 003: WAF ルール戦略](docs/adr/003_waf_rule_strategy.md)
```

---

## フェーズ完了の定義

- [ ] `scripts/test_connectivity.sh` が全テストを PASS する
- [ ] `scripts/attack_simulation.sh` の全リクエストが 403 で返る
- [ ] 3 本の ADR が自分の言葉で書かれている（AI 生成のコピーではない）
- [ ] `architecture.md` のアーキテクチャ図が正確である
- [ ] `README.md` が GitHub に公開できる品質である
- [ ] `terraform destroy` で全リソースが削除できる（コスト確認）

---

## 最終学習確認（プロジェクト全体の振り返り）

以下を **15分間、声に出して説明できるか** を確認すること:

**Q1**: インターネットからのリクエストが EC2 に到達するまでの
全セキュリティチェックポイントを順番に説明せよ。
（IGW → NFW → ALB/WAF → SG → NACL → EC2）

**Q2**: SQL インジェクション攻撃を `?id=1 UNION SELECT` で試みた場合、
どのセキュリティレイヤーがどの順番でブロックするか？
（Network Firewall の IPS ルール vs WAF の CRS マネージドルール）

**Q3**: 新しいボット IP（1.2.3.4）をブロックする最速の方法は何か？
WAF IP セット vs Network Firewall vs NACL、それぞれのメリット・デメリットを説明せよ。

**Q4**: このアーキテクチャを本番環境にするために最低限追加すべき要素は何か？
（Multi-AZ NFW、Shield Standard/Advanced、CloudFront など）