# ✅Phase 4: 比較レポート生成

## 目標

3クラウドの構築体験を元に、「なぜ差異が生まれたのか」を言語化する。
このフェーズで作るドキュメントは **面接での回答素材** になる。

---

## 作成するファイル

### `comparison/network-concepts.md`

```markdown
# ネットワーク概念比較

| 概念 | AWS | GCP | Azure | 差異のポイント |
|------|-----|-----|-------|---------------|
| VPCのスコープ | リージョン単位 | グローバル（全リージョン） | リージョン単位 | GCPは1VPCで全拠点をカバーできる |
| サブネットのスコープ | AZ単位 | リージョン単位 | リージョン単位 | AWSだけAZ単位で細分化が必要 |
| インターネット接続 | IGW（明示的なリソース）| デフォルトルートで自動 | IGW相当が内包 | AWSが一番「明示的」 |
| ファイアウォールのアタッチ方法 | SG → ENI、NACL → Subnet | ネットワークタグ or SA | NSG → Subnet or NIC | GCPはタグベースが独特 |
| ファイアウォールのステートフル性 | ステートフル（SG）、ステートレス（NACL） | ステートフル | ステートフル | NACLがある分AWSが柔軟 |
| LBの構成 | ALBで完結（シンプル） | 複数リソースの連鎖 | L4/L7が別サービス | AWSが最もシンプル |

## 所感（自分の言葉で書くこと）

<!-- 以下のセクションはAI生成禁止。自分の構築体験から感じたことを書く -->

### AWSのネットワーク設計で「当たり前」と思っていたが実は独特だったこと

（ここに記述）

### GCPのグローバルVPCが実務で有利になるシナリオ

（ここに記述）

### Azureのリソースグループという概念を知って変わった設計の見方

（ここに記述）
```

---

### `comparison/iam-concepts.md`

```markdown
# IAM概念比較

| 概念 | AWS | GCP | Azure |
|------|-----|-----|-------|
| 権限の単位 | Policy（JSON）| Role（YAML/JSON）| Role Definition |
| アタッチ対象 | User/Group/Role | Service Account / Group | Service Principal / Managed Identity |
| リソースへの付与 | IAM Role → EC2 Instance Profile | Service Account → VM | Managed Identity → VM |
| スコープ | Account / Resource ARN | Project / Folder / Org | Subscription / RG / Resource |
| 最小権限の実現 | Inline Policy or 細かいManaged Policy | Predefined Role or Custom Role | Built-in Role or Custom Role |

## IAMの設計思想の違い

### AWSのIAM
- リソースベースポリシー（バケットポリシー等）とアイデンティティベースポリシーの2軸
- ARNで全リソースをアドレス可能なため、クロスアカウント制御が強力

### GCPのIAM
- 「誰が」「何に」「何を」の3要素がシンプル
- リソース階層（Org > Folder > Project > Resource）での継承が直感的

### AzureのIAM
- RBACとAzure AD（Entra ID）の連携が複雑だがEnterpriseでは強力
- Managed Identityで「アプリ自体に権限を持たせる」思想がAWSのInstance Profileに近い

## 所感（自分の言葉で書くこと）

<!-- AI生成禁止 -->

### 3クラウドを比較して「AWSのIAMのここが使いやすい / 使いにくい」と感じたこと

（ここに記述）
```

---

### `comparison/cost.md`

```markdown
# コスト比較

## 今回の構成（同一ワークロード）での推定月額コスト

| 項目 | AWS | GCP | Azure |
|------|-----|-----|-------|
| Compute | t4g.nano Spot (arm64) ~$1 | e2-micro Preemptible ~$0（無料枠） | B1s Spot (arm64) ~$3 |
| LB | ALB ~$16 | Global LB ~$18 | Standard LB ~$18 |
| データ転送 | ~$0.01 | ~$0.01 | ~$0.01 |
| **合計（概算）** | **~$17** | **~$18** | **~$21** |

> ※ 少量トラフィック前提。GCPはe2-microの無料枠（月730時間）が使える場合0円。

## コスト削減の設計判断

| 削減ポイント | AWS | GCP | Azure |
|------------|-----|-----|-------|
| NAT Gateway回避 | パブリックサブネット配置 | Cloud NAT不使用 | パブリックサブネット配置 |
| コンピュートコスト | Spot + arm64 | Preemptible + 無料枠 | Spot + arm64 |
| ストレージ | gp3最小 | Standard PD | Standard LRS |

## 所感（自分の言葉で書くこと）

<!-- AI生成禁止 -->

### 3クラウドを触って「コスト設計で考え方が変わった」こと

（ここに記述）
```

---

### `comparison/operations.md`

```markdown
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
```

---

## 実行手順

```bash
# 比較ディレクトリの作成
mkdir -p comparison

# 上記ファイルをそれぞれ作成した後、所感セクションを自分で記述する
# （所感セクションはAI生成禁止 — 構築体験から感じたことを書くこと）

# 作成確認
ls -la comparison/
```

---

## 完了チェックリスト

- [ ] 4ファイルがすべて `comparison/` に存在する
- [ ] 各ファイルの「所感」セクションが自分の言葉で埋まっている
- [ ] AIに書かせたコピペが混入していない（自己申告）

---

## 口頭説明チェックポイント（phase4完了後に必ず実施）

「3クラウドを同じワークロードで構築してみてわかったこと」を5分間、
**スライドなし・メモなし**で話せるか確認する。

話す内容の構成例：
1. 最も驚いた概念の差異（1分）
2. コスト観点で判断が変わったこと（1分）
3. 運用観点での各クラウドの特徴（2分）
4. 「それでもAWSを選ぶ理由」または「GCP/Azureが有利なシナリオ」（1分）