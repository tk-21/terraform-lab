"""
Phase 3: Pulumi (Python) 実装 — エントリーポイント

iac-trilogy-lab の同一インフラを Pulumi で実装する。
Terraform (Phase 1) / CDK (Phase 2) との設計哲学の差を体感・言語化することが目的。

【3ツールの本質的な違い】

Terraform (HCL):
  - 宣言型専用言語。ループや条件は DSL (for_each / count / dynamic) で表現。
  - state ファイルがローカルまたは S3 に JSON として保存される。
  - 「インフラの設計図」をコードで書く感覚。

CDK (TypeScript):
  - オブジェクト指向の Construct 階層でリソースを組み立てる。
  - L1/L2/L3 の抽象化レベルがあり、L2 は「ベストプラクティス入り」の高レベル API。
  - 最終的に CloudFormation テンプレートに変換される（状態は CloudFormation が管理）。

Pulumi (Python):
  - 汎用プログラミング言語でインフラを記述する。ループは Python の for 文そのまま。
  - Output[T] 型が非同期値の依存解決を担う（最大の学習コスト）。
  - state は Pulumi Cloud またはローカルファイルに保存（Terraform state に近い）。

【なぜ Output[T] が存在するか】

Pulumi のエンジンはリソースを並列に作成する。
VPC と S3 バケットは互いに依存しないため同時に作成できる。
しかし EC2 は VPC より後に作る必要がある。

この「順序制約」を表現するのが Output[T] 型。
vpc.id (Output[str]) を subnet の vpc_id 引数に渡すと、
Pulumi エンジンは「subnet の作成は vpc の作成完了を待つ」と自動理解する。

Terraform では depends_on で明示することもあるが、
Pulumi では Output[T] の参照が暗黙的に依存グラフを構築する。

実行方法:
  pulumi preview    # Terraform plan / CDK diff に相当
  pulumi up         # Terraform apply / CDK deploy に相当
  pulumi destroy    # Terraform destroy / CDK destroy に相当
  pulumi stack output  # Terraform output / CDK 出力確認に相当
"""
import pulumi

from compute import create_compute
from monitoring import create_monitoring
from network import create_network
from storage import create_storage

# Python 関数呼び出しでリソースを構成する
# Terraform の module 呼び出し、CDK の Construct instantiation に相当するが、
# 「ただの Python 関数」であることが Pulumi の特徴
# → 関数・クラス・モジュールのどの単位でも自由に組み立てられる

vpc, subnet = create_network()
instance, sg = create_compute(vpc, subnet)
bucket = create_storage()
create_monitoring(instance)

# -----------------------------------------------------------------------
# Pulumi Outputs（Terraform の outputs.tf に相当）
# -----------------------------------------------------------------------
# pulumi.export() で宣言した値は `pulumi stack output` コマンドで確認できる
# Output[T] 型の値をそのままエクスポートできる（apply() 不要）
pulumi.export("vpc_id", vpc.id)
pulumi.export("subnet_id", subnet.id)
pulumi.export("instance_id", instance.id)
pulumi.export("bucket_name", bucket.id)
pulumi.export("security_group_id", sg.id)
