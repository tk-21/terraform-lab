# ADR-001: TerraformとAnsibleの責務分界

**ステータス**: 採用  
**決定日**: YYYY-MM-DD  
**決定者**: インフラチーム

---

## コンテキスト

インフラ構築においてTerraform（IaC）とAnsible（Configuration Management）を
組み合わせて使用する。「どちらで何を管理するか」の判断基準が曖昧だと、
設定がどこで管理されているか分からなくなり、変更時のリスクが高まる。

---

## 決定

### 責務分界の判断軸

> **「terraform destroyしたら消えてほしいものか？」**
>
> YES → Terraform で管理する（Immutable Infrastructure）  
> NO  → Ansible で管理する（Configuration Management）

### 管理対象マトリクス

| 管理対象 | Terraform | Ansible | 判断理由 |
|---------|:---------:|:-------:|---------|
| VPC・サブネット・IGW | ✅ | ❌ | Immutableなネットワーク設計。stateで依存関係を追跡する必要がある |
| EC2インスタンス | ✅ | ❌ | AMI・インスタンスタイプはIaCで宣言的に管理する |
| セキュリティグループ | ✅ | ❌ | ネットワーク設計はTerraform stateで追跡必須 |
| IAMロール・ポリシー | ✅ | ❌ | 権限設計はコードレビュー必須。Terraform管理で証跡を残す |
| SSMパラメータ（設定値） | ✅ | 読取のみ | TerraformがSSoT。Ansibleは読み取るだけ |
| OS設定・ミドルウェア | ❌ | ✅ | インスタンス起動後の設定変更が発生するMutableな領域 |
| nginx設定ファイル | ❌ | ✅ | アプリ要件変更に追随する。Ansibleのtemplateで管理 |
| cronジョブ | ❌ | ✅ | OSレイヤーの設定はAnsibleで管理 |
| アプリケーションコード | ❌ | ✅ | デプロイはAnsibleまたはCI/CDツール |

---

## 否定した選択肢

### 1. user_dataだけで全部やる
- **否定理由**: 変更のたびにEC2の再作成が必要になる。ミドルウェア設定変更のたびにインスタンスが置き換わるため本番運用に不向き。

### 2. Ansibleだけで全部やる
- **否定理由**: stateがないため差分管理が困難。依存関係の解決（VPC → Subnet → EC2の順序）をコードで表現しにくい。

### 3. CloudFormationを使う
- **否定理由**: AWSリソースのみ対象でOS設定管理ができない。Ansible連携が複雑になる。

---

## 結果として生まれる制約

1. Terraformリソースを手動で変更してはいけない（terraform planがdirtyになる）
2. OS・ミドルウェアの設定をAWS外（Ansibleなし）で変更してはいけない
3. SSMパラメータの値はTerraformで変更し、Ansibleで読み取る（値の直接編集禁止）

---

## 参考

- [Immutable Infrastructure](https://www.hashicorp.com/resources/what-is-mutable-vs-immutable-infrastructure)
- [Ansible Best Practices](https://docs.ansible.com/ansible/latest/tips_tricks/ansible_tips_tricks.html)