resource "aws_bedrockagent_agent_action_group" "aws_inspector" {
  agent_id          = aws_bedrockagent_agent.this.id
  agent_version     = "DRAFT"
  action_group_name = "aws-inspector"
  description       = "AWSリソース情報を調査するアクショングループ"

  skip_resource_in_use_check = true

  action_group_executor {
    lambda = var.aws_inspector_lambda_arn
  }

  api_schema {
    payload = jsonencode({
      openapi = "3.0.0"
      info = {
        title   = "AWS Inspector API"
        version = "1.0.0"
      }
      paths = {
        "/get_cost_and_usage" = {
          post = {
            summary     = "過去30日間のAWSコストをサービス別に取得する"
            operationId = "getCostAndUsage"
            responses = {
              "200" = {
                description = "コスト情報"
                content = {
                  "application/json" = {
                    schema = {
                      type = "object"
                      properties = {
                        period = { type = "string", description = "集計期間" }
                        costs  = { type = "object", description = "サービス別コスト" }
                      }
                    }
                  }
                }
              }
            }
          }
        }
        "/list_ec2_instances" = {
          post = {
            summary     = "指定リージョンのEC2インスタンス一覧を取得する"
            operationId = "listEc2Instances"
            requestBody = {
              content = {
                "application/json" = {
                  schema = {
                    type = "object"
                    properties = {
                      region = { type = "string", description = "AWSリージョン", default = "ap-northeast-1" }
                    }
                  }
                }
              }
            }
            responses = {
              "200" = {
                description = "EC2インスタンス一覧"
                content = {
                  "application/json" = {
                    schema = {
                      type = "object"
                      properties = {
                        region    = { type = "string" }
                        instances = { type = "array", items = { type = "object" } }
                        count     = { type = "integer" }
                      }
                    }
                  }
                }
              }
            }
          }
        }
        "/get_cw_alarms" = {
          post = {
            summary     = "CloudWatchアラームの一覧と状態を取得する"
            operationId = "getCwAlarms"
            responses = {
              "200" = {
                description = "CloudWatchアラーム一覧"
                content = {
                  "application/json" = {
                    schema = {
                      type = "object"
                      properties = {
                        alarms = { type = "array", items = { type = "object" } }
                        count  = { type = "integer" }
                      }
                    }
                  }
                }
              }
            }
          }
        }
      }
    })
  }
}

resource "aws_bedrockagent_agent_action_group" "report_writer" {
  agent_id          = aws_bedrockagent_agent.this.id
  agent_version     = "DRAFT"
  action_group_name = "report-writer"
  description       = "Markdownレポートを生成してS3に保存するアクショングループ"

  skip_resource_in_use_check = true

  action_group_executor {
    lambda = var.report_writer_lambda_arn
  }

  api_schema {
    payload = jsonencode({
      openapi = "3.0.0"
      info = {
        title   = "Report Writer API"
        version = "1.0.0"
      }
      paths = {
        "/generate_report" = {
          post = {
            summary     = "収集したデータからMarkdownレポートを生成する"
            operationId = "generateReport"
            requestBody = {
              required = true
              content = {
                "application/json" = {
                  schema = {
                    type = "object"
                    properties = {
                      title = { type = "string", description = "レポートタイトル" }
                      data  = { type = "object", description = "レポートに含めるデータ（ec2_instances, costs, alarmsなど）" }
                    }
                    required = ["title", "data"]
                  }
                }
              }
            }
            responses = {
              "200" = {
                description = "生成されたレポート"
                content = {
                  "application/json" = {
                    schema = {
                      type = "object"
                      properties = {
                        title   = { type = "string" }
                        content = { type = "string", description = "Markdown形式のレポート本文" }
                        lines   = { type = "integer" }
                      }
                    }
                  }
                }
              }
            }
          }
        }
        "/save_to_s3" = {
          post = {
            summary     = "レポートをS3に保存する"
            operationId = "saveToS3"
            requestBody = {
              required = true
              content = {
                "application/json" = {
                  schema = {
                    type = "object"
                    properties = {
                      title   = { type = "string", description = "レポートタイトル（ファイル名に使用）" }
                      content = { type = "string", description = "保存するMarkdownコンテンツ" }
                    }
                    required = ["title", "content"]
                  }
                }
              }
            }
            responses = {
              "200" = {
                description = "保存結果"
                content = {
                  "application/json" = {
                    schema = {
                      type = "object"
                      properties = {
                        bucket     = { type = "string" }
                        key        = { type = "string" }
                        s3_uri     = { type = "string" }
                        size_bytes = { type = "integer" }
                      }
                    }
                  }
                }
              }
            }
          }
        }
        "/list_past_reports" = {
          post = {
            summary     = "過去30日間のレポート一覧をS3から取得する"
            operationId = "listPastReports"
            responses = {
              "200" = {
                description = "レポート一覧"
                content = {
                  "application/json" = {
                    schema = {
                      type = "object"
                      properties = {
                        reports = { type = "array", items = { type = "object" } }
                        count   = { type = "integer" }
                      }
                    }
                  }
                }
              }
            }
          }
        }
      }
    })
  }
}

resource "aws_bedrockagent_agent_action_group" "notifier" {
  agent_id          = aws_bedrockagent_agent.this.id
  agent_version     = "DRAFT"
  action_group_name = "notifier"
  description       = "SNSでレポート完了通知を送信するアクショングループ"

  skip_resource_in_use_check = true

  action_group_executor {
    lambda = var.notifier_lambda_arn
  }

  api_schema {
    payload = jsonencode({
      openapi = "3.0.0"
      info = {
        title   = "Notifier API"
        version = "1.0.0"
      }
      paths = {
        "/send_sns_notification" = {
          post = {
            summary     = "SNSトピックに通知メッセージを送信する"
            operationId = "sendSnsNotification"
            requestBody = {
              required = true
              content = {
                "application/json" = {
                  schema = {
                    type = "object"
                    properties = {
                      subject    = { type = "string", description = "通知の件名" }
                      message    = { type = "string", description = "通知本文" }
                      report_uri = { type = "string", description = "S3レポートのURI（オプション）" }
                    }
                    required = ["subject", "message"]
                  }
                }
              }
            }
            responses = {
              "200" = {
                description = "送信結果"
                content = {
                  "application/json" = {
                    schema = {
                      type = "object"
                      properties = {
                        message_id = { type = "string" }
                        topic_arn  = { type = "string" }
                        subject    = { type = "string" }
                      }
                    }
                  }
                }
              }
            }
          }
        }
      }
    })
  }
}
