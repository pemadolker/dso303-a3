# Task 3: Cloud Architecture Lab

Simulator: https://main.d35uam9e2t7o65.amplifyapp.com/#lab

I built the design from Task 1 in the simulator and saved it as draft files. All three files have the same diagram (44 resources, 44 connections). The only difference is where the test request starts, because the simulator always sends the request from the start point saved in the file and there is no picker for it in the UI.

| File | Starts at | What it runs | Expected result |
|---|---|---|---|
| `exam-platform-lab.json` | Student browser (exam) | Walkthrough 1: `PUT /api/attempts/57/answers` (autosave) | HTTP 200, 14 steps |
| `exam-platform-lab-w2a-upload.json` | Student browser (upload) | Walkthrough 2, first half: the 40 MB file goes straight to S3, then the S3 event goes into the uploads queue | HTTP 202 |
| `exam-platform-lab-w2b-notify.json` | Lambda upload-fn | Walkthrough 2, second half: the upload worker puts an email job on the email queue and the email worker picks it up | HTTP 202 |

The AZ failure test uses the first file again.

`build_lab_json.py` is the script that writes the three files. I used a script instead of dragging 44 boxes by hand so the positions, ARNs and IAM roles stay the same across files, and so I can change something once and rebuild. Run it with `python3 build_lab_json.py`.

## How to load a file

1. Open the simulator link.
2. Click **Export** (top right), then **Upload JSON**, and choose the file.
3. Press Escape to close the panel. The diagram appears on the canvas. Use the fit button (bottom left of the canvas) if it is off screen.

## Walkthrough 1: student opens an exam and the answers autosave

1. Load `exam-platform-lab.json`.
2. Click **Simulate** at the top.
3. Click **Send Request**. The method and path (`PUT /api/attempts/57/answers`) are already filled in from the file.
4. Wait for the animation to finish. The timeline at the bottom should end at step 14 with **HTTP 200 Response Delivered**, and the green pill on the right shows `HTTP 200`.

The path it takes: Student browser → Route 53 (DNS) → CloudFront (cache miss, because `/api/*` is never cached) → WAF (inspection passed) → Internet Gateway → ALB → API task in AZ-A → RDS primary → back to the student.

Opening the exam page itself (HTML and JavaScript) comes from the S3 frontend bucket through CloudFront and is drawn as the dotted "load page (cached)" line.

## Walkthrough 2: student uploads a 40 MB assignment, tutor gets an email

Part A:
1. Load `exam-platform-lab-w2a-upload.json`.
2. **Simulate**, then **Send Request** (`POST /submissions/A2/report.pdf`).
3. Result: **HTTP 202**. The file goes from the browser to the S3 uploads bucket using the presigned POST, and S3 sends the "object created" event to the uploads queue. 202 means "accepted, the rest happens in the background", which is exactly what happens in the real design.

Part B:
1. Load `exam-platform-lab-w2b-notify.json`.
2. **Simulate**, then **Send Request**.
3. Result: **HTTP 202**. The upload worker writes the email job to the email queue, and the timeline shows the email worker (`email-fn`) consuming it.

Why it is split in two: the simulator stops at the first queue it reaches and only checks that the consumer can read from it. It does not chain one background job into the next one, so the second queue needs its own run.

The last two steps (email worker → SES → tutor inbox) are drawn on the diagram but cannot be simulated, because the simulator has no model for SES yet (it reports "no verified connection contract" for that pair). In the real code this is `workers/email.js`, which calls SES `SendEmail`.

## AZ failure: AZ-A goes down during an exam

1. Load `exam-platform-lab.json`.
2. Click **Failure Lab** at the top.
3. Click **AZ-A outage**. Everything in AZ-A is marked failed: NAT gateway A, the API tasks in AZ-A and the RDS primary.
4. Click **Send Request**.
5. Result: still **HTTP 200**. In the timeline:
   - the ALB checks both target groups and sends the request to the API tasks in **AZ-B**
   - step 12, **Multi-AZ Automated Database Failover**: "Primary DB in AZ-A failed ... Promoted synchronous standby replica in secondary AZ to primary writer ... Zero data loss"
6. Click **Restore all** when done.

**AZ-B outage** works the same way (the tasks in AZ-A take the traffic and the primary is not affected).

## Analyze tab

Clicking **Analyze** gives this design **Resilient**, with:

| Score | Value |
|---|---|
| Availability | 100% |
| Resilience | 95% |
| Fault tolerance | 100% |
| Scalability | 80% |
| Security and isolation | 85% |
| Single points of failure | none found |
| Configuration errors | none found |

The points it takes off, and what I think of them:

- **Security, "HTTP between the ALB and the API tasks".** That is true and on purpose. TLS ends at the ALB, and the hop to the tasks is on port 3000 inside the private app subnet, where only the ALB's security group can reach the tasks. Adding TLS on that last hop would need certificates inside every container for very little gain. The hop from CloudFront to the ALB is HTTPS when a domain is set.
- **Scalability, "database connection contention, add RDS Proxy or ElastiCache".** I looked at this. In the exam window there are 6 tasks with a pool of 5 connections each, plus the marking and upload Lambdas (concurrency 5, 2 connections each), so about 50 connections, and 80 even at the 12-task maximum. The production instance size (db.m6g.large) allows several hundred. The connection count is capped on purpose in the code, which is the main thing RDS Proxy would do for us. Autosave is about 100 small writes a second. Writes cannot be cached, so ElastiCache would not help the main load. RDS Proxy becomes worth it if the API moves to Lambda or the task count grows a lot. I left it out and wrote it down as a known trade-off.
- **Architecture risks (blast radius, dependency concentration).** These come from treating every line on the diagram as a hard dependency. For example it says a failure of the dead-letter queue would take down the API, but the API never talks to the DLQ, and the queues exist so a slow or broken worker does not affect the student's request. I kept the lines because they make the diagram explain itself.

## How the simulator differs from the Terraform

- The simulator splits the VPC CIDR into equal /19 subnets on its own, so it shows `10.0.0.0/19` and so on. The real subnets are /24s (`10.0.0.0/24` public A, `10.0.10.0/24` app A, `10.0.20.0/24` data A, and `.1`, `.11`, `.21` for AZ B). I took the CIDRs out of the box titles so the two don't contradict each other.
- The API tasks are shown as 3 per AZ, which is the exam-window floor. On a normal day it is 1 per AZ.
- Lambda functions are shown in one subnet box each, but in Terraform the VPC-attached ones (marking and upload) get network interfaces in both private app subnets.
- The IAM roles and resource ARNs on the nodes use a dummy account number (`111122223333`). The simulator checks them in strict mode, so they have the same permissions as `infra/iam.tf`.

## Screenshots

These are already in `evidence/`. To retake one, follow the steps above:

| File | What to capture |
|---|---|
| `cloud-architecture-lab.png` | The whole diagram in **Design** view (use the fit button first) |
| `lab-walkthrough-1.png` | Walkthrough 1 finished, timeline at step 14 and the `HTTP 200` pill visible |
| `lab-walkthrough-2a.png` | Part A finished with `HTTP 202` |
| `lab-walkthrough-2b.png` | Part B finished with `HTTP 202` |
| `lab-az-failure.png` | AZ-A outage active, request finished with `HTTP 200`, timeline scrolled so the failover step is visible |
| `lab-analyze.png` | The Analyze scores |
