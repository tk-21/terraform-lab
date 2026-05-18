# IaC比較マトリクス（iac-trilogy-lab実装比較）

> このファイルの客観的比較欄はClaude Codeが生成。主観評価欄はTakuya自身が記入すること。

---

## 客観的比較

| 比較軸 | Terraform | AWS CDK | Pulumi |
|---|---|---|---|
| 言語 | HCL | TypeScript / Python / Java等 | Python / TypeScript / Go等 |
| stateの保存場所 | S3（ローカルファイルも可） | CloudFormation（AWSマネージド） | Pulumi Cloud / S3 |
| stateのロック機構 | DynamoDB | CloudFormation組み込み | Pulumi Cloud組み込み |
| プロバイダー数 | 3,000+ | AWSのみ（公式） | 100+ |
| AWS対応の成熟度 | ★★★★★ | ★★★★★ | ★★★★ |
| 学習コスト（AWS知識前提） | 低（HCL習得のみ） | 中（CDK概念+TS必要） | 中（Pulumi概念+Python必要） |
| IMDSv2の設定方法 | `metadata_options`直接 | L1エスケープハッチ（`CfnInstance`） | `metadata_options`直接 |
| ループ処理 | `for_each` / `count` | `Array.map()` / for文 | Pythonのfor/内包表記 |
| モジュール化単位 | `module` | Construct（L1/L2/L3） | Python関数/クラス |
| drift検出コマンド | `terraform plan` | `cdk diff` | `pulumi preview` |
| リソース間参照 | `resource.attr`（静的） | `construct.attr`（TypeScript型） | `Output[T]`（非同期ラップ） |
| 既存リソースのimport | `terraform import` | `cdk import`（制限あり） | `pulumi import` |
| マルチクラウド対応 | ◎（プロバイダー次第） | △（AWS専用） | ◎（プロバイダー次第） |
| CI/CD連携の実績 | ★★★★★ | ★★★★ | ★★★ |
| コミュニティ規模 | 最大 | 大（AWS公式） | 中 |
| テスト容易性 | Terratest等（外部ツール） | `assertions`モジュール標準搭載 | `pytest`（Python標準） |

---

## 主観的評価（Takuya記入）

> **記入ガイド**: 実際に3実装を書いた感覚で評価する。
> ★1〜5、または短い文章で。「どちらでもない」は禁止——必ず差をつける。

| 比較軸 | Terraform | AWS CDK | Pulumi |
|---|---|---|---|
| 書いていて気持ちいい | [記入] | [記入] | [記入] |
| デバッグのしやすさ | [記入] | [記入] | [記入] |
| エラーメッセージの分かりやすさ | [記入] | [記入] | [記入] |
| 「インフラを設計している感」 | [記入] | [記入] | [記入] |
| 「プログラムを書いている感」 | [記入] | [記入] | [記入] |
| ドキュメントの充実度 | [記入] | [記入] | [記入] |
| IDEサポート・補完 | [記入] | [記入] | [記入] |
| また使いたいか | [記入] | [記入] | [記入] |

---

## リソース数比較（同一インフラ）

> **記入ガイド**: 各ツールの `state list` / CloudFormationコンソール等で確認して記入。
> CDKの「隠蔽リソース数」は `cdk.out/*.template.json` のResourcesセクションで確認できる。

| 実装 | 明示的リソース数（コード上） | 隠蔽リソース数 | 合計管理リソース数 |
|---|---|---|---|
| Terraform | [`terraform state list` で確認して記入] | 0（全て明示的） | [記入] |
| AWS CDK | [コード上のConstruct/Resource数を記入] | [`cdk.out/*.template.json` のResourcesで確認] | [CDKが生成したCFnリソース数を記入] |
| Pulumi | [`pulumi state export` で確認して記入] | 0（全て明示的） | [記入] |

---

## コードボリューム比較

> **記入ガイド**: `wc -l` 等で計測して記入。コメント行の扱いを統一すること。

| 実装 | コード行数（コメント除く） | ファイル数 | 備考 |
|---|---|---|---|
| Terraform | [記入] | [記入] | |
| AWS CDK | [記入] | [記入] | `node_modules`除く |
| Pulumi | [記入] | [記入] | `.venv`除く |

---

## コード実施状況

| 実装 | ステータス | apply完了日 | destroy完了日 |
|---|---|---|---|
| Terraform | [記入] | [記入] | [記入] |
| AWS CDK | [記入] | [記入] | [記入] |
| Pulumi | [記入] | [記入] | [記入] |

---

## 参照ADR

- [ADR-001: Terraform ベースライン](../adr/adr-001-terraform-baseline.md)
- [ADR-002: CDK vs Terraform](../adr/adr-002-cdk-vs-terraform.md)
- [ADR-003: Pulumi vs HCL](../adr/adr-003-pulumi-vs-hcl.md)
- [ADR-004: IaCツール選定ガイド（総括）](../adr/adr-004-iac-selection-guide.md)
