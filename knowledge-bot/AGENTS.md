# AGENTS.md

## Project overview
このリポジトリは、インフラ自動化およびAI基盤検証用のプロジェクトです。

主な技術:
- Terraform
- AWS
- Docker
- Python
- FastAPI

## Primary goals
- 再現可能な構成をコードで管理する
- 手動変更ではなく IaC を優先する
- セキュリティを優先し、秘密情報を出力しない
- 既存構造を尊重して最小差分で変更する

## Coding rules
- 既存のディレクトリ構成を崩さない
- Terraform は `terraform/modules` と `terraform/envs` を優先して利用する
- 新規リソースは module 化を優先する
- Python は既存の lint / formatter に従う
- README や docs の内容と矛盾する実装をしない
- 不要なリネームや大規模整形はしない
- コメントは必要最小限にする

## Command policy
- 破壊的なコマンドは実行前に必ず確認する
- 本番相当の設定変更を伴う提案は、変更点・影響範囲・ロールバック案を先に示す
- テスト・lint・validate を優先し、失敗時は原因を説明する

## Security rules
- Secrets, tokens, passwords, private keys, certificates を出力しない
- `.env`, `*.tfvars`, `*.pem`, `*.key`, `secrets/`, `private/` 配下は読まない
- 読む必要がある場合でも、まず「必要性」を説明し、ユーザー確認があるまで参照しない
- 実データではなく `.env.example` やサンプル値を優先する
- 機密値はマスクして扱う

## Files Codex should avoid reading
以下のファイルやディレクトリは、明示的に必要と判断できるまで読まないこと:
- `.env`
- `.env.*`
- `*.tfvars`
- `*.tfvars.json`
- `*.pem`
- `*.key`
- `*.p12`
- `secrets/**`
- `private/**`
- `certs/**`
- `node_modules/**`
- `.terraform/**`
- `dist/**`
- `build/**`
- `coverage/**`
- `*.log`

## Preferred sources of truth
優先順位:
1. `README.md`
2. `docs/architecture.md`
3. `docs/coding-rules.md`
4. 実装コード
5. テストコード

## Terraform policy
- `terraform fmt`
- `terraform validate`
- 可能なら変更理由を1行で説明する
- resource の直書きより module 再利用を優先する
- provider / backend / state の扱いは勝手に変えない

## Python policy
- 既存の依存管理方式を尊重する
- 新規ライブラリ追加時は必要性を明記する
- テスト追加を優先する

## Output style
- まず結論
- 次に変更点
- 次に影響範囲
- 最後に確認コマンド