# ✅Phase 4: 比較ADR作成 & 比較マトリクス

> **このフェーズの問い**:
> 「3つのツールを実際に触った上で、あなたは『どのケースでどれを選ぶか』を
>  自分の言葉で15分間説明できるか？」
>
> Phase 4はコードを書かない。**思考を書くフェーズ**。
> Claude Codeへの指示は「雛形を生成すること」のみ。
> **中身はTakuya自身が書くこと**（AI生成禁止）。

## 前提確認

- Phase 1〜3が全て完了していること
- 3実装でSSM接続・コスト監視が確認されていること
- このフェーズは **Claude Codeに内容を書かせない**（雛形のみ生成）

---

## タスク1: ADR雛形の生成（Claude Codeが実施）

以下の4つのADRファイルの**雛形のみ**を `adr/` に生成すること。
セクションタイトルと記入ガイドラインを含め、本文は `[Takuyaが記入]` とすること。

```
adr/
├── adr-001-terraform-baseline.md    # Phase 1完了後に書くもの（既に作成済みのはず）
├── adr-002-cdk-vs-terraform.md      # Phase 2完了後に書くもの（既に作成済みのはず）
├── adr-003-pulumi-vs-hcl.md         # Phase 3完了後に書くもの（既に作成済みのはず）
└── adr-004-iac-selection-guide.md   # Phase 4で書く総括ADR
```

### adr-004-iac-selection-guide.md の雛形

```markdown
# ADR-004: IaCツール選定ガイド（3実装比較総括）

**作成日**: YYYY-MM-DD
**ステータス**: Accepted
**作成者**: Takuya（iac-trilogy-lab Phase 4）

## コンテキスト

[Takuya記入: このADRを書くに至った背景。「とりあえずTerraform」という思考の偏りを
 3実装比較によって検証した経緯を書く]

## 比較した選択肢

- Terraform (HCL)
- AWS CDK (TypeScript)
- Pulumi (Python)

## 各ツールの実体験評価

### Terraform
**良かった点**: [Takuya記入]
**不便だった点**: [Takuya記入]
**「当たり前」に使っていて、実は根拠がなかったこと**: [Takuya記入]

### AWS CDK
**良かった点**: [Takuya記入]
**不便だった点（L1エスケープハッチ含む）**: [Takuya記入]
**TypeScriptの型安全性が役に立った/立たなかった場面**: [Takuya記入]

### Pulumi
**良かった点**: [Takuya記入]
**Output[T]型で戸惑った点と現在の理解**: [Takuya記入]
**Pythonであることのメリット・デメリット**: [Takuya記入]

## 決定: ツール選定フレームワーク

[Takuya記入: 「こういうケースではこのツールを選ぶ」という自分なりのガイドライン]

| ケース | 選択ツール | 理由 |
|---|---|---|
| チームがPython/TypeScriptに慣れている | | |
| Terraform既存資産がある | | |
| 型安全性を最優先したい | | |
| stateをAWS管理にしたい（CloudFormation） | | |
| OSS/コミュニティエコシステムを重視 | | |
| 個人・小規模プロジェクト | | |

## 「コスト設計ファースト」の実践評価

[Takuya記入: 3実装を通じて「コスト最適化を後回しにしない」設計を実践した感想。
 NAT Gatewayを禁止したことで制約になった場面はあったか？]

## 今後の自分への教訓

[Takuya記入: この比較実験を通じて発見した、自分の技術選定における思考の偏りと、
 今後それをどう修正するか]
```

---

## タスク2: 比較マトリクスの生成（Claude Codeが実施）

`docs/comparison-matrix.md` を生成すること。
**客観的な比較軸のみ**をClaude Codeが埋め、主観評価欄は `[Takuya記入]` とする。

```markdown
# IaC比較マトリクス（iac-trilogy-lab実装比較）

## 客観的比較

| 比較軸 | Terraform | AWS CDK | Pulumi |
|---|---|---|---|
| 言語 | HCL | TypeScript / Python / Java等 | Python / TypeScript / Go等 |
| stateの保存場所 | S3（ローカルファイルも可） | CloudFormation（AWSマネージド） | Pulumi Cloud / S3 |
| stateのロック機構 | DynamoDB | CloudFormation組み込み | Pulumi Cloud組み込み |
| プロバイダー数 | 3,000+ | AWSのみ（公式） | 100+ |
| AWS対応の成熟度 | ★★★★★ | ★★★★★ | ★★★★ |
| 学習コスト（AWS知識前提） | 低（HCL習得のみ） | 中（CDK概念+TS必要） | 中（Pulumi概念+Python必要） |
| IMDSv2の設定方法 | metadata_options直接 | L1エスケープハッチ | metadata_options直接 |
| ループ処理 | for_each / count | Array.map() | Pythonのfor/内包表記 |
| モジュール化単位 | module | Construct（L1/L2/L3） | Python関数/クラス |
| drift検出 | terraform plan | cdk diff | pulumi preview |
| CI/CD連携 | ★★★★★ | ★★★★ | ★★★ |
| コミュニティ | 最大 | 大（AWS公式） | 中 |

## 主観的評価（Takuya記入）

| 比較軸 | Terraform | AWS CDK | Pulumi |
|---|---|---|---|
| 書いていて気持ちいい | [記入] | [記入] | [記入] |
| デバッグのしやすさ | [記入] | [記入] | [記入] |
| エラーメッセージの分かりやすさ | [記入] | [記入] | [記入] |
| 「インフラを設計している感」 | [記入] | [記入] | [記入] |
| また使いたいか | [記入] | [記入] | [記入] |

## リソース数比較（同一インフラ）

| 実装 | 明示的リソース数 | 隠蔽リソース数 | 合計CloudFormationリソース数 |
|---|---|---|---|
| Terraform | [terraform state list で確認] | 0（全て明示的） | - |
| AWS CDK | [コード上のConstruct数] | [cdk.outで確認] | [CDKが生成したCFnリソース数] |
| Pulumi | [pulumi state export で確認] | 0（全て明示的） | - |

## コードステータス

| 実装 | ステータス | apply完了日 | destroy完了日 |
|---|---|---|---|
| Terraform | [記入] | [記入] | [記入] |
| AWS CDK | [記入] | [記入] | [記入] |
| Pulumi | [記入] | [記入] | [記入] |
```

---

## タスク3: GitHub / Zenn公開準備（Claude Codeが実施）

```
README.md を生成すること（プロジェクトルートに配置）。
```

### README.md の内容

```markdown
# iac-trilogy-lab

> 思考の偏りを破る IaC比較検証ラボ

同一AWSインフラを **Terraform / AWS CDK / Pulumi** の3ツールで実装し、
IaC設計哲学の差異を体感・言語化するハンズオン比較プロジェクト。

## 動機

「とりあえずTerraform」という思考の偏りを意識的に解体するため、
あえて慣れていないツールで同じインフラを構築し、設計判断の差異を記録した。

## 構成

[infra-spec.mdに定義した共通インフラの構成図をここに貼る]

## 実装フェーズ

| Phase | ツール | ドキュメント |
|---|---|---|
| 1 | Terraform | [terraform/README.md] |
| 2 | AWS CDK (TypeScript) | [cdk/README.md] |
| 3 | Pulumi (Python) | [pulumi/README.md] |
| 4 | 比較ADR | [adr/adr-004-iac-selection-guide.md] |

## コスト設計

全フェーズ合計: ~$3/月（t4g.nano × 3、NAT Gateway不使用）

## 学んだこと

[adr/adr-004-iac-selection-guide.md を参照]

## 参考

- [Terraform公式](https://developer.hashicorp.com/terraform)
- [AWS CDK公式](https://docs.aws.amazon.com/cdk/)
- [Pulumi公式](https://www.pulumi.com/docs/)
```

---

## Phase 4 完了の定義

- [ ] `adr/adr-004-iac-selection-guide.md` に**Takuya自身の言葉で**全セクション記入済み
- [ ] `docs/comparison-matrix.md` の主観評価欄が記入済み
- [ ] `README.md` が完成している
- [ ] **「なぜTerraformを選ぶか・選ばないか」を15分間口頭で説明できる**
- [ ] GitHubにpushしてZennの記事ドラフトを作成（任意）

---

## 全フェーズ完了後のクリーンアップ

```bash
# コスト発生を止めるため、全実装を順番にdestroy
cd terraform && terraform destroy
cd ../cdk && npx cdk destroy
cd ../pulumi && pulumi destroy

# stateバックエンドリソースも手動削除
# - S3: itl-tfstate-{account_id}
# - DynamoDB: itl-tfstate-lock
```