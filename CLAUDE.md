# terraform-lab

## 作業開始前の必須手順
以下のスキルを読んでから作業すること:
- `.claude/skills/terraform-module/SKILL.md`

---

## Python Environment

Python スクリプト、pytest、Ansible module、補助ツールなど、
Python を利用する作業では必ず `.venv` を使用すること。

システム Python への直接 `pip install` は禁止。

### venv セットアップ手順

新しいプロジェクトまたはクローン直後:
```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

### 作業前チェック

作業を開始する前に、必ず以下を確認:
1. カレントディレクトリがプロジェクトルートであること
2. `.venv` が存在すること (`ls .venv`)
3. venv がアクティブであること (`which python` が `.venv/bin/python` を指すこと)

アクティブでない場合は `source .venv/bin/activate` を実行してから進むこと。

### 禁止事項

- システム Python (`/usr/bin/python3`) への直接 pip install 禁止
- `sudo pip install` 禁止
- venv なしでの作業禁止

### requirements.txt の管理

- 各プロジェクトルートに `requirements.txt` を必ず置く
- バージョンは pin する（例: `checkov==3.x.x`）

---

## Terraform Execution Policy

**Terraform コマンドの実行は必ずユーザー自身が行う。**
Claude Code は以下を禁止とする:
- `terraform apply` の実行
- `terraform destroy` の実行
- `terraform import` の実行

### Claude Code の役割範囲

**OK（Claude Code が行う）**
- venv の作成: `python3 -m venv .venv`
- 依存パッケージのインストール: `pip install -r requirements.txt`
- `.tf` ファイルの作成・編集
- `terraform init` / `terraform validate` / `terraform fmt` の実行
- `terraform plan` の実行（読み取り専用のため許可）
- `checkov` / `tflint` による静的解析

**NG（ユーザーが自分で実行する）**
- `terraform apply`
- `terraform destroy`
- `terraform import`
- その他インフラに変更を加えるコマンド全般

### 実行が必要なタイミング

コードの準備が完了したら、実行すべきコマンドをユーザーに提示して止まること。

---

## .gitignore

各プロジェクトに以下を必ず含めること:
```
.venv/
.terraform/
*.tfstate
*.tfstate.backup
.terraform.lock.hcl
```