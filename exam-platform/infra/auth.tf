resource "aws_cognito_user_pool" "main" {
  name                     = "${local.name}-users"
  username_attributes      = ["email"]
  auto_verified_attributes = ["email"]
  mfa_configuration        = "OPTIONAL"

  admin_create_user_config {
    allow_admin_create_user_only = true # no self sign-up: admins create accounts
  }

  password_policy {
    minimum_length                   = 12
    require_lowercase                = true
    require_uppercase                = true
    require_numbers                  = true
    require_symbols                  = false
    temporary_password_validity_days = 7
  }

  software_token_mfa_configuration {
    enabled = true
  }

  account_recovery_setting {
    recovery_mechanism {
      name     = "verified_email"
      priority = 1
    }
  }
}

# The group names are the roles. They end up in the token as cognito:groups.
resource "aws_cognito_user_group" "roles" {
  for_each     = toset(["student", "tutor", "admin"])
  name         = each.key
  user_pool_id = aws_cognito_user_pool.main.id
}

resource "aws_cognito_user_pool_client" "web" {
  name            = "${local.name}-web"
  user_pool_id    = aws_cognito_user_pool.main.id
  generate_secret = false # browser app cannot keep a secret

  explicit_auth_flows = [
    "ALLOW_USER_PASSWORD_AUTH",
    "ALLOW_USER_SRP_AUTH",
    "ALLOW_REFRESH_TOKEN_AUTH",
  ]

  id_token_validity      = 60
  access_token_validity  = 60
  refresh_token_validity = 8
  token_validity_units {
    id_token      = "minutes"
    access_token  = "minutes"
    refresh_token = "hours"
  }

  prevent_user_existence_errors = "ENABLED"
}
