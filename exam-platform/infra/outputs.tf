output "site_url" {
  value = local.site_url
}

output "region" {
  value = var.region
}

output "cloudfront_distribution_id" {
  value = aws_cloudfront_distribution.main.id
}

output "frontend_bucket" {
  value = aws_s3_bucket.frontend.id
}

output "uploads_bucket" {
  value = aws_s3_bucket.uploads.id
}

output "ecr_repository_url" {
  value = aws_ecr_repository.api.repository_url
}

output "ecs_cluster" {
  value = aws_ecs_cluster.main.name
}

output "ecs_service" {
  value = aws_ecs_service.api.name
}

output "user_pool_id" {
  value = aws_cognito_user_pool.main.id
}

output "user_pool_client_id" {
  value = aws_cognito_user_pool_client.web.id
}

output "db_identifier" {
  value = aws_db_instance.main.identifier
}

output "vpc_id" {
  value = aws_vpc.main.id
}

output "alb_dns_name" {
  value = aws_lb.main.dns_name
}

output "dashboard_name" {
  value = aws_cloudwatch_dashboard.main.dashboard_name
}

output "target_group_arn" {
  value = aws_lb_target_group.api.arn
}

output "uploads_queue_url" {
  value = aws_sqs_queue.uploads.url
}
