# Least-privilege roles, one per job: ECS execution, API task, VPC Lambdas, email Lambda, AWS Backup.
# use_lab_role = true is only for AWS Academy accounts, which cannot create IAM roles; every
# service then reuses the account's pre-made LabRole instead.

locals {
  lab_role_arn = "arn:aws:iam::${local.account}:role/LabRole"
  create_roles = var.use_lab_role ? 0 : 1

  exec_role_arn   = coalesce(one(aws_iam_role.exec[*].arn), local.lab_role_arn)
  task_role_arn   = coalesce(one(aws_iam_role.task[*].arn), local.lab_role_arn)
  lambda_role_arn = coalesce(one(aws_iam_role.lambda_db[*].arn), local.lab_role_arn)
  email_role_arn  = coalesce(one(aws_iam_role.lambda_email[*].arn), local.lab_role_arn)
  backup_role_arn = coalesce(one(aws_iam_role.backup[*].arn), local.lab_role_arn)
}

data "aws_iam_policy_document" "assume_ecs" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "assume_lambda" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "assume_backup" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["backup.amazonaws.com"]
    }
  }
}

# ---- ECS execution role: pulls the image, writes logs, injects the DB secret ----
resource "aws_iam_role" "exec" {
  count              = local.create_roles
  name               = "${local.name}-ecs-exec"
  assume_role_policy = data.aws_iam_policy_document.assume_ecs.json
}

resource "aws_iam_role_policy_attachment" "exec_managed" {
  count      = local.create_roles
  role       = aws_iam_role.exec[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

data "aws_iam_policy_document" "exec_secret" {
  statement {
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_secretsmanager_secret.db.arn]
  }
  statement {
    actions   = ["kms:Decrypt"]
    resources = [aws_kms_key.main.arn]
  }
}

resource "aws_iam_role_policy" "exec_secret" {
  count  = local.create_roles
  name   = "read-db-secret"
  role   = aws_iam_role.exec[0].id
  policy = data.aws_iam_policy_document.exec_secret.json
}

# ---- ECS task role: what the API code itself may do ----
resource "aws_iam_role" "task" {
  count              = local.create_roles
  name               = "${local.name}-api-task"
  assume_role_policy = data.aws_iam_policy_document.assume_ecs.json
}

data "aws_iam_policy_document" "task" {
  statement {
    sid       = "UploadsWriteOnly"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.uploads.arn}/submissions/*"]
  }
  statement {
    sid       = "EnqueueWork"
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.marking.arn, aws_sqs_queue.email.arn]
  }
  statement {
    sid = "AdminUserManagement"
    actions = [
      "cognito-idp:AdminCreateUser",
      "cognito-idp:AdminAddUserToGroup",
      "cognito-idp:ListUsers",
    ]
    resources = [aws_cognito_user_pool.main.arn]
  }
}

resource "aws_iam_role_policy" "task" {
  count  = local.create_roles
  name   = "api-permissions"
  role   = aws_iam_role.task[0].id
  policy = data.aws_iam_policy_document.task.json
}

# ---- Lambda (in VPC): marking + upload workers ----
resource "aws_iam_role" "lambda_db" {
  count              = local.create_roles
  name               = "${local.name}-lambda-db"
  assume_role_policy = data.aws_iam_policy_document.assume_lambda.json
}

resource "aws_iam_role_policy_attachment" "lambda_db_vpc" {
  count      = local.create_roles
  role       = aws_iam_role.lambda_db[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

data "aws_iam_policy_document" "lambda_db" {
  statement {
    actions   = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes"]
    resources = [aws_sqs_queue.marking.arn, aws_sqs_queue.uploads.arn]
  }
  statement {
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.email.arn]
  }
  statement {
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_secretsmanager_secret.db.arn]
  }
  statement {
    actions   = ["kms:Decrypt"]
    resources = [aws_kms_key.main.arn]
  }
}

resource "aws_iam_role_policy" "lambda_db" {
  count  = local.create_roles
  name   = "worker-permissions"
  role   = aws_iam_role.lambda_db[0].id
  policy = data.aws_iam_policy_document.lambda_db.json
}

# ---- Lambda (no VPC): email worker ----
resource "aws_iam_role" "lambda_email" {
  count              = local.create_roles
  name               = "${local.name}-lambda-email"
  assume_role_policy = data.aws_iam_policy_document.assume_lambda.json
}

resource "aws_iam_role_policy_attachment" "lambda_email_basic" {
  count      = local.create_roles
  role       = aws_iam_role.lambda_email[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

data "aws_iam_policy_document" "lambda_email" {
  statement {
    actions   = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes"]
    resources = [aws_sqs_queue.email.arn]
  }
  statement {
    actions   = ["ses:SendEmail"]
    resources = [aws_ses_email_identity.sender.arn]
  }

}

resource "aws_iam_role_policy" "lambda_email" {
  count  = local.create_roles
  name   = "email-permissions"
  role   = aws_iam_role.lambda_email[0].id
  policy = data.aws_iam_policy_document.lambda_email.json
}

resource "aws_iam_role" "backup" {
  count              = local.create_roles
  name               = "${local.name}-backup"
  assume_role_policy = data.aws_iam_policy_document.assume_backup.json
}

resource "aws_iam_role_policy_attachment" "backup" {
  count      = local.create_roles
  role       = aws_iam_role.backup[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForBackup"
}
