# terraform-lab

## 作業開始前の必須手順
以下のスキルを読んでから作業すること:
- `.Codex/skills/terraform-module/SKILL.md`

README 用画像の作成や埋め込み作業では、必要に応じて以下のスキルも使用すること:
- `.agents/skills/readme-hero-generator/SKILL.md`

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
Codex は以下を禁止とする:
- `terraform apply` の実行
- `terraform destroy` の実行
- `terraform import` の実行

### Codex の役割範囲

**OK（Codex が行う）**
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

## GitHub Actions（モノレポ）

GitHub Actions はリポジトリ直下の `.github/workflows/` しか読まない。
各プロジェクト配下の `.github/workflows/` は無効なので作らないこと。

ワークフローを追加するときの必須ルール:
- ファイル名は `<project>-<purpose>.yml`（例: `bedrock-finops-terraform.yml`）
- `pull_request` / `push` トリガーには必ず `paths:` を付け、
  `<project>/**` とそのワークフロー自身のみを対象にする（`paths:` なしは禁止）
- `working-directory` は `<project>/` プレフィックス付きで指定する
  （`defaults.run.working-directory` では `env` コンテキストが使えないためリテラルで書く）
- `workflow_dispatch` のみのワークフローは `paths:` 不要
- PR コメントの重複防止用の識別文字列にはプロジェクト名を含める

---

## tfvars の扱い

`*.tfvars` / `*.tfvars.json` は**常にローカル管理**（コミットしない）。
- リポジトリには `terraform.tfvars.example` のみコミットする
- 機密でない値でも `terraform.tfvars` はコミットしない
- CI では `-var` / `TF_VAR_*` / GitHub Variables・Secrets で値を渡す

---

## .claude/ の扱い

- `.claude/skills/` は**共有**する（git 管理する）。ルートの `.claude/skills/` に一本化し、プロジェクト個別の重複を作らない。
- `.claude/hooks/` と `.claude/settings*.json` は個人用（git 管理しない）。

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