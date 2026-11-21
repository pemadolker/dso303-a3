variable "project" {
  type    = string
  default = "exam-platform"
}

variable "region" {
  description = "Mumbai is the closest AWS region to Bhutan. CloudFront certificates and the CloudFront WAF are always created in us-east-1 (AWS requirement)."
  type        = string
  default     = "ap-south-1"
}

variable "domain_name" {
  description = "Site domain, e.g. exams.cst.edu.bt. When set, ACM certificates are issued and HTTPS is used end to end (browser to CloudFront and CloudFront to ALB). Leave empty to use the CloudFront default domain."
  type        = string
  default     = ""
}

variable "hosted_zone_id" {
  description = "Route 53 hosted zone for domain_name (needed for certificate validation and DNS records)."
  type        = string
  default     = ""
}

variable "use_lab_role" {
  description = "Only for AWS Academy accounts, which cannot create IAM roles: reuse the pre-made LabRole. Normal accounts keep false and get least-privilege roles."
  type        = bool
  default     = false
}

variable "image_tag" {
  description = "Tag of the API image in ECR. CI sets this to the git commit SHA."
  type        = string
  default     = "latest"
}

variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

# ---------- capacity ----------
variable "api_cpu" {
  type    = number
  default = 512
}

variable "api_memory" {
  type    = number
  default = 1024
}

variable "api_min_tasks" {
  description = "Normal-day floor. Must be an even number so both AZs always hold tasks."
  type        = number
  default     = 2
}

variable "api_max_tasks" {
  type    = number
  default = 12
}

variable "exam_min_tasks" {
  description = "Floor during the exam window (scheduled scaling), so capacity is ready before 3,000 students arrive."
  type        = number
  default     = 6
}

variable "exam_window_start_cron" {
  description = "UTC cron. Default is 02:30 UTC = 08:30 in Bhutan (UTC+6), Mon-Fri."
  type        = string
  default     = "cron(30 2 ? * MON-FRI *)"
}

variable "exam_window_end_cron" {
  description = "UTC cron. Default is 08:00 UTC = 14:00 in Bhutan, Mon-Fri."
  type        = string
  default     = "cron(0 8 ? * MON-FRI *)"
}

variable "db_instance_class" {
  description = "Small default so a test deployment stays cheap. Sized for production: db.m6g.large (see docs/services.md)."
  type        = string
  default     = "db.t3.micro"
}

variable "db_allocated_storage" {
  type    = number
  default = 20
}

variable "db_backup_retention_days" {
  type    = number
  default = 7
}

# ---------- optional features ----------
variable "enable_waf" {
  type    = bool
  default = true
}

variable "enable_backup_plan" {
  description = "AWS Backup monthly copy of the database, kept for records_retention_days (5 years)."
  type        = bool
  default     = true
}

variable "protect_data" {
  description = "true = RDS deletion protection on and S3 buckets refuse to delete while they hold files. scripts/destroy.sh switches this off first, on purpose."
  type        = bool
  default     = true
}

# ---------- email ----------
variable "ses_sender_email" {
  description = "Sender address for result and submission emails. SES sends a verification link to it; while the account is in the SES sandbox, recipients must be verified too."
  type        = string
}

variable "alarm_email" {
  description = "Where CloudWatch alarms are sent. Leave empty to skip the subscription."
  type        = string
  default     = ""
}

variable "log_retention_days" {
  type    = number
  default = 30
}

variable "records_retention_days" {
  description = "Uploaded assignment files are deleted after this many days. 5 years = 1826."
  type        = number
  default     = 1826
}
