"""Builds exam-platform-lab.json, the workspace file for the Cloud Architecture Lab simulator.

Run:  python3 build_lab_json.py
Then in the simulator: Export -> Upload JSON -> pick exam-platform-lab.json.

The layout mirrors architecture/architecture.png: a region with a VPC across two AZs,
each AZ split into public, private app and private data subnets. Global edge services sit on
the left, regional managed services on the right.
"""
import json
from datetime import datetime, timezone

CATEGORY = {
    "user": "Client / Ingress", "route53": "Networking & Content Delivery",
    "cloudfront": "Networking & Content Delivery", "waf": "Security, Identity & Compliance",
    "internet_gateway": "Networking & Content Delivery", "alb": "Networking & Content Delivery",
    "nat_gateway": "Networking & Content Delivery", "ecs": "Compute", "lambda": "Compute",
    "rds": "Databases", "s3": "Storage", "s3_gateway_endpoint": "Networking & Content Delivery",
    "sqs": "Integration & Messaging", "sqs_dlq": "Integration & Messaging",
    "ses": "Business Applications", "sns": "Integration & Messaging",
    "cognito": "Security, Identity & Compliance", "secrets_manager": "Security, Identity & Compliance",
    "kms": "Security, Identity & Compliance", "cloudwatch": "Management & Governance",
    "ecr_registry": "Containers", "eventbridge": "Integration & Messaging",
    "github": "Third-Party & External", "backup": "Storage",
}

nodes, edges = [], []

ACCOUNT = "111122223333"  # example account id used in AWS documentation
REGION = "ap-south-1"
ARN = {
    "s3-uploads": "arn:aws:s3:::exam-platform-uploads",
    "s3-frontend": "arn:aws:s3:::exam-platform-frontend",
    "sqs-marking": f"arn:aws:sqs:{REGION}:{ACCOUNT}:exam-platform-marking",
    "sqs-uploads": f"arn:aws:sqs:{REGION}:{ACCOUNT}:exam-platform-uploads",
    "sqs-email": f"arn:aws:sqs:{REGION}:{ACCOUNT}:exam-platform-email",
    "dlq": f"arn:aws:sqs:{REGION}:{ACCOUNT}:exam-platform-dlq",
    "secrets": f"arn:aws:secretsmanager:{REGION}:{ACCOUNT}:secret:exam-platform/db",
    "kms": f"arn:aws:kms:{REGION}:{ACCOUNT}:key/exam-platform",
    "sns-alarms": f"arn:aws:sns:{REGION}:{ACCOUNT}:exam-platform-alarms",
}


def role(name, service, *statements):
    """IAM role in the simulator's format: trust policy + one identity policy."""
    return {"id": name,
            "trustPolicy": {"id": f"{name}-trust", "kind": "trust", "statements": [
                {"effect": "Allow", "actions": ["sts:AssumeRole"], "resources": [], "principals": [service]}]},
            "identityPolicies": [{"id": f"{name}-permissions", "kind": "identity", "statements": [
                {"effect": "Allow", "actions": a, "resources": r} for a, r in statements]}]}


CONSUME = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes"]
API_TASK_ROLE = role("exam-platform-api-task", "ecs-tasks.amazonaws.com",
                     (["sqs:SendMessage"], [ARN["sqs-marking"], ARN["sqs-email"]]),
                     (["s3:PutObject"], [ARN["s3-uploads"] + "/submissions/*"]))
LAMBDA_DB_ROLE = role("exam-platform-lambda-db", "lambda.amazonaws.com",
                      (CONSUME, [ARN["sqs-marking"], ARN["sqs-uploads"]]),
                      (["sqs:SendMessage"], [ARN["sqs-email"]]),
                      (["secretsmanager:GetSecretValue"], [ARN["secrets"]]),
                      (["kms:Decrypt"], [ARN["kms"]]))
LAMBDA_EMAIL_ROLE = role("exam-platform-lambda-email", "lambda.amazonaws.com",
                         (CONSUME, [ARN["sqs-email"]]),
                         (["ses:SendEmail"], ["*"]))
QUEUE = {"visibilityTimeoutSeconds": 180, "messageRetentionSeconds": 345600,
         "redrivePolicy": {"deadLetterTargetId": "dlq", "maxReceiveCount": 3}}
LAMBDA = {"timeoutSeconds": 30}


def box(id, label, kind, x, y, w, h, z, cidr=None):
    data = {"label": label, "boundaryType": kind, "width": w, "height": h}
    if cidr:
        data["cidr"] = cidr
    nodes.append({"id": id, "type": "boundaryNode", "position": {"x": x, "y": y}, "data": data,
                  "style": {"width": w, "height": h}, "draggable": True, "selectable": True, "zIndex": z})


def svc(id, service, label, x, y, az="Multi-AZ", subnet="global", replicas=1, multi_az=True, notes=None, **extra):
    data = {"serviceId": service, "label": label, "category": CATEGORY[service], "health": "healthy",
            "az": az, "subnet": subnet, "replicas": replicas, "multiAz": multi_az}
    if notes:
        data["notes"] = notes
    config = dict(extra.pop("config", {}))
    if id in ARN:
        config["resourceArn"] = ARN[id]
    if config:
        data["customConfig"] = config
    data.update(extra)
    nodes.append({"id": id, "type": "serviceNode", "position": {"x": x, "y": y}, "data": data})


def link(id, src, dst, protocol, step=None, mode="synchronous", critical=True, timeout=3000, label=None,
         dependency=False, manages=False):
    data = {"protocol": protocol, "interactionType": mode, "isCriticalDependency": critical, "timeoutMs": timeout}
    if step is not None:
        data["stepNumber"] = step
    if label:
        data["label"] = label
    if dependency:
        data["traversal"] = "dependency"
        data["relationship"] = "dependency"
    if manages:
        data["relationship"] = "manages"
    edges.append({"id": id, "source": src, "target": dst, "type": "custom", "data": data})


# ---------------- boundaries ----------------
box("box-region", "AWS Region ap-south-1 (Mumbai)", "region", 440, 20, 1620, 1360, -4)
box("box-vpc", "VPC 10.0.0.0/16", "vpc", 470, 210, 1060, 1140, -3, cidr="10.0.0.0/16")
box("box-az-a", "Availability Zone A (ap-south-1a)", "az", 490, 300, 500, 1030, -2)
box("box-az-b", "Availability Zone B (ap-south-1b)", "az", 1010, 300, 500, 1030, -2)
for side, x in (("a", 510), ("b", 1030)):
    # The simulator splits the VPC CIDR evenly by itself (six /19s), so the Terraform /24s are not shown here.
    box(f"box-public-{side}", f"Public subnet {side.upper()}", "public_subnet", x, 340, 460, 210, 0)
    box(f"box-app-{side}", f"Private app subnet {side.upper()}", "private_subnet", x, 590, 460, 320, 0)
    box(f"box-data-{side}", f"Private data subnet {side.upper()} (no internet route)", "private_subnet", x, 950, 460, 220, 0)

# ---------------- global edge (left) ----------------
svc("student-exam", "user", "Student browser (exam)", 20, 420, az="Edge / Global")
svc("route53", "route53", "Route 53", 170, 420, az="Edge / Global",
    notes="Alias A/AAAA records: site to CloudFront, origin.<domain> to the ALB. ACM certificates validated by DNS.")
svc("cloudfront", "cloudfront", "CloudFront", 310, 420, az="Edge / Global",
    notes="HTTPS only. Default behaviour: S3 frontend (cached). /api/*: ALB, caching disabled, forwards Authorization.")
svc("waf", "waf", "AWS WAF", 310, 280, az="Edge / Global",
    notes="AWS managed common + bad-inputs rules, 100k req / 5 min per-IP flood limit (campus shares one IP).")

# ---------------- regional services above the VPC ----------------
svc("cognito", "cognito", "Cognito user pool", 520, 70,
    notes="Groups student / tutor / admin. Admin-created users only. ID token 60 min.")
svc("s3-frontend", "s3", "S3 frontend bucket", 700, 70,
    notes="Private, readable only by CloudFront (OAC). TLS only. SSE-S3.")
svc("backup", "backup", "AWS Backup", 880, 70,
    notes="Monthly RDS copy kept 1,826 days (5 years).")

# ---------------- VPC ----------------
svc("igw", "internet_gateway", "Internet Gateway", 940, 220)
svc("alb", "alb", "Application Load Balancer (both AZs)", 560, 400, subnet="public", replicas=2,
    notes="Public subnets A and B. HTTPS listener with ACM cert. Health check /health every 10 s. Only accepts CloudFront (prefix list + secret header).")
svc("nat-a", "nat_gateway", "NAT gateway A", 800, 400, az="AZ-A", subnet="public", multi_az=False)
svc("nat-b", "nat_gateway", "NAT gateway B", 1320, 400, az="AZ-B", subnet="public", multi_az=False)

svc("ecs-a", "ecs", "API tasks on Fargate (AZ-A)", 560, 650, az="AZ-A", subnet="private", replicas=3, multi_az=False,
    notes="Node.js API, 0.5 vCPU / 1 GB. Shown at the exam-window floor: 3 tasks here + 3 in AZ-B. Normal days 1 + 1, max 12 total.",
    autoScalingEnabled=True, minReplicas=1, maxReplicas=6, iamRole=API_TASK_ROLE)
svc("ecs-b", "ecs", "API tasks on Fargate (AZ-B)", 1080, 650, az="AZ-B", subnet="private", replicas=3, multi_az=False,
    notes="Same ECS service as AZ-A. ECS spreads the tasks evenly across both AZs.",
    autoScalingEnabled=True, minReplicas=1, maxReplicas=6, iamRole=API_TASK_ROLE)
svc("lambda-marking", "lambda", "Lambda marking-fn", 800, 650, subnet="private",
    notes="VPC-attached to both app subnets. Auto-marks MCQs. Timeout 30 s, max concurrency 5.",
    iamRole=LAMBDA_DB_ROLE, config=LAMBDA)
svc("lambda-upload", "lambda", "Lambda upload-fn", 1320, 650, subnet="private",
    notes="VPC-attached to both app subnets. Records the submission, asks for the tutor email. Timeout 30 s.",
    iamRole=LAMBDA_DB_ROLE, config=LAMBDA)
svc("s3-endpoint", "s3_gateway_endpoint", "S3 gateway endpoint", 680, 800, subnet="private",
    notes="Free. Keeps S3 traffic off the NAT gateways.")

svc("rds-primary", "rds", "RDS PostgreSQL primary", 620, 1010, az="AZ-A", subnet="private",
    notes="Multi-AZ primary. db.m6g.large in production. KMS encrypted, TLS forced, PITR 7 days.")
svc("rds-standby", "rds", "RDS PostgreSQL standby", 1140, 1010, az="AZ-B", subnet="private",
    notes="Synchronous standby. Promoted automatically if AZ-A fails (1 to 2 min).")

# ---------------- regional managed services (right) ----------------
svc("s3-uploads", "s3", "S3 uploads bucket", 1600, 230,
    notes="Presigned POST, 50 MB limit enforced by S3. Versioned. IA at 30 d, Glacier at 365 d, deleted at 1,826 d.")
svc("secrets", "secrets_manager", "Secrets Manager", 1800, 230, notes="Database password, injected into tasks at start.")
svc("sqs-uploads", "sqs", "SQS uploads queue", 1600, 380, notes="Receives S3 ObjectCreated events. Visibility 180 s.", config=QUEUE)
svc("kms", "kms", "KMS key", 1800, 380, notes="Customer managed key, yearly rotation.")
svc("sqs-marking", "sqs", "SQS marking queue", 1600, 530, notes="Visibility timeout 180 s.", config=QUEUE)
svc("dlq", "sqs_dlq", "Dead-letter queues", 1800, 530, notes="One per queue, after 3 failed receives. Alarm fires on any message.")
svc("sqs-email", "sqs", "SQS email queue", 1600, 680, notes="Visibility timeout 180 s.", config=QUEUE)
svc("lambda-email", "lambda", "Lambda email-fn", 1800, 680, notes="Outside the VPC, no database access needed. Timeout 30 s.",
    iamRole=LAMBDA_EMAIL_ROLE, config=LAMBDA)
svc("ses", "ses", "Amazon SES", 1800, 830, notes="Sends result and submission emails.")
svc("cloudwatch", "cloudwatch", "CloudWatch", 1600, 980, notes="Logs, dashboard, alarms (5xx, latency, unhealthy hosts, DLQ, RDS CPU).")
svc("sns-alarms", "sns", "SNS alarm topic", 1800, 980, notes="Emails the on-call admin.")
svc("ecr", "ecr_registry", "ECR (API image)", 1600, 1130, notes="Image tagged with the git commit SHA, scanned on push.")
svc("eventbridge", "eventbridge", "EventBridge (5 min sweep)", 1800, 1130,
    notes="Auto-submits attempts whose time ran out.")

# ---------------- outside the region (right) ----------------
svc("student-upload", "user", "Student browser (upload)", 2100, 230, az="Edge / Global")
svc("tutor", "user", "Tutor inbox", 2100, 830, az="Edge / Global")
svc("github", "github", "GitHub Actions (CI/CD)", 2100, 1130, az="Edge / Global",
    notes="Push to main: tests, terraform apply, build and push image, rolling ECS deploy.")

# ---------------- walkthrough 1: open exam + autosave ----------------
link("w1-1", "student-exam", "route53", "DNS", 1, timeout=1000)
link("w1-2", "route53", "cloudfront", "HTTPS", 2, mode="cached", timeout=1500)
link("w1-2b", "cloudfront", "s3-frontend", "Object access", 2, mode="cached", critical=False,
     label="load page (cached)", dependency=True)
link("w1-3", "cloudfront", "waf", "HTTPS", 3, timeout=1000, label="/api/*")
link("w1-4", "waf", "igw", "HTTPS", 4, timeout=1000)
link("w1-5", "igw", "alb", "HTTPS", 5, timeout=2500, label="HTTPS to origin.<domain>")
link("w1-6a", "alb", "ecs-a", "HTTP", 6, critical=False, timeout=2000, label="PUT /api/attempts/:id/answers, port 3000")
link("w1-6b", "alb", "ecs-b", "HTTP", 6, critical=False, timeout=2000, label="port 3000 (TLS ends at the ALB)")
link("w1-7a", "ecs-a", "rds-primary", "SQL", 7, timeout=5000, label="upsert answers")
link("w1-7b", "ecs-b", "rds-primary", "SQL", 7, timeout=5000, label="upsert answers")
link("w1-dep-cog-a", "ecs-a", "cognito", "HTTPS", critical=False, label="verify JWT (JWKS)", dependency=True)
link("w1-dep-cog-b", "ecs-b", "cognito", "HTTPS", critical=False, label="verify JWT (JWKS)", dependency=True)
link("w1-rep", "rds-primary", "rds-standby", "SQL", critical=False, label="synchronous replication", dependency=True)

# submit -> async marking
link("mk-1a", "ecs-a", "sqs-marking", "Message", mode="asynchronous", critical=False, label="on submit: enqueue marking", dependency=True)
link("mk-1b", "ecs-b", "sqs-marking", "Message", mode="asynchronous", critical=False, label="on submit: enqueue marking", dependency=True)
link("mk-2", "sqs-marking", "lambda-marking", "Message", 1, mode="asynchronous", label="trigger")
link("mk-3", "lambda-marking", "rds-primary", "SQL", 2, label="score MCQs")
link("mk-sweep", "eventbridge", "lambda-marking", "Event", mode="event", critical=False, label="every 5 min", manages=True)

# ---------------- walkthrough 2: 40 MB upload + tutor notified ----------------
link("w2-1", "student-upload", "cloudfront", "HTTPS", critical=False, label="POST /api/uploads/presign", dependency=True)
link("w2-2", "student-upload", "s3-uploads", "Object access", 2, timeout=60000, label="presigned POST, 40 MB")
link("w2-3", "s3-uploads", "sqs-uploads", "Message", 3, mode="asynchronous", label="ObjectCreated event")
link("w2-4", "sqs-uploads", "lambda-upload", "Message", 4, mode="asynchronous", label="trigger")
link("w2-5", "lambda-upload", "sqs-email", "Message", 5, mode="asynchronous", label="email request")
link("w2-dep-db", "lambda-upload", "rds-primary", "SQL", critical=False, label="status = received", dependency=True)
link("w2-6", "sqs-email", "lambda-email", "Message", 6, mode="asynchronous", label="trigger")
# The simulator has no connection contract for SES yet, so these two are drawn as dependencies
# instead of request hops. Walkthrough 2b proves the email worker gets the message.
link("w2-7", "lambda-email", "ses", "HTTPS", critical=False, label="7: SendEmail", dependency=True)
link("w2-8", "ses", "tutor", "HTTPS", critical=False, label="8: New submission email", dependency=True)

# ---------------- supporting relationships (drawn, not simulated as traffic) ----------------
link("ops-dlq-m", "sqs-marking", "dlq", "Message", mode="asynchronous", critical=False, label="redrive after 3 failures", manages=True)
link("ops-dlq-u", "sqs-uploads", "dlq", "Message", mode="asynchronous", critical=False, label="redrive after 3 failures", manages=True)
link("ops-dlq-e", "sqs-email", "dlq", "Message", mode="asynchronous", critical=False, label="redrive after 3 failures", manages=True)
link("ops-nat-a", "ecs-a", "nat-a", "TCP", critical=False, label="outbound (SQS, Cognito, ECR)", manages=True)
link("ops-nat-b", "ecs-b", "nat-b", "TCP", critical=False, label="outbound (SQS, Cognito, ECR)", manages=True)
link("ops-s3ep", "s3-endpoint", "s3-uploads", "Object access", critical=False, label="private S3 path", manages=True)
link("ops-secret-a", "secrets", "ecs-a", "HTTPS", critical=False, label="DB password at start", manages=True)
link("ops-secret-b", "secrets", "ecs-b", "HTTPS", critical=False, label="DB password at start", manages=True)
link("ops-kms-rds", "kms", "rds-primary", "HTTPS", critical=False, label="encrypts storage", manages=True)
link("ops-kms-sec", "kms", "secrets", "HTTPS", critical=False, label="encrypts secret", manages=True)
link("ops-waf", "waf", "cloudfront", "HTTPS", critical=False, label="web ACL attached", manages=True)
link("ops-backup", "backup", "rds-primary", "HTTPS", critical=False, label="monthly, 5 years", manages=True)
link("ops-cw-alb", "cloudwatch", "alb", "HTTPS", critical=False, label="metrics and alarms", manages=True)
link("ops-cw-sns", "cloudwatch", "sns-alarms", "Message", mode="asynchronous", critical=False, label="alarm", manages=True)
link("ops-gh-ecr", "github", "ecr", "HTTPS", critical=False, label="docker push", manages=True)
link("ops-ecr-a", "ecr", "ecs-a", "HTTPS", critical=False, label="image pull", manages=True)
link("ops-ecr-b", "ecr", "ecs-b", "HTTPS", critical=False, label="image pull", manages=True)

SCENARIOS = [
    # file name, scenario name, method, path, start node
    ("exam-platform-lab.json", "Walkthrough 1: open exam and autosave", "PUT", "/api/attempts/57/answers", "student-exam"),
    ("exam-platform-lab-w2a-upload.json", "Walkthrough 2a: student uploads 40 MB to S3", "POST", "/submissions/A2/report.pdf", "student-upload"),
    ("exam-platform-lab-w2b-notify.json", "Walkthrough 2b: upload worker asks for the tutor email", "POST", "/email-queue", "lambda-upload"),
]

for filename, name, method, path, start in SCENARIOS:
    state = {
        "draftName": f"DSO303 A2 exam platform - {name.split(':')[0]}",
        "nodes": nodes,
        "edges": edges,
        "scenario": {"id": filename.replace(".json", ""), "name": name, "method": method, "path": path,
                     "startNodeId": start, "trafficLevel": "normal"},
        "simulationResult": None,
        "activeFailures": [],
        "activeLabReference": None,
        "activeChallengeId": None,
        "challengeResult": None,
        "appMode": "design",
        "selectedNodeId": None,
        "selectedEdgeId": None,
        "activeStepIndex": None,
        "playbackSpeed": 1,
        "highlightTaskFlow": False,
        "showNaclSideColumn": False,
        "viewport": None,
    }
    doc = {"format": "aws-architecture-lab", "version": 2, "applicationRelease": None,
           "savedAt": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z"), "state": state}
    with open(filename, "w") as f:
        json.dump(doc, f, indent=2)
    print(f"wrote {filename}: {len(nodes)} nodes, {len(edges)} connections, starts at {start}")
