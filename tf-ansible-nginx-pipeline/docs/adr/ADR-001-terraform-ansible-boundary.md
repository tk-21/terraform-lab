# ADR-001: TerraformとAnsibleの責務分界

**ステータス**: 採用

**日付**: 2026-05-03

## コンテキスト

インフラ構築においてTerraform（IaC）とAnsible（Configuration Management）の両方を使用する。
それぞれ何を管理すべきかの判断基準を明示する。

## 決定

| 管理対象 | Terraform | Ansible | 理由 |
|---------|-----------|---------|------|
| VPC/サブネット/IGW | ✅ | ❌ | 作成後は変更頻度が低いImmutableリソース |
| EC2インスタンス | ✅ | ❌ | AMI・インスタンスタイプはIaCで宣言的に管理 |
| セキュリティグループ | ✅ | ❌ | ネットワーク設計はTerraform stateで追跡必須 |
| OS設定・ミドルウェア | ❌ | ✅ | インスタンス起動後の設定変更が発生するMutableな領域 |
| nginx設定ファイル | ❌ | ✅ | アプリ要件変更に追随するため頻繁に変更される |
| SSMパラメータ（設定値） | ✅ | 読取のみ | Ansibleへの設定受け渡し口としてTerraformが作成 |
| cronジョブ | ❌ | ✅ | OSレイヤーの設定はAnsibleで管理 |

## 結論の根拠

- **Terraform**: **「存在するかどうか」** を管理する（Immutable Infrastructure）
- **Ansible**: **「どういう状態にあるか」** を管理する（Configuration Management）
- **境界の判断軸**: `terraform destroy` したら消えてほしいものか？→ Terraform / 消えなくていいものか？→ Ansible

## 否定した選択肢

### user_dataだけで全部やる
- 却下理由: 変更のたびにEC2再作成が必要になり運用不可
- OS設定・nginx設定の変更ごとにインスタンス置き換えが発生し、ダウンタイムリスクと再起動コストが高い

### Ansibleだけで全部やる
- 却下理由: stateがないため差分管理・依存関係解決が困難
- VPC/EC2/SGのような「存在するかどうか」を管理するにはstateが必要
- AnsibleはべきIDを保証するが、リソースの作成・削除順序の依存関係解決はTerraformが得意

## 結果として得られるもの

この設計により以下が実現できる:

1. **変更影響の局所化**: nginx設定変更 → Ansibleのみ再実行。EC2を再作成しない
2. **ドリフト検知**: `terraform plan` でAWSリソースの意図せぬ変更を検知できる
3. **設定の可読性**: インフラ（Terraform）とOS設定（Ansible）が分離され、それぞれが読みやすい
