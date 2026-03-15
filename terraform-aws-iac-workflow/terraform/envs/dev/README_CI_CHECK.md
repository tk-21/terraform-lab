# リポジトリルートで
git checkout -b ci/plan-check

mkdir -p terraform/envs/dev
echo "CI plan check $(date)" > terraform/envs/dev/README_CI_CHECK.md

git add terraform/envs/dev/README_CI_CHECK.md
git commit -m "ci: trigger terraform plan workflow"
