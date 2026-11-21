locals {
  alarm_actions = [aws_sns_topic.alarms.arn]
  alb_dim       = { LoadBalancer = aws_lb.main.arn_suffix }
  tg_dim        = { LoadBalancer = aws_lb.main.arn_suffix, TargetGroup = aws_lb_target_group.api.arn_suffix }
}

resource "aws_cloudwatch_metric_alarm" "alb_5xx" {
  alarm_name          = "${local.name}-api-5xx"
  alarm_description   = "API returning server errors"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "HTTPCode_Target_5XX_Count"
  dimensions          = local.alb_dim
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 2
  threshold           = 20
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
}

resource "aws_cloudwatch_metric_alarm" "alb_latency" {
  alarm_name          = "${local.name}-api-latency-p95"
  alarm_description   = "p95 response time above 1 second"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "TargetResponseTime"
  dimensions          = local.alb_dim
  extended_statistic  = "p95"
  period              = 60
  evaluation_periods  = 3
  threshold           = 1
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
}

resource "aws_cloudwatch_metric_alarm" "unhealthy_hosts" {
  alarm_name          = "${local.name}-unhealthy-targets"
  alarm_description   = "At least one API task failing health checks (fires during an AZ loss)"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "UnHealthyHostCount"
  dimensions          = local.tg_dim
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 2
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
}

resource "aws_cloudwatch_metric_alarm" "ecs_cpu" {
  alarm_name          = "${local.name}-ecs-cpu-high"
  namespace           = "AWS/ECS"
  metric_name         = "CPUUtilization"
  dimensions          = { ClusterName = aws_ecs_cluster.main.name, ServiceName = aws_ecs_service.api.name }
  statistic           = "Average"
  period              = 60
  evaluation_periods  = 5
  threshold           = 85
  comparison_operator = "GreaterThanThreshold"
  alarm_actions       = local.alarm_actions
}

resource "aws_cloudwatch_metric_alarm" "rds_cpu" {
  alarm_name          = "${local.name}-rds-cpu-high"
  namespace           = "AWS/RDS"
  metric_name         = "CPUUtilization"
  dimensions          = { DBInstanceIdentifier = aws_db_instance.main.identifier }
  statistic           = "Average"
  period              = 60
  evaluation_periods  = 5
  threshold           = 80
  comparison_operator = "GreaterThanThreshold"
  alarm_actions       = local.alarm_actions
}

resource "aws_cloudwatch_metric_alarm" "rds_connections" {
  alarm_name          = "${local.name}-rds-connections-high"
  alarm_description   = "Connection count close to the instance limit"
  namespace           = "AWS/RDS"
  metric_name         = "DatabaseConnections"
  dimensions          = { DBInstanceIdentifier = aws_db_instance.main.identifier }
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 3
  threshold           = 60
  comparison_operator = "GreaterThanThreshold"
  alarm_actions       = local.alarm_actions
}

resource "aws_cloudwatch_metric_alarm" "dlq" {
  for_each            = aws_sqs_queue.dlq
  alarm_name          = "${local.name}-${each.key}-dlq-not-empty"
  alarm_description   = "A message failed 3 times and was parked in the dead-letter queue"
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  dimensions          = { QueueName = each.value.name }
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
}

resource "aws_cloudwatch_metric_alarm" "marking_backlog" {
  alarm_name          = "${local.name}-marking-backlog"
  alarm_description   = "Marking queue is not draining"
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateAgeOfOldestMessage"
  dimensions          = { QueueName = aws_sqs_queue.marking.name }
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 5
  threshold           = 300
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
}

resource "aws_cloudwatch_dashboard" "main" {
  dashboard_name = local.name
  dashboard_body = jsonencode({
    widgets = [
      {
        type = "metric", x = 0, y = 0, width = 12, height = 6
        properties = {
          title  = "API requests and errors"
          region = var.region
          stat   = "Sum"
          period = 60
          metrics = [
            ["AWS/ApplicationELB", "RequestCount", "LoadBalancer", aws_lb.main.arn_suffix],
            [".", "HTTPCode_Target_5XX_Count", ".", "."],
          ]
        }
      },
      {
        type = "metric", x = 12, y = 0, width = 12, height = 6
        properties = {
          title  = "Healthy vs unhealthy targets (watch this during the AZ test)"
          region = var.region
          stat   = "Maximum"
          period = 60
          metrics = [
            ["AWS/ApplicationELB", "HealthyHostCount", "LoadBalancer", aws_lb.main.arn_suffix, "TargetGroup", aws_lb_target_group.api.arn_suffix],
            [".", "UnHealthyHostCount", ".", ".", ".", "."],
          ]
        }
      },
      {
        type = "metric", x = 0, y = 6, width = 12, height = 6
        properties = {
          title  = "ECS CPU and running tasks"
          region = var.region
          period = 60
          metrics = [
            ["AWS/ECS", "CPUUtilization", "ClusterName", aws_ecs_cluster.main.name, "ServiceName", aws_ecs_service.api.name, { stat = "Average" }],
            ["ECS/ContainerInsights", "RunningTaskCount", "ClusterName", aws_ecs_cluster.main.name, "ServiceName", aws_ecs_service.api.name, { stat = "Average", yAxis = "right" }],
          ]
        }
      },
      {
        type = "metric", x = 12, y = 6, width = 12, height = 6
        properties = {
          title  = "Database CPU and connections"
          region = var.region
          period = 60
          metrics = [
            ["AWS/RDS", "CPUUtilization", "DBInstanceIdentifier", aws_db_instance.main.identifier, { stat = "Average" }],
            [".", "DatabaseConnections", ".", ".", { stat = "Maximum", yAxis = "right" }],
          ]
        }
      },
      {
        type = "metric", x = 0, y = 12, width = 12, height = 6
        properties = {
          title  = "Queues: oldest message age"
          region = var.region
          stat   = "Maximum"
          period = 60
          metrics = [
            ["AWS/SQS", "ApproximateAgeOfOldestMessage", "QueueName", aws_sqs_queue.marking.name],
            ["...", aws_sqs_queue.uploads.name],
            ["...", aws_sqs_queue.email.name],
          ]
        }
      },
      {
        type = "metric", x = 12, y = 12, width = 12, height = 6
        properties = {
          title  = "Worker errors"
          region = var.region
          stat   = "Sum"
          period = 60
          metrics = [
            ["AWS/Lambda", "Errors", "FunctionName", aws_lambda_function.marking.function_name],
            ["...", aws_lambda_function.upload.function_name],
            ["...", aws_lambda_function.email.function_name],
          ]
        }
      },
    ]
  })
}
