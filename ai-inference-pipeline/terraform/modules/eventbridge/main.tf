# S3オブジェクト作成イベントをStep Functionsに転送するルール
# input/ プレフィックスに限定することで、中間出力ファイルの再トリガーを防ぐ
resource "aws_cloudwatch_event_rule" "s3_to_sfn" {
  name        = "${var.name_prefix}-s3-input-trigger"
  description = "S3 input/配下へのファイルアップロードでパイプラインを起動"

  event_pattern = jsonencode({
    source      = ["aws.s3"]
    detail-type = ["Object Created"]
    detail = {
      bucket = {
        name = [var.input_bucket_name]
      }
      object = {
        # input/ プレフィックスのオブジェクトのみに絞り込む
        key = [{ prefix = "input/" }]
      }
    }
  })
}

resource "aws_cloudwatch_event_target" "sfn" {
  rule     = aws_cloudwatch_event_rule.s3_to_sfn.name
  arn      = var.sfn_arn
  role_arn = var.eventbridge_role_arn

  # EventBridgeのS3イベント構造をStep Functionsが期待するJSONに変換する
  # input_transformer を使うことでLambdaを介さず直接マッピングできる
  input_transformer {
    input_paths = {
      bucket = "$.detail.bucket.name"
      key    = "$.detail.object.key"
    }
    input_template = <<-EOT
    {
      "input_bucket": "<bucket>",
      "s3_key": "<key>"
    }
    EOT
  }
}
