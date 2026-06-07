#!/bin/bash
# Lambda 関数の依存パッケージをインストールする
# terraform apply の前に実行すること
# 実行: bash scripts/package-lambda.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

install_packages() {
  local lambda_dir="$1"
  local req_file="$lambda_dir/requirements.txt"

  if [ ! -f "$req_file" ]; then
    echo "[$lambda_dir] requirements.txt なし — スキップ"
    return
  fi

  echo "=== $lambda_dir のパッケージインストール ==="
  # arm64 Lambda 向けにビルド（linux/arm64 プラットフォーム指定）
  pip install \
    --platform manylinux2014_aarch64 \
    --target "$lambda_dir" \
    --implementation cp \
    --python-version 3.12 \
    --only-binary=:all: \
    --upgrade \
    -r "$req_file"
  echo "[$lambda_dir] インストール完了"
}

install_packages "$REPO_ROOT/lambda/rotator"
install_packages "$REPO_ROOT/lambda/notifier"

echo ""
echo "パッケージインストール完了。terraform apply を実行してください。"
