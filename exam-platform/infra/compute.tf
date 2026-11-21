# ---------- container registry ----------
resource "aws_ecr_repository" "api" {
  name                 = "${local.name}-api"
  image_tag_mutability = "MUTABLE"
  force_delete         = true # coursework: lets terraform destroy remove images too

  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_ecr_lifecycle_policy" "api" {
  repository = aws_ecr_repository.api.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "keep the last 10 images"
      selection    = { tagStatus = "any", countType = "imageCountMoreThan", countNumber = 10 }
      action       = { type = "expire" }
    }]
  })
}

# ---------- load balancer (public subnets, both AZs) ----------
resource "aws_lb" "main" {
  name                       = "${local.name}-alb"
  load_balancer_type         = "application"
  internal                   = false
  subnets                    = aws_subnet.public[*].id
  security_groups            = [aws_security_group.alb.id]
  drop_invalid_header_fields = true
  idle_timeout               = 60
}

resource "aws_lb_target_group" "api" {
  name                          = "${local.name}-api-tg"
  port                          = 3000
  protocol                      = "HTTP"
  target_type                   = "ip"
  vpc_id                        = aws_vpc.main.id
  deregistration_delay          = 30
  load_balancing_algorithm_type = "least_outstanding_requests"

  health_check {
    path                = "/health"
    matcher             = "200"
    interval            = 10
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }
}

# One listener: HTTPS on 443 with the origin certificate when a domain is set, otherwise HTTP on 80.
# Either way anything without the CloudFront secret header gets a 403.
resource "aws_lb_listener" "main" {
  load_balancer_arn = aws_lb.main.arn
  port              = local.origin_port
  protocol          = local.use_domain ? "HTTPS" : "HTTP"
  ssl_policy        = local.use_domain ? "ELBSecurityPolicy-TLS13-1-2-2021-06" : null
  certificate_arn   = local.use_domain ? aws_acm_certificate_validation.origin[0].certificate_arn : null

  default_action {
    type = "fixed-response"
    fixed_response {
      content_type = "text/plain"
      message_body = "forbidden"
      status_code  = "403"
    }
  }
}

resource "aws_lb_listener_rule" "from_cloudfront" {
  listener_arn = aws_lb_listener.main.arn
  priority     = 1

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.api.arn
  }

  condition {
    http_header {
      http_header_name = "X-Origin-Verify"
      values           = [random_password.origin_verify.result]
    }
  }
}

# ---------- ECS on Fargate ----------
resource "aws_ecs_cluster" "main" {
  name = "${local.name}-cluster"
  setting {
    name  = "containerInsights"
    value = "enabled"
  }
}

resource "aws_cloudwatch_log_group" "api" {
  name              = "/ecs/${local.name}-api"
  retention_in_days = var.log_retention_days
}

resource "aws_ecs_task_definition" "api" {
  family                   = "${local.name}-api"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.api_cpu
  memory                   = var.api_memory
  execution_role_arn       = local.exec_role_arn
  task_role_arn            = local.task_role_arn

  container_definitions = jsonencode([{
    name         = "api"
    image        = "${aws_ecr_repository.api.repository_url}:${var.image_tag}"
    essential    = true
    portMappings = [{ containerPort = 3000, protocol = "tcp" }]

    environment = [
      { name = "NODE_ENV", value = "production" },
      { name = "AWS_REGION", value = var.region },
      { name = "DB_HOST", value = aws_db_instance.main.address },
      { name = "DB_PORT", value = "5432" },
      { name = "DB_NAME", value = aws_db_instance.main.db_name },
      { name = "UPLOAD_BUCKET", value = aws_s3_bucket.uploads.id },
      { name = "MARKING_QUEUE_URL", value = aws_sqs_queue.marking.url },
      { name = "EMAIL_QUEUE_URL", value = aws_sqs_queue.email.url },
      { name = "USER_POOL_ID", value = aws_cognito_user_pool.main.id },
      { name = "CLIENT_ID", value = aws_cognito_user_pool_client.web.id },
      { name = "DB_POOL_MAX", value = "5" },
    ]

    # Injected by ECS from Secrets Manager at start-up; never written into the image or task definition.
    secrets = [
      { name = "DB_USER", valueFrom = "${aws_secretsmanager_secret.db.arn}:username::" },
      { name = "DB_PASSWORD", valueFrom = "${aws_secretsmanager_secret.db.arn}:password::" },
    ]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.api.name
        "awslogs-region"        = var.region
        "awslogs-stream-prefix" = "api"
      }
    }
  }])

  depends_on = [aws_secretsmanager_secret_version.db]
}

resource "aws_ecs_service" "api" {
  name            = "${local.name}-api"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.api.arn
  desired_count   = var.api_min_tasks
  launch_type     = "FARGATE"

  # Keeps the task count balanced across both AZs, including re-balancing after an AZ comes back.
  availability_zone_rebalancing = "ENABLED"

  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200
  health_check_grace_period_seconds  = 60

  deployment_circuit_breaker {
    enable   = true
    rollback = true # a bad deploy rolls itself back
  }

  network_configuration {
    subnets          = aws_subnet.app[*].id
    security_groups  = [aws_security_group.app.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.api.arn
    container_name   = "api"
    container_port   = 3000
  }

  lifecycle {
    ignore_changes = [desired_count] # autoscaling owns this
  }

  depends_on = [aws_lb_listener_rule.from_cloudfront]
}

# ---------- autoscaling ----------
resource "aws_appautoscaling_target" "api" {
  service_namespace  = "ecs"
  resource_id        = "service/${aws_ecs_cluster.main.name}/${aws_ecs_service.api.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  min_capacity       = var.api_min_tasks
  max_capacity       = var.api_max_tasks
}

resource "aws_appautoscaling_policy" "cpu" {
  name               = "${local.name}-cpu"
  policy_type        = "TargetTrackingScaling"
  service_namespace  = aws_appautoscaling_target.api.service_namespace
  resource_id        = aws_appautoscaling_target.api.resource_id
  scalable_dimension = aws_appautoscaling_target.api.scalable_dimension

  target_tracking_scaling_policy_configuration {
    target_value       = 50
    scale_out_cooldown = 30
    scale_in_cooldown  = 300
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
  }
}

resource "aws_appautoscaling_policy" "requests" {
  name               = "${local.name}-requests"
  policy_type        = "TargetTrackingScaling"
  service_namespace  = aws_appautoscaling_target.api.service_namespace
  resource_id        = aws_appautoscaling_target.api.resource_id
  scalable_dimension = aws_appautoscaling_target.api.scalable_dimension

  target_tracking_scaling_policy_configuration {
    target_value       = 3000 # requests per task per minute (about 50 per second)
    scale_out_cooldown = 30
    scale_in_cooldown  = 300
    predefined_metric_specification {
      predefined_metric_type = "ALBRequestCountPerTarget"
      resource_label         = "${aws_lb.main.arn_suffix}/${aws_lb_target_group.api.arn_suffix}"
    }
  }
}

# Pre-warm: raise the floor before the exam window so capacity already exists when students arrive.
resource "aws_appautoscaling_scheduled_action" "exam_start" {
  name               = "${local.name}-exam-window-start"
  service_namespace  = aws_appautoscaling_target.api.service_namespace
  resource_id        = aws_appautoscaling_target.api.resource_id
  scalable_dimension = aws_appautoscaling_target.api.scalable_dimension
  schedule           = var.exam_window_start_cron
  timezone           = "UTC"

  scalable_target_action {
    min_capacity = var.exam_min_tasks
    max_capacity = var.api_max_tasks
  }
}

resource "aws_appautoscaling_scheduled_action" "exam_end" {
  name               = "${local.name}-exam-window-end"
  service_namespace  = aws_appautoscaling_target.api.service_namespace
  resource_id        = aws_appautoscaling_target.api.resource_id
  scalable_dimension = aws_appautoscaling_target.api.scalable_dimension
  schedule           = var.exam_window_end_cron
  timezone           = "UTC"

  scalable_target_action {
    min_capacity = var.api_min_tasks
    max_capacity = var.api_max_tasks
  }
}
