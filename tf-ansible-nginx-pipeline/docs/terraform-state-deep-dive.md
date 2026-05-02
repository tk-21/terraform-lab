# Terraform State 深掘り解説

## 1. stateとは何か

### JSONファイルとしての実体

`terraform.tfstate` はJSON形式のファイルで、Terraformが管理するリソースの「現在の状態」を記録する。

```json
{
  "version": 4,
  "terraform_version": "1.7.0",
  "serial": 3,
  "lineage": "f2a3b1c4-...",
  "outputs": {
    "vpc_id": {
      "value": "vpc-0a1b2c3d4e5f",
      "type": "string"
    }
  },
  "resources": [
    {
      "mode": "managed",
      "type": "aws_vpc",
      "name": "main",
      "provider": "provider[\"registry.terraform.io/hashicorp/aws\"]",
      "instances": [
        {
          "schema_version": 1,
          "attributes": {
            "id": "vpc-0a1b2c3d4e5f",
            "cidr_block": "10.0.0.0/16",
            "enable_dns_hostnames": true,
            "tags": {
              "Name": "handson-dev-vpc",
              "Environment": "dev"
            }
          },
          "dependencies": [
            "aws_internet_gateway.main"
          ]
        }
      ]
    }
  ]
}
```

### stateが「知っている」3つのこと

1. **リソースID**: AWSが付与した実際のID（`vpc-0a1b2c3d4e5f`など）。これによりTerraformはAWSリソースと.tfコードのマッピングを維持する
2. **属性値**: 作成時・最後のapply時のすべての属性（CIDR、タグ、設定値など）。`terraform plan`で差分計算に使われる
3. **依存関係グラフ**: `dependencies`フィールドでリソース間の依存を記録。destroyの順序制御に使われる

---

## 2. stateがないと何が起きるか

### `terraform apply`を2回実行したとき

stateがない状態（または無視した場合）は以下が起きる:

```
1回目: aws_vpc "main" を作成 → vpc-0a1b2c3d4e5f が作成される
2回目: stateがなければ "main" は存在しないと判断 → vpc-xxxxxxxxxx を新たに作成

結果: VPCが2つ存在する（意図しない重複）
```

**stateがあるから**「すでに存在する」と判断して何もしないか、差分だけを適用できる。

### ドリフト（手動変更）を検知できない問題

AWSコンソールで手動変更が行われたケース:

```
.tfファイル: cidr_block = "10.0.0.0/16"
AWSの実態:   cidr_block = "10.1.0.0/16"  ← 誰かが手動変更
stateの記録: cidr_block = "10.0.0.0/16"  ← 最後のapply時の値
```

`terraform plan`はstateとAWSの実態を比較し、ドリフトを検知できる。
stateがなければこの比較ができず、意図せぬ変更が気づかれないまま残る。

---

## 3. remote stateのアーキテクチャ

### なぜS3 + DynamoDBなのか

```hcl
# なぜS3 + DynamoDBなのかをコメントで説明した設定例
terraform {
  backend "s3" {
    bucket         = "handson-dev-tfstate"
    key            = "handson/dev/terraform.tfstate"
    region         = "ap-northeast-1"
    encrypt        = true          # 静止時暗号化：stateにはDB接続情報等が含まれる
    dynamodb_table = "handson-dev-tflock"  # 複数人の同時apply防止
  }
}
```

**S3を使う理由**:
- ローカルファイルはGitにコミットされやすく、シークレット漏洩リスクがある
- チームメンバー全員が同じstateを参照する必要がある
- S3のバージョニングにより、誤ったapply前の状態にロールバックできる

**DynamoDBを使う理由**:
- 2人が同時に`terraform apply`した場合、stateが壊れる（競合書き込み）
- DynamoDBのconditionチェックを使い、ロック取得→apply→ロック解放を原子的に行う
- ロック中は他のapplyが待機状態になる

### ローカルstateとの比較

| | ローカルstate | remote state (S3+DynamoDB) |
|---|---|---|
| チーム利用 | ❌ 個人のみ | ✅ 全員が同じstateを参照 |
| 同時apply | ❌ state破壊のリスク | ✅ ロックで防止 |
| 秘密情報 | ❌ Gitに入るリスク | ✅ S3暗号化+アクセス制御 |
| 障害耐性 | ❌ PCが壊れたら消える | ✅ S3の高耐久性 |
| ロールバック | ❌ 手動管理が必要 | ✅ S3バージョニング |

---

## 4. stateを直接触ってはいけないアンチパターン

### `terraform state rm` の正しい使いどころと危険性

```bash
# 正しい使いどころ: Terraformの管理から外したいが、AWSリソースは消したくない場合
# 例: モジュール移行時に一度stateから外してimportし直す
terraform state rm aws_s3_bucket.old_name

# ❌ 危険な使い方: apply失敗時の「とりあえずstateから消す」
# → 次のapplyで同じリソースを再作成しようとし、名前衝突エラーが起きる
# → 最悪の場合、AWSリソースが孤立して課金が続く
```

**`state rm`後は必ず**:
1. 対象リソースがAWSに存在するか確認する
2. 存在する場合は `terraform import` で再取り込みする

### `terraform import` が必要になる状況とその手順

**状況**: Terraform管理外のリソース（手動作成・既存リソース）をTerraform管理下に置きたい場合

```bash
# 手順1: .tfファイルにリソース定義を書く（まだapplyしない）
# main.tf
resource "aws_s3_bucket" "existing" {
  bucket = "my-existing-bucket"
}

# 手順2: importでstateに取り込む
terraform import aws_s3_bucket.existing my-existing-bucket

# 手順3: planで差分を確認（属性の不一致がないか確認）
terraform plan
# → "No changes" になれば完全にTerraform管理下に移行完了

# 手順4: planで差分が出た場合は.tfファイルを実態に合わせて修正する
```

**Terraform 1.5以降**: `import`ブロックをコードで宣言できる

```hcl
import {
  to = aws_s3_bucket.existing
  id = "my-existing-bucket"
}
```

### stateを直接編集してはいけない理由

`terraform.tfstate`をテキストエディタで直接編集することは**絶対に禁止**:
- JSONのインデントずれや構文エラーでstateが読めなくなる
- `serial`フィールドのインクリメントが行われず、remote stateとの競合チェックが機能しなくなる
- 正規の操作は `terraform state mv` / `terraform state rm` / `terraform import` を使うこと
