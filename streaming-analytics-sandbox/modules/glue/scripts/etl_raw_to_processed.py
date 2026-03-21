"""
Glue ETL Job: raw (JSON/NDJSON) → processed (Parquet + SNAPPY)

学習ポイント:
  - DynamicFrame (Glue) と DataFrame (Spark) の変換
  - Glue Catalog から読み込む（Crawler が事前に発見したスキーマを使う）
  - Parquet + SNAPPY で出力 → Athena のスキャンコスト削減
  - Hive スタイルパーティション (event_type/year/month/day/hour)
    → Athena の WHERE 条件でパーティションプルーニングが効く

引数 (--job-parameters):
  --JOB_NAME         : Glue が自動注入
  --source_bucket    : raw ゾーン S3 バケット名
  --target_bucket    : processed ゾーン S3 バケット名
  --database_name    : Glue Catalog データベース名
  --table_name       : Glue Catalog テーブル名（Crawler が作成）
"""

import sys

from awsglue.context import GlueContext
from awsglue.dynamicframe import DynamicFrame
from awsglue.job import Job
from awsglue.utils import getResolvedOptions
from pyspark.context import SparkContext
from pyspark.sql.functions import col, dayofmonth, hour, month, to_timestamp, year

args = getResolvedOptions(
    sys.argv,
    ["JOB_NAME", "source_bucket", "target_bucket", "database_name", "table_name"],
)

sc = SparkContext()
glueContext = GlueContext(sc)
spark = glueContext.spark_session
job = Job(glueContext)
job.init(args["JOB_NAME"], args)

# ---------------------------------------------------------------------------
# Step 1: Glue Catalog から raw ゾーンを読み込む
#         Crawler が /events/ 配下の NDJSON を走査してスキーマを登録済み
# ---------------------------------------------------------------------------
datasource = glueContext.create_dynamic_frame.from_catalog(
    database=args["database_name"],
    table_name=args["table_name"],
    transformation_ctx="datasource",
)

record_count = datasource.count()
print(f"[INFO] Records read from catalog: {record_count}")

if record_count == 0:
    print("[INFO] No records to process. Exiting.")
    job.commit()
    sys.exit(0)

# ---------------------------------------------------------------------------
# Step 2: DynamicFrame → DataFrame に変換して変換処理を行う
# ---------------------------------------------------------------------------
df = datasource.toDF()

# timestamp 文字列を Spark の TimestampType にキャスト
df = df.withColumn("event_ts", to_timestamp(col("timestamp")))

# Hive スタイルのパーティション列を追加
# Athena で WHERE year=2024 AND month=1 のようにプルーニングが効く
df = (
    df.withColumn("year",  year(col("event_ts")))
      .withColumn("month", month(col("event_ts")))
      .withColumn("day",   dayofmonth(col("event_ts")))
      .withColumn("hour",  hour(col("event_ts")))
)

# 中間列は不要なので削除
df = df.drop("event_ts")

print(f"[INFO] Schema after transformation:")
df.printSchema()

# ---------------------------------------------------------------------------
# Step 3: DynamicFrame に戻して Parquet で出力
# ---------------------------------------------------------------------------
output_frame = DynamicFrame.fromDF(df, glueContext, "output_frame")

glueContext.write_dynamic_frame.from_options(
    frame=output_frame,
    connection_type="s3",
    connection_options={
        "path": f"s3://{args['target_bucket']}/events/",
        # Hive スタイルパーティション: Glue / Athena が自動認識
        "partitionKeys": ["event_type", "year", "month", "day", "hour"],
    },
    format="parquet",
    format_options={
        "compression": "snappy",  # SNAPPY: バランスが良い（速度 vs 圧縮率）
    },
    transformation_ctx="output",
)

print(f"[INFO] Parquet written to s3://{args['target_bucket']}/events/")

job.commit()
