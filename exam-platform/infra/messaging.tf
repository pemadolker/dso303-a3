# Three queues, each with a dead-letter queue (DLQ) that catches messages that fail 3 times.
#   marking : API -> marking-fn   (auto-mark MCQ after submit)
#   uploads : S3  -> upload-fn    (record file, ask for tutor email)
#   email   : API/upload-fn -> email-fn (SES)

resource "aws_sqs_queue" "dlq" {
  for_each                  = toset(["marking", "uploads", "email"])
  name                      = "${local.name}-${each.key}-dlq"
  message_retention_seconds = 1209600 # 14 days
  sqs_managed_sse_enabled   = true
}

resource "aws_sqs_queue" "marking" {
  name                       = "${local.name}-marking"
  visibility_timeout_seconds = 180 # 6x the worker timeout
  sqs_managed_sse_enabled    = true
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq["marking"].arn
    maxReceiveCount     = 3
  })
}

resource "aws_sqs_queue" "uploads" {
  name                       = "${local.name}-uploads"
  visibility_timeout_seconds = 180
  sqs_managed_sse_enabled    = true
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq["uploads"].arn
    maxReceiveCount     = 3
  })
}

resource "aws_sqs_queue" "email" {
  name                       = "${local.name}-email"
  visibility_timeout_seconds = 180
  sqs_managed_sse_enabled    = true
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq["email"].arn
    maxReceiveCount     = 3
  })
}

# Lets the uploads bucket (and only that bucket) put messages on the uploads queue.
data "aws_iam_policy_document" "uploads_queue" {
  statement {
    effect    = "Allow"
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.uploads.arn]
    principals {
      type        = "Service"
      identifiers = ["s3.amazonaws.com"]
    }
    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [aws_s3_bucket.uploads.arn]
    }
  }
}

resource "aws_sqs_queue_policy" "uploads" {
  queue_url = aws_sqs_queue.uploads.id
  policy    = data.aws_iam_policy_document.uploads_queue.json
}

resource "aws_ses_email_identity" "sender" {
  email = var.ses_sender_email
}

resource "aws_sns_topic" "alarms" {
  name = "${local.name}-alarms"
}

resource "aws_sns_topic_subscription" "alarm_email" {
  count     = var.alarm_email == "" ? 0 : 1
  topic_arn = aws_sns_topic.alarms.arn
  protocol  = "email"
  endpoint  = var.alarm_email
}
