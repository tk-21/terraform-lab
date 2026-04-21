#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULES_DIR="${SCRIPT_DIR}/../terraform/modules"

build_receiver() {
  local src_dir="${MODULES_DIR}/lambda_receiver/src"
  local pkg_dir="${MODULES_DIR}/lambda_receiver/receiver_pkg"
  local zip_path="${MODULES_DIR}/lambda_receiver/receiver.zip"

  rm -rf "${pkg_dir}"
  mkdir -p "${pkg_dir}"
  pip install aws-lambda-powertools boto3 -t "${pkg_dir}" --quiet
  cp "${src_dir}/receiver.py" "${pkg_dir}/"
  (cd "${pkg_dir}" && zip -r "${zip_path}" . -x "*.pyc" -x "*/__pycache__/*")
  rm -rf "${pkg_dir}"
  echo "Built: ${zip_path}"
}

build_generator() {
  local src_dir="${MODULES_DIR}/lambda_generator/src"
  local pkg_dir="${MODULES_DIR}/lambda_generator/generator_pkg"
  local zip_path="${MODULES_DIR}/lambda_generator/generator.zip"

  rm -rf "${pkg_dir}"
  mkdir -p "${pkg_dir}"
  pip install aws-lambda-powertools -t "${pkg_dir}" --quiet
  cp "${src_dir}/generator.py" "${pkg_dir}/"
  (cd "${pkg_dir}" && zip -r "${zip_path}" . -x "*.pyc" -x "*/__pycache__/*")
  rm -rf "${pkg_dir}"
  echo "Built: ${zip_path}"
}

echo "Building Lambda packages (arm64)..."
echo "Note: Run inside a linux/arm64 environment or Docker for correct architecture."
echo "  docker run --rm --platform linux/arm64 -v \$(pwd):/work -w /work python:3.12-slim bash scripts/build_lambda.sh"
echo ""

build_receiver
build_generator

echo "Done."
