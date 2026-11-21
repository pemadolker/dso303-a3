locals {
  use_domain  = var.domain_name != ""
  origin_host = "origin.${var.domain_name}" # ALB record, only used with a domain
  origin_port = local.use_domain ? 443 : 80

  # The address students open.
  site_url = local.use_domain ? "https://${var.domain_name}" : "https://${aws_cloudfront_distribution.main.domain_name}"
}

# ---------- WAF (global scope, attached to CloudFront) ----------
resource "aws_wafv2_web_acl" "main" {
  count    = var.enable_waf ? 1 : 0
  provider = aws.use1 # CloudFront web ACLs must live in us-east-1
  name     = "${local.name}-waf"
  scope    = "CLOUDFRONT"

  default_action {
    allow {}
  }

  rule {
    name     = "aws-common"
    priority = 1
    override_action {
      none {}
    }
    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesCommonRuleSet"
        vendor_name = "AWS"
        # The default 8 KB body limit would block autosave requests with long short-answer text.
        rule_action_override {
          name = "SizeRestrictions_BODY"
          action_to_use {
            count {}
          }
        }
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "aws-common"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "aws-bad-inputs"
    priority = 2
    override_action {
      none {}
    }
    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesKnownBadInputsRuleSet"
        vendor_name = "AWS"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "aws-bad-inputs"
      sampled_requests_enabled   = true
    }
  }

  # Flood protection only. The limit is high on purpose: a whole campus shares one public IP,
  # and 3,000 students autosaving is about 30,000 requests per 5 minutes from that single address.
  rule {
    name     = "ip-flood"
    priority = 3
    action {
      block {}
    }
    statement {
      rate_based_statement {
        limit              = 100000
        aggregate_key_type = "IP"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "ip-flood"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${local.name}-waf"
    sampled_requests_enabled   = true
  }
}

# ---------- certificates and DNS (only when domain_name is set) ----------
# Certificate for the viewer side: CloudFront only accepts certificates from us-east-1.
resource "aws_acm_certificate" "site" {
  count             = local.use_domain ? 1 : 0
  provider          = aws.use1
  domain_name       = var.domain_name
  validation_method = "DNS"
  lifecycle {
    create_before_destroy = true
  }
}

# Certificate for the origin side: lives in the ALB's own region, for origin.<domain>.
resource "aws_acm_certificate" "origin" {
  count             = local.use_domain ? 1 : 0
  domain_name       = local.origin_host
  validation_method = "DNS"
  lifecycle {
    create_before_destroy = true
  }
}

locals {
  cert_validation = local.use_domain ? {
    for o in concat(tolist(aws_acm_certificate.site[0].domain_validation_options), tolist(aws_acm_certificate.origin[0].domain_validation_options)) :
    o.domain_name => o
  } : {}
}

resource "aws_route53_record" "cert_validation" {
  for_each        = local.cert_validation
  zone_id         = var.hosted_zone_id
  name            = each.value.resource_record_name
  type            = each.value.resource_record_type
  records         = [each.value.resource_record_value]
  ttl             = 300
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "site" {
  count                   = local.use_domain ? 1 : 0
  provider                = aws.use1
  certificate_arn         = aws_acm_certificate.site[0].arn
  validation_record_fqdns = [for k, r in aws_route53_record.cert_validation : r.fqdn if k == var.domain_name]
}

resource "aws_acm_certificate_validation" "origin" {
  count                   = local.use_domain ? 1 : 0
  certificate_arn         = aws_acm_certificate.origin[0].arn
  validation_record_fqdns = [for k, r in aws_route53_record.cert_validation : r.fqdn if k == local.origin_host]
}

# origin.<domain> -> ALB, so CloudFront can connect over HTTPS with a matching certificate.
resource "aws_route53_record" "origin" {
  count   = local.use_domain ? 1 : 0
  zone_id = var.hosted_zone_id
  name    = local.origin_host
  type    = "A"
  alias {
    name                   = aws_lb.main.dns_name
    zone_id                = aws_lb.main.zone_id
    evaluate_target_health = true
  }
}

# <domain> -> CloudFront (IPv4 and IPv6).
resource "aws_route53_record" "site" {
  for_each = local.use_domain ? toset(["A", "AAAA"]) : toset([])
  zone_id  = var.hosted_zone_id
  name     = var.domain_name
  type     = each.key
  alias {
    name                   = aws_cloudfront_distribution.main.domain_name
    zone_id                = aws_cloudfront_distribution.main.hosted_zone_id
    evaluate_target_health = false
  }
}

# ---------- CloudFront ----------
resource "aws_cloudfront_origin_access_control" "frontend" {
  name                              = "${local.name}-frontend-oac"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_distribution" "main" {
  enabled             = true
  comment             = "${local.name} edge"
  default_root_object = "index.html"
  price_class         = "PriceClass_200" # includes edge locations in India
  http_version        = "http2and3"
  aliases             = local.use_domain ? [var.domain_name] : []
  web_acl_id          = var.enable_waf ? aws_wafv2_web_acl.main[0].arn : null

  # Origin 1: static frontend in a private S3 bucket, readable only through this distribution (OAC)
  origin {
    origin_id                = "frontend"
    domain_name              = aws_s3_bucket.frontend.bucket_regional_domain_name
    origin_access_control_id = aws_cloudfront_origin_access_control.frontend.id
  }

  # Origin 2: the API behind the ALB. HTTPS when a domain (and so a certificate) exists.
  origin {
    origin_id   = "api"
    domain_name = local.use_domain ? local.origin_host : aws_lb.main.dns_name
    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = local.use_domain ? "https-only" : "http-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
    custom_header {
      name  = "X-Origin-Verify"
      value = random_password.origin_verify.result
    }
  }

  default_cache_behavior {
    target_origin_id       = "frontend"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true
    cache_policy_id        = "658327ea-f89d-4fab-a63d-7e88639e58f6" # Managed-CachingOptimized
  }

  ordered_cache_behavior {
    path_pattern             = "/api/*"
    target_origin_id         = "api"
    viewer_protocol_policy   = "https-only"
    allowed_methods          = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods           = ["GET", "HEAD"]
    compress                 = true
    cache_policy_id          = "4135ea2d-6df8-44a3-9df3-4b5a84be39ad" # Managed-CachingDisabled
    origin_request_policy_id = "b689b0a8-53d0-40ab-baf2-68738e2966ac" # Managed-AllViewerExceptHostHeader (forwards Authorization)
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = !local.use_domain
    acm_certificate_arn            = local.use_domain ? aws_acm_certificate_validation.site[0].certificate_arn : null
    ssl_support_method             = local.use_domain ? "sni-only" : null
    minimum_protocol_version       = local.use_domain ? "TLSv1.2_2021" : null
  }
}

# Only this distribution may read the frontend bucket; plain HTTP is refused.
data "aws_iam_policy_document" "frontend" {
  statement {
    sid       = "AllowCloudFrontOAC"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.frontend.arn}/*"]
    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.main.arn]
    }
  }
  statement {
    sid       = "DenyNonTLS"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.frontend.arn, "${aws_s3_bucket.frontend.arn}/*"]
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

resource "aws_s3_bucket_policy" "frontend" {
  bucket = aws_s3_bucket.frontend.id
  policy = data.aws_iam_policy_document.frontend.json
}
