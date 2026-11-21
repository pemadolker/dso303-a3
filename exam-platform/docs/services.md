# Task 2: Service documentation

This is every service in my design: what it does here, why I picked it over the obvious alternative, how it is set up, and what it connects to. The configuration values are the same as in `infra/*.tf`, so if one changes the other should too.

Region: **ap-south-1 (Mumbai)**. It is the closest AWS region to Bhutan, so students get lower latency than from Singapore or the US regions. The only things outside it are the CloudFront certificate and the CloudFront WAF, which AWS requires to be in us-east-1.

## Edge and delivery

| Service | Role | Why over an alternative | Configuration | Connects to |
|---|---|---|---|---|
| **Route 53** | DNS for the exam site | Alias records can point at CloudFront and the ALB, which have no fixed IP. A normal DNS provider can only do a CNAME, which does not work at the root of a domain. | Built when `domain_name` is set. Alias A and AAAA for the site to CloudFront, alias A for `origin.<domain>` to the ALB, and the records ACM uses to validate the certificates. | CloudFront, ALB, ACM |
| **ACM** | Free TLS certificates that renew themselves | Buying a certificate and uploading it means remembering to renew it every year. ACM renews on its own as long as the DNS record is there. | Two certificates, both DNS validated: one for the site in us-east-1 (CloudFront only accepts that region) and one for `origin.<domain>` in ap-south-1 for the ALB. | CloudFront, ALB, Route 53 |
| **CloudFront** | The single HTTPS entry point. Serves the frontend from cache and passes `/api/*` to the ALB | Without it every page load at exam start would hit the region directly. CloudFront serves the HTML and JS from edge locations in India and takes the spike when 3,000 students open the page at once. WAF also attaches here. | Two origins: the S3 frontend bucket (through OAC) and the ALB. Default behaviour is cached with HTTP redirected to HTTPS. `/api/*` has caching off, allows all methods and forwards the `Authorization` header. Adds the secret `X-Origin-Verify` header on every origin request. Origin protocol is HTTPS only when a domain is set. Price class 200 (includes India). HTTP/2 and HTTP/3. | Route 53, WAF, S3 frontend, ALB |
| **AWS WAF** | Blocks common web attacks and request floods | A security group only sees IPs and ports and cannot read the request. WAF can. The AWS managed rule groups are kept up to date by AWS, which is better than me writing my own rules. | Scope CLOUDFRONT. AWS Common rule set and Known Bad Inputs. `SizeRestrictions_BODY` changed to count only, because its default 8 KB limit would block long short-answer autosaves. Rate rule of 100,000 requests per 5 minutes per IP, set high on purpose because a whole campus shares one public IP. | CloudFront |
| **S3 (frontend bucket)** | Holds the static site (HTML, JS, CSS) | Cheaper and simpler than serving the files from the API containers, and it never needs scaling. | All public access blocked. The bucket policy only lets this CloudFront distribution read (OAC) and denies any non-TLS request. SSE-S3 encryption. Uploaded by `scripts/publish-frontend.sh`, which also clears the CloudFront cache. | CloudFront |

## Compute and API

| Service | Role | Why over an alternative | Configuration | Connects to |
|---|---|---|---|---|
| **Application Load Balancer** | Spreads API requests over the tasks in both AZs and runs health checks | It works at layer 7, so it can health check `/health` and route on headers. A Network Load Balancer cannot do either. Cross-zone balancing is built in. | In both public subnets. HTTPS listener on 443 with the origin certificate and a TLS 1.2/1.3 policy when a domain is set (port 80 without one). Security group only allows CloudFront's managed prefix list. A listener rule forwards only when `X-Origin-Verify` matches, otherwise it returns 403. Health check `/health` every 10 s, 2 failures = unhealthy. Least outstanding requests algorithm. | CloudFront, ECS tasks |
| **ECS on Fargate** | Runs the Node.js API containers | I considered API Gateway + Lambda. The problem is that every concurrent Lambda opens its own database connection, and autosave is about 100 requests a second at peak. Containers keep a small shared pool instead. Fargate over EC2 because there are no servers to patch. | 0.5 vCPU and 1 GB per task, private app subnets, no public IP. Minimum 2 tasks (1 per AZ), 6 in the exam window, maximum 12. Rolling deploy with the circuit breaker and automatic rollback. AZ rebalancing on. Handles `SIGTERM` so in-flight requests finish. DB pool of 5 per task. | ALB, RDS, SQS, S3, Cognito, Secrets Manager |
| **ECR** | Stores the API container image | It is private by default, works with ECS IAM without extra login, and scans images on push. Docker Hub has pull rate limits and would be an outside dependency during an exam. | Scan on push, keeps the last 10 images, each image tagged with the git commit SHA so a deploy can be traced to a commit. | GitHub Actions, ECS |
| **Application Auto Scaling** | Adds and removes API tasks | Target tracking alone reacts too slowly when 3,000 students arrive in 5 minutes, because new tasks take about a minute to start. Scheduled scaling alone can't handle surprises. I use both. | Target 50% CPU and 3,000 requests per task per minute. Scale-out cooldown 30 s, scale-in 300 s. Scheduled floor of 6 tasks from 08:30 to 14:00 Bhutan time, Monday to Friday (editable variables). | ECS, CloudWatch |
| **Lambda: marking-fn** | Auto-marks the MCQ answers after submit. Every 5 minutes it also submits attempts whose time has run out | Marking only happens in bursts after an exam, and Lambda costs nothing while idle. Doing it inside the API would make the submit request slow. | Node 22, 256 MB, 30 s timeout, attached to both private app subnets. SQS trigger, batch 10, maximum concurrency 5 so the database is not flooded, reports partial batch failures. | SQS marking queue, EventBridge, RDS, Secrets Manager |
| **Lambda: upload-fn** | Reacts to a new file in S3, marks the submission as received and asks for the tutor email | Reacting to S3 events needs no always-on server. | Same settings as marking-fn. Idempotent, so if S3 delivers the same event twice the tutor still gets one email. | SQS uploads queue, RDS, SQS email queue |
| **Lambda: email-fn** | Sends emails through SES | Kept separate so a slow or failing email never affects marking or uploads. | Node 22, 128 MB, outside the VPC because it doesn't need the database (so it doesn't use NAT capacity). Maximum concurrency 2 to stay under the SES send rate. | SQS email queue, SES |
| **EventBridge rule** | Runs the 5-minute sweeper | A scheduled rule is cheaper and simpler than keeping a cron container running. | `rate(5 minutes)`, invokes marking-fn with `{"source":"sweep"}`. | Lambda marking-fn |

## Identity and security

| Service | Role | Why over an alternative | Configuration | Connects to |
|---|---|---|---|---|
| **Cognito user pool** | Sign-in, password policy and roles | If I built login myself I would have to store and protect password hashes, handle resets and lockouts. Cognito does that and gives signed tokens that the API only has to verify. | Admin-created users only, no self sign-up. Password at least 12 characters. Optional TOTP MFA. Groups `student`, `tutor` and `admin` become the roles in the API. ID token 60 min, refresh token 8 h. No client secret, because it's a browser app. | Browser, API |
| **IAM** | Permissions for the tasks and functions | Roles give temporary credentials, so there are no access keys in the code or in environment variables. | Four least-privilege roles. For example the API task role may only `PutObject` under `submissions/*`, send to two queues and manage Cognito users, and the email role may only send from the verified SES identity. (`use_lab_role = true` swaps them for the AWS Academy `LabRole`, only for accounts that cannot create roles.) | All services |
| **Secrets Manager** | Holds the database password | Putting the password in Terraform files or plain environment variables would leak it into Git or logs. ECS injects it when the task starts. | Encrypted with the KMS key. 32-character random password made by Terraform. Stored as JSON with host, port, user and password. | ECS, Lambda |
| **KMS** | Customer-managed encryption key | With my own key I control who can use it and CloudTrail logs every use. The default AWS-owned keys give neither. | Yearly automatic rotation. Encrypts RDS storage and the secret. | RDS, Secrets Manager |
| **Security groups** | Firewall for each tier, by reference instead of IP | Network ACLs work per subnet and need IP ranges. Security groups can say "only from the ALB's group", which stays correct as tasks scale in and out. | ALB: CloudFront prefix list only. App: port 3000 from the ALB only. Database: 5432 from the app and Lambda groups only. | All VPC resources |

## Data and storage

| Service | Role | Why over an alternative | Configuration | Connects to |
|---|---|---|---|---|
| **RDS PostgreSQL (Multi-AZ)** | Users, exams, questions, attempts, answers and submissions | The data is relational: an attempt belongs to an exam and a student, marking joins answers to questions, and submit has to be one transaction. DynamoDB would need every query designed up front. Multi-AZ gives a synchronous standby and automatic failover, which I would have to build by hand with PostgreSQL on EC2. | PostgreSQL 16. Default `db.t3.micro` so a test deployment is cheap; production size `db.m6g.large`. 20 GB gp3 that can grow to 100 GB. Encrypted with KMS, in the private data subnets, not publicly accessible, `rds.force_ssl=1`. Backups kept 7 days with point-in-time restore. Deletion protection and a final snapshot while `protect_data = true`. | ECS, Lambda |
| **S3 (uploads bucket)** | Stores the assignment PDFs and ZIPs | Cheaper and much more durable than a disk on a server, and with presigned POST the 50 MB files never pass through the API. | Presigned POST valid 5 minutes with a signed `content-length-range` of 1 byte to 50 MB and the exact content type. SSE-S3, versioning on, public access blocked, TLS only. Lifecycle: Standard-IA after 30 days, Glacier after 365, deleted after 1,826 days (5 years). Old versions removed after 90 days, unfinished multipart uploads after 7. CORS allows POST only from the site. Sends `ObjectCreated` events to the uploads queue. | Browser, SQS uploads queue |
| **AWS Backup** | Monthly database copy kept for 5 years | Automated RDS backups only go up to 35 days, so the 5-year records rule needs a separate plan. | Monthly rule, deleted after 1,826 days. On by default (`enable_backup_plan`). | RDS |

## Background work and email

| Service | Role | Why over an alternative | Configuration | Connects to |
|---|---|---|---|---|
| **SQS (marking, uploads, email) with dead-letter queues** | Buffers work between the API, S3 and the workers | If the API called Lambda directly, a slow marking job would make the student's submit fail. With a queue the submit returns straight away and failed jobs are retried. SNS pushes messages but does not keep them for retry. | Encrypted with SQS-managed keys. Visibility timeout 180 s (six times the Lambda timeout). After 3 failed tries the message moves to a DLQ that keeps it for 14 days, and an alarm fires. | API, S3, Lambda |
| **Amazon SES** | Sends the "results released" and "new submission" emails | Cheaper than running a mail server and much better deliverability than sending SMTP from a container. | Verified sender identity. New SES accounts start in the sandbox, where recipients must also be verified until production access is requested. | email-fn |

## Network

| Service | Role | Why over an alternative | Configuration | Connects to |
|---|---|---|---|---|
| **VPC, subnets, route tables** | Private network, 3 tiers in each of 2 AZs | A flat network would put the database at the same level as the internet-facing parts. | `10.0.0.0/16`. Public `10.0.0.0/24` and `10.0.1.0/24` (ALB, NAT). Private app `10.0.10.0/24` and `10.0.11.0/24` (tasks, Lambda). Private data `10.0.20.0/24` and `10.0.21.0/24` (RDS, no route out). | All |
| **Internet gateway** | Way in and out for the public subnets | Needed for the ALB and the NAT gateways. | One per VPC, only in the public route table. | ALB, NAT |
| **NAT gateway (one per AZ)** | Lets the private tasks call AWS APIs (SQS, Secrets Manager, ECR, Cognito) | One shared NAT would mean AZ B loses its outbound access when AZ A goes down. A NAT instance would be one more server to manage. | One per AZ. Each private app subnet routes to the NAT in its own AZ. | Private app subnets |
| **S3 gateway endpoint** | Private path to S3 | It is free and keeps S3 traffic off the NAT gateways, which charge per GB. | Attached to both app route tables. | VPC, S3 |

## Monitoring

| Service | Role | Why over an alternative | Configuration | Connects to |
|---|---|---|---|---|
| **CloudWatch** (logs, metrics, alarms, dashboard) | Seeing what is happening during an exam | Every service above already sends metrics to it, so there is no extra agent or tool to run. | Logs kept 30 days. Alarms for API 5xx, p95 latency over 1 s, unhealthy targets, ECS CPU, RDS CPU and connections, any message in a DLQ and a marking queue older than 5 minutes. One dashboard. Container Insights on. | Everything |
| **SNS** | Sends the alarm emails | The simplest way to get an alarm to a person. | One topic with an email subscription to `alarm_email`. | CloudWatch |

## Delivery pipeline

| Service | Role | Why over an alternative | Configuration | Connects to |
|---|---|---|---|---|
| **Terraform** | The whole infrastructure as code | I already know it and it works the same way outside AWS, while CloudFormation is AWS only and wordier. Clicking in the console can't be repeated or reviewed. `terraform plan` shows what will change before it happens. | Remote state in S3 (versioned, encrypted, native lock file). Variables for sizing, the exam window and the optional domain. | All AWS resources |
| **S3 (Terraform state bucket)** | Stores the state file | Local state is lost with the laptop and can't be shared with the pipeline. | Created once by `scripts/bootstrap-state.sh`. | Terraform |
| **GitHub Actions** | Tests, builds and deploys on every push to `main` | The code is already on GitHub, so there is nothing extra to set up. CodePipeline plus CodeBuild would do the same with more AWS resources to manage. | `test` job on every push and pull request (API and worker tests, `terraform fmt -check` and `validate`). `deploy` job on push to `main` when `DEPLOY_ENABLED` is true: apply, build and push the image, wait for ECS to be stable, publish the frontend, smoke test. | ECR, Terraform, S3, CloudFront |

## Things I considered and left out

| Option | Why not (for now) |
|---|---|
| **RDS Proxy** | The Cloud Architecture Lab suggested it. It pools connections, but my code already caps them: 5 per task and 2 per Lambda, so about 50 in the exam window and 80 at the maximum, which the production instance handles easily. It becomes worth it if the API moves to Lambda. |
| **ElastiCache (Redis)** | The heavy traffic is autosave, which is writes, and writes can't be cached. The read-heavy part (the exam page) is already cached by CloudFront. |
| **Aurora PostgreSQL** | Faster failover (under 30 s) and read replicas, but it costs more at this size. Multi-AZ RDS already meets the 1-hour RTO with a lot of room. |
| **API Gateway + Lambda for the API** | Explained in the Fargate row: one database connection per concurrent request at 100 requests a second. |
| **A third AZ** | The brief asks to survive the loss of one AZ, which two AZs already do. A third would add another NAT gateway and more subnets for little gain at this scale. |
