# [1] DataBrew Dataset
resource "aws_databrew_dataset" "raw" {
  name = "${var.name_prefix}-raw-dataset"

  format = "JSON"

  format_options {
    json {
      multi_line = false
    }
  }

  input {
    s3_input_definition {
      bucket = var.raw_bucket_name
      key    = "logs/"
    }
  }
}

# [2] DataBrew Recipe
resource "aws_databrew_recipe" "main" {
  name = "${var.name_prefix}-recipe"

  step {
    action {
      operation = "CAST"
      parameters = {
        sourceColumn = "status_code"
        dataType     = "INTEGER"
      }
    }
  }

  step {
    action {
      operation = "CAST"
      parameters = {
        sourceColumn = "latency_ms"
        dataType     = "INTEGER"
      }
    }
  }

  step {
    action {
      operation = "DELETE_ROWS_WITH_NULL_IN_COLUMN"
      parameters = {
        sourceColumn = "request_id"
      }
    }
  }

  step {
    action {
      operation = "CREATE_COLUMN"
      parameters = {
        newColumnName  = "latency_category"
        columnDataType = "STRING"
        expression     = "if(:latency_ms < 100, 'fast', if(:latency_ms < 500, 'normal', 'slow'))"
      }
    }
  }

  step {
    action {
      operation = "CREATE_COLUMN"
      parameters = {
        newColumnName  = "is_error"
        columnDataType = "BOOLEAN"
        expression     = "if(:status_code >= 400, true, false)"
      }
    }
  }

  step {
    action {
      operation = "CREATE_COLUMN"
      parameters = {
        newColumnName  = "processed_at"
        columnDataType = "DATETIME"
        expression     = "now()"
      }
    }
  }
}

# [3] DataBrew Project
resource "aws_databrew_project" "main" {
  name         = "${var.name_prefix}-databrew-project"
  dataset_name = aws_databrew_dataset.raw.name
  recipe_name  = aws_databrew_recipe.main.name
  role_arn     = var.databrew_role_arn

  sample {
    size = 500
    type = "FIRST_N"
  }
}

# [4] DataBrew Job
resource "aws_databrew_job" "main" {
  name         = "${var.name_prefix}-job"
  type         = "RECIPE"
  dataset_name = aws_databrew_dataset.raw.name
  role_arn     = var.databrew_role_arn

  recipe {
    name = aws_databrew_recipe.main.name
  }

  output {
    location {
      bucket = var.processed_bucket_name
      key    = "processed/"
    }
    format = "PARQUET"
    format_options {
      parquet {
        row_count = 1000000
      }
    }
    compression = "SNAPPY"
    overwrite   = true
  }

  max_capacity     = 5
  max_retries      = 1
  timeout          = 2880
  log_subscription = "ENABLE"
}

# [5] DataBrew Schedule
resource "aws_databrew_schedule" "main" {
  name            = "${var.name_prefix}-schedule"
  cron_expression = "cron(0 * * * ? *)"
  job_names       = [aws_databrew_job.main.name]
}
