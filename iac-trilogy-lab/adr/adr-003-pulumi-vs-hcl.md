# ADR-003: Pulumi (Python) vs HCL (Terraform) — 設計哲学の比較

**ステータス**: Draft（`pulumi up` 検証完了後に Accepted へ更新すること）
**作成日**: 2026-05-18
**対象フェーズ**: Phase 3 (Pulumi) 完了後に記述

---

## コンテキスト

iac-trilogy-lab では同一 AWS インフラを Terraform (HCL) / CDK (TypeScript) / Pulumi (Python) の
3 ツールで実装し、IaC 設計哲学の差異を体感・言語化することを目的としている。

本 ADR は Phase 3 (Pulumi) 実装を通じて気づいた点を記録する。

---

## Output[T] 型で戸惑った箇所とその理解

### 戸惑った箇所

**CloudWatch Alarm の dimensions 設定**（monitoring.py）。

Terraform では以下のように書けた:
```hcl
dimensions = {
  InstanceId = aws_instance.app.id
}
```

Pulumi では `instance.id` が `Output[str]` 型であるため、
dict の value として直接置くと型エラーになる:

```python
# ❌ これは動かない
dimensions={"InstanceId": instance.id}

# ✅ apply() で str に解決してから dict を構築する
dimensions=instance.id.apply(lambda id: {"InstanceId": id})
```

### 理解に至った考え方

Output[T] は「将来解決される値への約束（Promise）」。

Pulumi エンジンはリソースを並列で作成するため、
EC2 インスタンスの作成中に `instance.id` はまだ確定していない。
`apply()` は「ID が確定したときに実行するコールバック」を登録する仕組み。

**別リソースの引数に渡す場合は apply() 不要**（エンジンが自動解決）という
「暗黙の依存解決」と「apply() が必要な明示的変換」の使い分けが最初の難関だった。

判断基準: Pulumi リソースのコンストラクタに渡すなら apply() 不要。
Python の値として使いたい（文字列操作・dict 組み立て等）なら apply() 必要。

---

## Python が HCL より強力だと感じた場面

### 1. リスト内包表記でのタグ操作

Terraform では locals の merge() 関数や for 式が必要だった箇所を、
Python の dict 展開 `{**COMMON_TAGS, "Name": "..."}` で直感的に書けた。

### 2. 型ヒントによる補完

```python
def create_compute(vpc: aws.ec2.Vpc, subnet: aws.ec2.Subnet) -> Tuple[...]:
```

関数シグネチャに型ヒントを付けることで、引数の渡し忘れや型の誤りを
IDE が事前に検出できた。Terraform の module 呼び出しには型検査がない。

### 3. データソースの同期呼び出し

```python
al2023_ami = aws.ec2.get_ami(most_recent=True, ...)
```

Terraform の `data "aws_ami" {}` ブロックと同じ結果だが、
Python では関数の戻り値として直接扱える。条件分岐やループと自然に組み合わせられる。

---

## Python が HCL より不便だと感じた場面

### 1. Output[T] 型の精神的コスト

「この値は Output か、通常の値か」を常に意識する必要がある。
Terraform では state 参照・データソース参照のどちらも同じように書けたため、
この区別を考える認知負荷がなかった。

### 2. エラーメッセージが遅延する

Pulumi はリソース作成を非同期で並列実行するため、
エラーが `apply()` のコールバック内で起きると実行時にしか検出できない。
Terraform の `terraform validate` のような静的検証に比べると早期エラー検出が弱い。

### 3. IDE の補完が完全ではない

`aws.ec2.InstanceMetadataOptionsArgs` のような引数クラスは、
TypeScript の CDK に比べると型推論の精度が低く、補完が効かない場面があった。

---

## Pulumi の state と Terraform state の根本的な違い

### 共通点

どちらも「現在のインフラの実際の状態」をファイルに記録し、
次回実行時に「あるべき状態（コード）」との差分を計算する。

### 根本的な違い

| 観点 | Terraform state | Pulumi state |
|---|---|---|
| 保存先デフォルト | ローカルの `terraform.tfstate` | Pulumi Cloud（SaaS） |
| フォーマット | JSON（手動編集可） | JSON（Pulumi 管理、手動編集非推奨） |
| ロック機構 | S3 + DynamoDB で実装 | Pulumi Cloud が自動提供 |
| リソース識別子 | リソース種別 + ローカル名 | URN（Uniform Resource Name）形式 |
| シークレット暗号化 | なし（別途 SOPS 等が必要） | state 内に暗号化して保存可能 |

### URN の特徴

Pulumi は各リソースを以下の形式の URN で一意識別する:
```
urn:pulumi:{stack}::{project}::{type}::{name}
例: urn:pulumi:itl-dev::itl-trilogy-lab::aws:ec2/instance:Instance::itl-dev-app
```

Terraform の `resource "aws_instance" "app"` のようなシンプルな参照と異なり、
スタック・プロジェクト・型情報が全て埋め込まれる。

リソース名変更時に Terraform は `moved` ブロックが必要だが、
Pulumi は URN の変更として扱い「削除 + 再作成」になることがある。
この点はリファクタリング時のリスクとして意識が必要。

---

## 今後のツール選択基準（3 ツール経験後）

| ケース | 選択 | 理由 |
|---|---|---|
| チーム全員が Terraform 経験者 | Terraform | 学習コスト最小、エコシステム成熟 |
| 複雑な条件分岐・ループが必要 | Pulumi | 汎用言語の表現力が活きる |
| AWS Only・型安全性重視 | CDK | L2 コンストラクトの抽象化・型補完が強力 |
| マルチクラウド（AWS + GCP 等） | Pulumi または Terraform | CDK は AWS に特化 |
| シークレット管理を IaC に統合したい | Pulumi | state 内暗号化が標準機能 |

---

## 決定

Phase 3 として Pulumi Python 実装を完了した。
Output[T] 型の設計は初見では難解だが、「依存グラフの自動構築」という
Pulumi エンジンの設計思想を理解すると合理性が見えてくる。

「Python がそのまま使える」という柔軟性は強みだが、
Output[T] という型システムへの学習コストが Terraform より高いため、
小規模な AWS インフラには Terraform、複雑なロジックが必要な場合に Pulumi を検討する。
