# ADR-002: CDK vs Terraform — Phase 2 実装を通じた比較考察

**Date**: 2026-05-18
**Status**: Active
**Author**: takuya

---

## コンテキスト

iac-trilogy-lab Phase 2 として、Phase 1（Terraform）で実装した同一インフラを AWS CDK (TypeScript) で再実装した。
同一仕様（infra-spec.md）を異なるIaCツールで書く体験を通じて、設計哲学の差異を言語化する。

---

## CDK L2 Constructが便利だったこと・不便だったこと

### 便利だったこと

**1. VPC周辺リソースの自動生成**
`ec2.Vpc` 1つで、Terraformで6ファイルに分散していたリソース（VPC/Subnet/IGW/RouteTable/RouteTableAssociation）を内包生成できた。
コード量は明らかに少ない。

**2. TypeScriptの型補完**
CloudWatch Alarmの `comparisonOperator` や `treatMissingData` の値を
`cloudwatch.ComparisonOperator.GREATER_THAN_THRESHOLD` のように列挙型で指定できる。
Terraformでは文字列 `"GreaterThanThreshold"` を直接書くため、タイポがバリデーション前まで検出されない。

**3. Constructへの依存関係の自動解決**
`compute.instance.instanceId` を CloudWatch Alarm の `dimensionsMap` に渡せば、
CDKがCloudFormationの `{ "Ref": ... }` に変換してくれる。
Terraformの `aws_instance.app.id` と同様の参照だが、型安全に書ける点が異なる。

**4. タグの伝播**
`cdk.Tags.of(this).add(key, value)` をスタックのルートで呼べば、全子Constructに伝播する。
Terraformの `default_tags` に相当するが、Construct単位で上書きも可能でより柔軟。

### 不便だったこと

**1. Subnet CIDRを直接指定できない**
infra-spec.md が要求する `10.10.1.0/24` を指定するために、
`10.10.0.0/24` をダミーの `reserved` サブネットとして宣言してCDKの自動CIDR割り当てをずらす必要があった。
Terraformでは `cidr_block = "10.10.1.0/24"` と直接書けるため、この問題は存在しない。

```typescript
// CDK: ダミーのreservedサブネットで10.10.0.0/24をスキップ（直感に反する）
{ name: 'reserved', subnetType: PRIVATE_ISOLATED, cidrMask: 24, reserved: true },
{ name: 'itl-dev-public', subnetType: PUBLIC, cidrMask: 24 },
// → 結果として 10.10.1.0/24 が割り当てられる
```

**2. VPC内部の詳細が不透明**
`ec2.Vpc` が生成する23リソース（`npx cdk synth | grep -c "Type: AWS::"` で確認）のうち、
ルートテーブルやIGWアタッチメントは `cdk.out/` のCFnテンプレートを見るまで把握できない。
Terraformでは全リソースが明示的にコードに現れるため、学習目的では透明性が高い。

---

## L1エスケープハッチが必要になった理由と感想

### IMDSv2強制設定

`ec2.Instance` L2 ConstructはIMDSv2（`MetadataOptions`）の設定プロパティを持たない（CDK v2.254時点）。
そのためL1（CloudFormationリソース相当の`CfnInstance`）に直接プロパティを注入した。

```typescript
// L1エスケープハッチ: L2が抽象化しきれない設定をCloudFormationレベルで直接注入
const cfnInstance = this.instance.node.defaultChild as ec2.CfnInstance;
cfnInstance.addPropertyOverride('MetadataOptions.HttpTokens', 'required');
```

**感想**: Terraformでは `metadata_options { http_tokens = "required" }` と1行で書ける設定が、
CDKでは「L2の型体系を抜け出してCFnのプロパティ名を把握する」という追加知識を要求した。
L1エスケープハッチはCDKの「抽象化の限界」を体験する良い機会だったが、
実務では「L2でカバーされていない設定」を都度把握するコストが発生することを意識した。

### AWS Budgets の L2 非対応

`budgets.CfnBudget`（L1）を使用。L2が存在しないAWSサービスはこのケースに相当し、
CloudFormationのプロパティ仕様（`notificationsWithSubscribers` 等）を直接書く必要がある。
Terraformの `aws_budgets_budget` よりも冗長だが、型補完があるため記述ミスは減る。

---

## 型安全性がインフラ設計にもたらした価値（またはノイズ）

### 価値

- **列挙型によるタイポ防止**: `ec2.SubnetType.PUBLIC`, `cloudwatch.TreatMissingData.NOT_BREACHING` など
  文字列ではなく型で指定できるため、コンパイル時に誤りを検出できる
- **IDEの補完**: VS Code上でConstructのプロパティを補完できるため、ドキュメントを見なくても書き進められる
- **Props型定義による契約**: `ComputeProps` のような型を定義することで、
  Constructの「使い方の仕様」がコードとして表現される（Terraformの `variables.tf` と同等だがコンパイルが通る）

### ノイズ

- `as ec2.CfnInstance` のようなキャストが出てくると型安全性が局所的に崩れる感覚がある
- CDKの `any` 型を使わないルールを徹底するために、L1プロパティの型定義を調べる手間が発生した

---

## 生成リソース数の比較

| 実装 | 明示的なリソース宣言数 | CloudFormation物理リソース数 |
|---|---|---|
| Terraform | 約15リソース | 15リソース（宣言＝実体） |
| CDK | 約5 Construct + L1×2 | 23リソース（`cdk synth`で確認） |

CDKの「コード行数は少ない」が「何が作られるかは多い」という逆転現象が発生した。
これは検証ラボでは許容範囲だが、本番環境でのコスト見積もりや監査では注意が必要。

---

## 結論: どのケースでどれを選ぶか

| ケース | 選択 | 理由 |
|---|---|---|
| チームに非エンジニアが含まれる | Terraform | HCLの可読性・宣言的な透明性 |
| TypeScript開発チームがインフラも書く | CDK | 同一言語での統一・型安全性 |
| 既存CloudFormationからの移行 | CDK | CFnとの相互変換が可能 |
| リソース数・コストを厳密に把握したい | Terraform | 宣言＝実体の透明性 |
| インフラ設計の学習目的 | Terraform | 概念が1対1でマッピングされる |
| Lambda/ECS等の複合構成を素早く組む | CDK | L2ConstructのDX優位性 |
