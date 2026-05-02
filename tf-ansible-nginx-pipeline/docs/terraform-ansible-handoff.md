# Terraform → Ansible 設定値受け渡し設計

## 問題: なぜSSMパラメータを経由するのか

### アンチパターン: Terraform outputをAnsible varsに直接書く

```bash
# ❌ アンチパターン
terraform output instance_id >> ansible/vars/ec2.yml
```

問題点:
- 生成されたファイルをgit管理するとstateとvarsが二重管理になる
- CI/CD環境でのファイル生成・参照のタイミング問題が発生する

### 採用パターン: SSMパラメータを中間バスとして使用

```
Terraform → SSMパラメータ書き込み → Ansible実行時に読み取り
```

メリット:
- 設定値の信頼できる唯一の情報源（Single Source of Truth）がSSM
- AnsibleはSSMから常に最新の値を取得する
- 値の変更はTerraform applyだけで完結する
- GitにはSSMのパラメータ名だけを書けばよい（値のハードコード不要）

## Dynamic Inventoryの仕組み

```
AWS EC2 API
    ↓（タグフィルタ: AnsibleManaged=true, state=running）
aws_ec2 plugin
    ↓（instance-idをホスト名として使用）
Ansibleホスト: i-0123456789abcdef
    ↓（ansible_connection=aws_ssm）
SSMセッションマネージャー接続
    ↓（SSHキー不要、ポート22不要）
EC2インスタンス
```
