# ✅Phase 2: AWS CDK (TypeScript) 実装

> **このフェーズの問い**:
> 「TypeScriptの型システムがインフラ設計に何をもたらすか？
>  TerraformのモジュールとCDKのConstructは何が同じで何が違うか？」

## 前提確認

- Phase 1（Terraform）が完了していること
- `cdk/` ディレクトリで作業すること
- CDKバージョン: aws-cdk-lib >= 2.100.0
- Node.js: >= 18.x
- TypeScript: >= 5.x
- infra-spec.mdの仕様をTerraform実装と同一にすること

---

## セットアップ手順（Claude Codeが実施）

```bash
mkdir -p cdk && cd cdk

# CDKプロジェクト初期化
npx cdk init app --language typescript

# 依存パッケージ追加
npm install aws-cdk-lib constructs
npm install --save-dev @types/node typescript ts-node

# CDKバージョン確認
npx cdk --version
```

---

## タスク

`cdk/lib/` に以下のファイル構造でCDKコードを生成すること。

```
cdk/
├── bin/
│   └── itl-app.ts            # CDKアプリエントリーポイント
├── lib/
│   ├── itl-dev-stack.ts      # メインスタック
│   ├── constructs/
│   │   ├── network.ts        # VPC / Subnet / IGW（L2 Constructラッパー）
│   │   ├── compute.ts        # EC2 / IAM（L2 Constructラッパー）
│   │   ├── storage.ts        # S3（L2 Constructラッパー）
│   │   └── monitoring.ts     # Budgets / CloudWatch / SNS
├── cdk.json
├── tsconfig.json
└── package.json
```

---

## 実装要件

### bin/itl-app.ts

```typescript
#!/usr/bin/env node
import 'source-map-support/register';
import * as cdk from 'aws-cdk-lib';
import { ItlDevStack } from '../lib/itl-dev-stack';

const app = new cdk.App();

new ItlDevStack(app, 'ItlDevStack', {
  env: {
    account: process.env.CDK_DEFAULT_ACCOUNT,
    region: 'ap-northeast-1',
  },
  // CDKではenvをコード上で明示することで、Terraformのprovider設定に相当する役割を果たす
});
```

### メインスタック（itl-dev-stack.ts）の要件

```typescript
// Props定義（TypeScriptの型安全性を活かす）
interface ItlDevStackProps extends cdk.StackProps {
  notificationEmail?: string;
}

// 共通タグはcdk.Tags.of(this)で付与
// ManagedBy: "cdk" に設定（Terraform実装との差別化）
```

### Constructsの設計方針

**network.ts**: `ec2.Vpc` L2 Constructを使用
```typescript
// ⚠️ 重要な学習ポイント:
// CDKのec2.Vpcは「1行で書ける」が、内部でSubnet/IGW/RouteTableを自動生成する。
// これはTerraformで明示的に書いた5〜6リソースが隠蔽されることを意味する。
// 「便利さ」と「透明性」のトレードオフをコメントで説明すること。

const vpc = new ec2.Vpc(this, 'ItlDevVpc', {
  ipAddresses: ec2.IpAddresses.cidr('10.10.0.0/16'),
  maxAzs: 1,
  natGateways: 0,  // NAT Gateway禁止（コスト設計ファースト）
  subnetConfiguration: [
    {
      name: 'itl-dev-public',
      subnetType: ec2.SubnetType.PUBLIC,
      cidrMask: 24,
    },
  ],
});
```

**compute.ts**: `ec2.Instance` L2 Constructを使用
```typescript
// IMDSv2強制はL2ではプロパティ未対応のため、L1(CfnInstance)でエスケープハッチを使う
// これはCDKの「抽象化の限界」を体験する重要なポイント

// arm64 AMI指定
const machineImage = ec2.MachineImage.latestAmazonLinux2023({
  cpuType: ec2.AmazonLinuxCpuType.ARM_64,
});

// IMDSv2はエスケープハッチ(L1)で設定
const cfnInstance = instance.node.defaultChild as ec2.CfnInstance;
cfnInstance.addPropertyOverride('MetadataOptions.HttpTokens', 'required');
// コメント: L2 ConstructがIMDSv2をサポートしていないため、CloudFormationリソース(L1)に直接プロパティを注入している
// これはCDKの抽象化が「漏れる」場面。Terraformでは `metadata_options { http_tokens = "required" }` で直接書ける。
```

**monitoring.ts**: AWS Budgets は L1 Construct（`budgets.CfnBudget`）を使用
```typescript
// AWS BudgetsはCDKのL2 Constructが存在しないため、L1(CloudFormation相当)を直接使う
// Terraformの `aws_budgets_budget` リソースとの比較:
// - Terraform: HCLで宣言的に書ける
// - CDK: CfnBudgetにJSONライクなオブジェクトを渡す（型補完あり）
```

---

## コーディング規則

1. **全Constructに日本語コメントで「TerraformとCDKの違い」を明記**
2. **L1エスケープハッチを使う箇所は必ずその理由をコメントで説明**
3. **`cdk.Tags.of(construct).add(key, value)` でタグを付与**（全リソース必須）
4. **`any` 型の使用禁止**（型安全性を最大限活用する）

---

## CDK特有の学習ポイント（コメントに含めること）

実装中に以下の問いへの答えをコードコメントとして残すこと:

```typescript
// Q1: ec2.Vpc L2 Constructは内部で何個のCloudFormationリソースを生成するか？
//     → cdk synth 後に cdk.out/ のCFnテンプレートで確認すること

// Q2: Terraformの `for_each` に相当するCDKのパターンは何か？
//     → Array.from() や map() でConstructをループ生成する

// Q3: Terraform state に相当するCDKの状態管理はどこにあるか？
//     → CloudFormationスタックがAWS側で管理（ローカルstateファイル不要）
```

---

## 実装後の自己確認チェック（Claude Codeが実施）

```bash
cd cdk

# TypeScriptコンパイルチェック
npx tsc --noEmit

# CloudFormationテンプレート生成・確認
npx cdk synth

# リソース数確認（Terraformと比較）
npx cdk synth | grep -c "Type: AWS::"

# SSH(22)が含まれていないことを確認
npx cdk synth | grep -i "22" && echo "要確認" || echo "✅ SSHなし"

# デプロイ前の差分確認
npx cdk diff
```

---

## 完了後にやること（手動）

1. `npx cdk deploy` を実行
2. EC2にSSM接続できることを確認
3. infra-spec.mdの「検証完了条件」をチェック
4. `cdk.out/` のCloudFormationテンプレートを開いて、**Terraform実装で明示的に書いたリソースが何個隠蔽されているか数える**
5. **「CDKのConstructとTerraformのモジュールの違い」を15分間口頭で説明できるか確認**

---

## Phase 2 完了の定義

- [ ] `npx cdk deploy` が成功する
- [ ] SSM接続確認済み
- [ ] コスト監視設定済み
- [ ] IMDSv2強制が設定されている（L1エスケープハッチ使用）
- [ ] TypeScript型エラーがゼロ
- [ ] 全Constructに「TerraformとCDKの違い」コメントがある
- [ ] `adr/adr-002-cdk-vs-terraform.md` に以下を自分の言葉で記述:
  - 「CDKのL2 Constructが便利だったこと・不便だったこと」
  - 「L1エスケープハッチが必要になった理由と感想」
  - 「型安全性がインフラ設計にもたらした価値（またはノイズ）」