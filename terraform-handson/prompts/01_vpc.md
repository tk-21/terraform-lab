# Step 1 — VPC プロンプト集

## 学習目標
- VPC・サブネット・IGW・ルートテーブルの関係を理解する
- `count` メタ引数でリソースをループ生成する
- `data` ソースで AZ 一覧を動的取得する
- `locals` で共通タグを一元管理する

---

## 🟢 Step 1: 初期構築・動作確認

```
01_vpc ディレクトリで terraform init && terraform plan を実行してください。
plan の結果を確認し、作成されるリソースの一覧を日本語で説明してください。
問題なければ terraform apply を実行してください。
```

```
apply 完了後、terraform output を実行して出力値を確認してください。
vpc_id と public_subnet_ids の値を表示してください。
```

---

## 🔵 Step 2: コードを読んで理解する

```
01_vpc/main.tf の count を使っているリソースを全て探して、
count の仕組みと count.index の役割を説明してください。
```

```
01_vpc/main.tf の data "aws_availability_zones" について、
data ソースを使う理由と、ハードコードした場合の問題点を説明してください。
```

```
パブリックサブネットとプライベートサブネットの違いを、
今回のコードのどの設定が違いを生んでいるか具体的に指摘して説明してください。
```

```
ルートテーブルがない（またはデフォルトルートがない）状態だと
パブリックサブネットに EC2 を置いても外部通信できない理由を説明してください。
```

---

## 🟡 Step 3: コードを改造して学ぶ

```
01_vpc/variables.tf の public_subnet_cidrs を 3つに増やして、
3つ目の AZ のパブリックサブネットも作成されるように変更してください。
変更後に terraform plan で差分を確認し、追加されるリソースを説明してください。
```

```
01_vpc/main.tf に VPC Flow Logs を追加してください。
ログの送り先は CloudWatch Logs とし、IAM Role も Terraform で作成してください。
なぜ Flow Logs が必要か（セキュリティ上の意味）も説明してください。
```

```
01_vpc/main.tf の locals に Terraform を実行したユーザーの情報を
タグとして追加する方法を調べて実装してください。
（ヒント: data "aws_caller_identity"）
```

---

## 🔴 トラブルシュート

```
terraform plan でこのエラーが出ました。原因と修正方法を教えてください。
---
[エラーをここに貼り付ける]
---
```

```
サブネットの CIDR が重複しているエラーが出ています。
variables.tf の CIDR 設定を確認して修正してください。
```

```
AZ が足りないエラーが出ています（例: ap-northeast-1 は 3 AZ あるが
変数の CIDR が 2 つしか定義されていない等）。
状況を確認して適切に修正してください。
```
