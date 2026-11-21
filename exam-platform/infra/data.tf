# ---------- encryption key (RDS storage + Secrets Manager) ----------
resource "aws_kms_key" "main" {
  description             = "${local.name} data key"
  enable_key_rotation     = true
  deletion_window_in_days = 7
}

resource "aws_kms_alias" "main" {
  name          = "alias/${local.name}"
  target_key_id = aws_kms_key.main.key_id
}

# ---------- database: PostgreSQL, Multi-AZ, private data subnets ----------
resource "random_password" "db" {
  length  = 32
  special = false # keeps the connection string simple
}

resource "aws_db_subnet_group" "main" {
  name       = "${local.name}-db-subnets"
  subnet_ids = aws_subnet.data[*].id
}

resource "aws_db_parameter_group" "pg" {
  name   = "${local.name}-pg16"
  family = "postgres16"

  parameter {
    name  = "rds.force_ssl" # reject any non-TLS connection
    value = "1"
  }
}

resource "aws_db_instance" "main" {
  identifier     = "${local.name}-db"
  engine         = "postgres"
  engine_version = "16"
  instance_class = var.db_instance_class

  allocated_storage     = var.db_allocated_storage
  max_allocated_storage = var.db_allocated_storage * 5
  storage_type          = "gp3"
  storage_encrypted     = true
  kms_key_id            = aws_kms_key.main.arn

  db_name  = "exams"
  username = "examadmin"
  password = random_password.db.result

  multi_az               = true # synchronous standby in the other AZ, automatic failover
  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.db.id]
  publicly_accessible    = false
  parameter_group_name   = aws_db_parameter_group.pg.name

  backup_retention_period         = var.db_backup_retention_days # enables point-in-time restore (logs shipped about every 5 min)
  backup_window                   = "20:00-21:00"                # UTC, 02:00 Bhutan time
  maintenance_window              = "sun:21:00-sun:22:00"
  copy_tags_to_snapshot           = true
  auto_minor_version_upgrade      = true
  deletion_protection             = var.protect_data
  skip_final_snapshot             = !var.protect_data
  final_snapshot_identifier       = "${local.name}-final"
  enabled_cloudwatch_logs_exports = ["postgresql", "upgrade"]
}

# ---------- secrets ----------
resource "aws_secretsmanager_secret" "db" {
  name                    = "${local.name}/db"
  kms_key_id              = aws_kms_key.main.arn
  recovery_window_in_days = var.protect_data ? 7 : 0 # 0 lets a torn-down stack be rebuilt with the same name
}

resource "aws_secretsmanager_secret_version" "db" {
  secret_id = aws_secretsmanager_secret.db.id
  secret_string = jsonencode({
    username = aws_db_instance.main.username
    password = random_password.db.result
    host     = aws_db_instance.main.address
    port     = 5432
    dbname   = aws_db_instance.main.db_name
  })
}

# Shared secret that CloudFront adds to every request so the ALB can reject anything that did not come through the edge.
resource "random_password" "origin_verify" {
  length  = 40
  special = false
}

# ---------- file storage ----------
# protect_data = true (default): a bucket that still holds files refuses to be deleted.
resource "aws_s3_bucket" "uploads" {
  bucket        = "${local.name}-uploads-${local.account}"
  force_destroy = !var.protect_data
}

resource "aws_s3_bucket" "frontend" {
  bucket        = "${local.name}-frontend-${local.account}"
  force_destroy = true # only build output lives here; it is republished on every deploy
}

resource "aws_s3_bucket_public_access_block" "uploads" {
  bucket                  = aws_s3_bucket.uploads.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "uploads" {
  bucket = aws_s3_bucket.uploads.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_versioning" "uploads" {
  bucket = aws_s3_bucket.uploads.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "uploads" {
  bucket     = aws_s3_bucket.uploads.id
  depends_on = [aws_s3_bucket_versioning.uploads]

  rule {
    id     = "age-out-submissions"
    status = "Enabled"
    filter {
      prefix = "submissions/"
    }
    transition {
      days          = 30
      storage_class = "STANDARD_IA"
    }
    transition {
      days          = 365
      storage_class = "GLACIER"
    }
    expiration {
      days = var.records_retention_days
    }
    noncurrent_version_expiration {
      noncurrent_days = 90
    }
  }

  rule {
    id     = "abort-broken-uploads"
    status = "Enabled"
    filter {}
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

resource "aws_s3_bucket_cors_configuration" "uploads" {
  bucket = aws_s3_bucket.uploads.id
  cors_rule {
    allowed_methods = ["POST"]
    allowed_origins = [local.site_url]
    allowed_headers = ["*"]
    max_age_seconds = 3000
  }
}

data "aws_iam_policy_document" "uploads_tls" {
  statement {
    sid       = "DenyNonTLS"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.uploads.arn, "${aws_s3_bucket.uploads.arn}/*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "uploads" {
  bucket = aws_s3_bucket.uploads.id
  policy = data.aws_iam_policy_document.uploads_tls.json
}

# S3 -> SQS: every new object in submissions/ becomes a message for the upload worker.
resource "aws_s3_bucket_notification" "uploads" {
  bucket = aws_s3_bucket.uploads.id
  queue {
    queue_arn     = aws_sqs_queue.uploads.arn
    events        = ["s3:ObjectCreated:*"]
    filter_prefix = "submissions/"
  }
  depends_on = [aws_sqs_queue_policy.uploads]
}

resource "aws_s3_bucket_public_access_block" "frontend" {
  bucket                  = aws_s3_bucket.frontend.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "frontend" {
  bucket = aws_s3_bucket.frontend.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# ---------- optional: 5-year backup copy of the database ----------
resource "aws_backup_vault" "main" {
  count = var.enable_backup_plan ? 1 : 0
  name  = "${local.name}-vault"
}

resource "aws_backup_plan" "main" {
  count = var.enable_backup_plan ? 1 : 0
  name  = "${local.name}-monthly-5y"
  rule {
    rule_name         = "monthly"
    target_vault_name = aws_backup_vault.main[0].name
    schedule          = "cron(0 18 1 * ? *)"
    lifecycle {
      delete_after = var.records_retention_days
    }
  }
}

resource "aws_backup_selection" "main" {
  count        = var.enable_backup_plan ? 1 : 0
  name         = "rds"
  plan_id      = aws_backup_plan.main[0].id
  iam_role_arn = local.backup_role_arn
  resources    = [aws_db_instance.main.arn]
}
