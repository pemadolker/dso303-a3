# Online Exam and Assignment Platform (DSO303 Assignment 2)

Pema Dolker, 4th year Software Engineering, CST

This repo is my cloud design for moving the university's exams and assignment submissions online. It covers about 8,000 students and 400 staff. Most of the marks are for the architecture, so that is where most of the work went, but I also wrote the infrastructure as Terraform, a small working application (API, workers and a plain HTML frontend) and a GitHub Actions pipeline, so the design can actually be deployed and is not only a drawing.

## Summary

| | |
|---|---|
| What it does | Students sign in, sit timed MCQ and short-answer exams that autosave every 30 seconds, and upload PDF or ZIP files up to 50 MB. Tutors create exams, mark them and release results. Admins manage users. Students get an email when results are released and tutors get one when a submission arrives. |
| Main services | Route 53, CloudFront with WAF, S3 for the frontend, an Application Load Balancer, the API on ECS Fargate, Cognito for sign-in, RDS PostgreSQL Multi-AZ, S3 for uploads (with lifecycle rules), SQS and Lambda for marking and emails, SES, CloudWatch, Secrets Manager and KMS. |
| Layout | One region (ap-south-1, Mumbai, the closest AWS region to Bhutan), one VPC, two Availability Zones, three subnet tiers (public, private app, private data). |
| Targets | 99.9% availability during exam periods, keeps running if one AZ is lost, RPO 5 minutes, RTO 1 hour, records kept for 5 years, encryption in transit and at rest. How each one is met is in `architecture/README.md`. |

## What is where

| Path | What it has |
|---|---|
| `architecture/` | The diagram, both request walkthroughs, the peak and AZ loss explanation (Task 1) |
| `architecture/cloud-architecture-lab/` | The simulator files for the Cloud Architecture Lab (Task 3) |
| `docs/services.md` | The service table: role, why I picked it over an alternative, configuration, connections (Task 2) |
| `evidence/` | Screenshots from the Cloud Architecture Lab and test runs |
| `infra/` | Terraform for the whole stack |
| `api/` | Node.js API that runs on Fargate, with tests |
| `workers/` | The three Lambda functions (marking, upload, email), with tests |
| `frontend/` | Static web app in plain HTML and JavaScript |
| `scripts/` | Deploy, destroy, seed users, publish the frontend, AZ failure test |
| `.github/workflows/deploy.yml` | CI/CD: tests on every push, deploy to AWS on push to `main` |

## Cloud Architecture Lab (Task 3)

The design is built in the Cloud Architecture Lab simulator as a draft file, so it can be loaded instead of redrawn by hand.

1. Open https://main.d35uam9e2t7o65.amplifyapp.com/#lab
2. Click **Export**, then **Upload JSON**, and pick `architecture/cloud-architecture-lab/exam-platform-lab.json`.
3. Go to **Simulate** and click **Send Request**. This runs walkthrough 1 and should end with HTTP 200.

The full steps for walkthrough 2 and the AZ failure test are in `architecture/cloud-architecture-lab/README.md`.

## Deploy to AWS

I did not deploy this on the Learner Lab for the submission (the lecturer confirmed only the architecture is required there). These are the steps for a normal AWS account.

### What you need

- An AWS account with admin access, and the AWS CLI logged in to it
- Terraform 1.10 or newer, Docker, Node 22 and Git
- An email address you can open (SES sends a verification link to it)
- Optional: a domain in a Route 53 hosted zone. With one, the site gets its own name and HTTPS all the way to the load balancer. Without one, the site still works on the CloudFront address (`https://xxxx.cloudfront.net`).

### From your own machine

```bash
# 1. Settings
cp infra/terraform.tfvars.example infra/terraform.tfvars
# edit ses_sender_email and alarm_email, and domain_name + hosted_zone_id if you have a domain

# 2. Deploy (about 25 minutes, most of it is the Multi-AZ database)
scripts/deploy.sh

# 3. Click the SES verification link in your inbox, then create demo users
PASSWORD='Choose-A-Strong-Pass-1' scripts/seed-users.sh you@example.com
```

`deploy.sh` creates the Terraform state bucket, creates the container registry, builds and pushes the API image, applies the rest of the stack, waits for the API tasks to be healthy and uploads the frontend to S3. It prints the site address at the end.

`seed-users.sh` makes `you+admin@`, `you+tutor@`, `you+student1@` and `you+student2@` on your own address, so every email lands in one inbox.

### From GitHub Actions

1. Push the repo to GitHub.
2. In the repo go to **Settings > Secrets and variables > Actions**.
   - Secrets: `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` (and `AWS_SESSION_TOKEN` only if the keys are temporary)
   - Variables: `SES_SENDER_EMAIL`, `ALARM_EMAIL`, optionally `DOMAIN_NAME` and `HOSTED_ZONE_ID`, and `DEPLOY_ENABLED` = `true`
3. Push to `main`.

The `test` job runs on every push and pull request: API tests, worker tests, `terraform fmt -check` and `terraform validate`. The `deploy` job only runs when `DEPLOY_ENABLED` is `true`, so the repo can sit on GitHub without AWS keys and still show green test runs. When it does run, it does the same steps as `deploy.sh` and finishes with a smoke test through CloudFront (the page must return 200 and `/api/me` must return 401 without a token).

## Tear down

```bash
scripts/destroy.sh
```

The NAT gateways, the load balancer and the Multi-AZ database are billed by the hour, so do this when you are done. The database has deletion protection and the uploads bucket refuses to be deleted while it has files, on purpose. The script first applies `protect_data=false` to switch both off, then destroys everything. The state bucket is left behind and can be deleted by hand.

## AZ failure test on real AWS

```bash
scripts/simulate-az-failure.sh
```

This probes the site every 2 seconds, blocks the app subnet in AZ A with a deny-all network ACL, forces the database to fail over, prints the target health every 15 seconds and then puts everything back. The log goes into `evidence/`.

## Running the tests

```bash
(cd api && npm ci && npm test)
(cd workers && npm ci && npm test)
(cd infra && terraform init -backend=false && terraform validate)
```

## Limitations I know about

- The capacity numbers (6 tasks for 3,000 students) are worked out on paper in `architecture/README.md`. I have not load tested them.
- SES accounts start in the sandbox, so emails only go to verified addresses until production access is requested.
- The API creates its database tables when it starts. A bigger project should use a proper migration tool.
- Without a custom domain, the hop from CloudFront to the load balancer is plain HTTP inside AWS, because there is no certificate to put on the load balancer. Setting `domain_name` fixes this and makes the origin HTTPS only.
- The Cloud Architecture Lab has no model for SES yet, so in the simulator the last two steps of walkthrough 2 (email worker to SES to tutor) are drawn but not simulated. The simulation proves the email worker receives the job.
