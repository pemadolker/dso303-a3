# One zip holds all three handlers (workers/). CI runs `npm ci` there first so node_modules is included.
data "archive_file" "workers" {
  type        = "zip"
  source_dir  = "${path.module}/../workers"
  output_path = "${path.module}/.build/workers.zip"
  excludes    = ["test", "package-lock.json", ".gitignore"]
}

locals {
  worker_env = {
    DB_SECRET_ARN   = aws_secretsmanager_secret.db.arn
    EMAIL_QUEUE_URL = aws_sqs_queue.email.url
    SES_SENDER      = var.ses_sender_email
  }
}

# --- marking-fn: auto-marks MCQ answers; also the 5-minute sweeper that auto-submits expired attempts ---
resource "aws_cloudwatch_log_group" "marking" {
  name              = "/aws/lambda/${local.name}-marking"
  retention_in_days = var.log_retention_days
}

resource "aws_lambda_function" "marking" {
  function_name    = "${local.name}-marking"
  role             = local.lambda_role_arn
  runtime          = "nodejs22.x"
  handler          = "marking.handler"
  filename         = data.archive_file.workers.output_path
  source_code_hash = data.archive_file.workers.output_base64sha256
  timeout          = 30
  memory_size      = 256
  environment { variables = local.worker_env }

  vpc_config {
    subnet_ids         = aws_subnet.app[*].id
    security_group_ids = [aws_security_group.lambda.id]
  }
  depends_on = [aws_cloudwatch_log_group.marking]
}

resource "aws_lambda_event_source_mapping" "marking" {
  event_source_arn        = aws_sqs_queue.marking.arn
  function_name           = aws_lambda_function.marking.arn
  batch_size              = 10
  function_response_types = ["ReportBatchItemFailures"]
  scaling_config {
    maximum_concurrency = 5 # caps database connections from marking during the post-exam burst
  }
}

resource "aws_cloudwatch_event_rule" "sweep" {
  name                = "${local.name}-sweep"
  schedule_expression = "rate(5 minutes)"
}

resource "aws_cloudwatch_event_target" "sweep" {
  rule  = aws_cloudwatch_event_rule.sweep.name
  arn   = aws_lambda_function.marking.arn
  input = jsonencode({ source = "sweep" })
}

resource "aws_lambda_permission" "sweep" {
  statement_id  = "AllowEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.marking.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.sweep.arn
}

# --- upload-fn: runs when a file lands in S3 ---
resource "aws_cloudwatch_log_group" "upload" {
  name              = "/aws/lambda/${local.name}-upload"
  retention_in_days = var.log_retention_days
}

resource "aws_lambda_function" "upload" {
  function_name    = "${local.name}-upload"
  role             = local.lambda_role_arn
  runtime          = "nodejs22.x"
  handler          = "upload.handler"
  filename         = data.archive_file.workers.output_path
  source_code_hash = data.archive_file.workers.output_base64sha256
  timeout          = 30
  memory_size      = 256
  environment { variables = local.worker_env }

  vpc_config {
    subnet_ids         = aws_subnet.app[*].id
    security_group_ids = [aws_security_group.lambda.id]
  }
  depends_on = [aws_cloudwatch_log_group.upload]
}

resource "aws_lambda_event_source_mapping" "upload" {
  event_source_arn        = aws_sqs_queue.uploads.arn
  function_name           = aws_lambda_function.upload.arn
  batch_size              = 10
  function_response_types = ["ReportBatchItemFailures"]
  scaling_config {
    maximum_concurrency = 5
  }
}

# --- email-fn: sends mail through SES. No database, so it stays outside the VPC. ---
resource "aws_cloudwatch_log_group" "email" {
  name              = "/aws/lambda/${local.name}-email"
  retention_in_days = var.log_retention_days
}

resource "aws_lambda_function" "email" {
  function_name    = "${local.name}-email"
  role             = local.email_role_arn
  runtime          = "nodejs22.x"
  handler          = "email.handler"
  filename         = data.archive_file.workers.output_path
  source_code_hash = data.archive_file.workers.output_base64sha256
  timeout          = 30
  memory_size      = 128
  environment { variables = local.worker_env }
  depends_on = [aws_cloudwatch_log_group.email]
}

resource "aws_lambda_event_source_mapping" "email" {
  event_source_arn        = aws_sqs_queue.email.arn
  function_name           = aws_lambda_function.email.arn
  batch_size              = 10
  function_response_types = ["ReportBatchItemFailures"]
  scaling_config {
    maximum_concurrency = 2
  }
}
