# REVIEW.md

## Overview

This repo runs a stateless Flask API on ECS Fargate behind an ALB. The infrastructure
plans and the app runs, but was put together carelessly in several areas that would be
unacceptable in production — particularly around secrets management, IAM permissions,
network exposure, and deployment safety.

I prioritized fixes by real-world risk: hardcoded credentials and overpermissioned IAM
are the most dangerous, followed by network surface area and pipeline safety. Issues I
didn't fix are documented below with the reasoning.

---

## Issues & Fixes

### Dockerfile

| Priority | Issue | Why it matters | Fix |
|---|---|---|---|
| Blocker | `FROM python:latest` | Unpinned ~1GB image, risk of breaking changes on rebuild | Changed to `python:3.12-slim` |
| Blocker | `ENV DB_PASSWORD=SuperSecret123!` | Secret baked into image layer, visible via `docker inspect` and image history | Removed entirely — should be injected via ECS Secrets Manager |
| Should-fix | `COPY . .` with no `.dockerignore` | Copies `.git`, `infra/`, `.env` into image | Added `.dockerignore` |
| Should-fix | Running as root | Unnecessary privilege inside container | Added non-root user via `useradd` + `USER appuser` |
| Nice-to-have | No dependency layer caching | Every code change reinstalls all packages | Separated `COPY requirements.txt` before `COPY app/` |
| Nice-to-have | `pip install` without `--no-cache-dir` | Larger image than needed | Added `--no-cache-dir` flag |

---

### app/app.py

| Priority | Issue | Why it matters | Fix |
|---|---|---|---|
| Blocker | `DB_PASSWORD` hardcoded as default fallback | If env var not set, password exposed in source code | Removed default value |
| Blocker | `debug=True` in production | Exposes stack traces and Werkzeug interactive debugger publicly | Changed to read from `FLASK_DEBUG` env var, defaults to false |
| Should-fix | `flask` unpinned in requirements.txt | Non-reproducible builds, risk of breaking changes | Left documented — should pin to `flask==3.0.3` |

---

### infra/main.tf

| Priority | Issue | Why it matters | Fix |
|---|---|---|---|
| Blocker | ECS task role has `AdministratorAccess` | Container has full AWS access — if exploited, entire account is compromised | Replaced with least-privilege; created separate execution role with `AmazonECSTaskExecutionRolePolicy` |
| Blocker | `task_role_arn` and `execution_role_arn` use the same role | These serve different purposes and have different trust requirements | Created separate `ecs_execution_role` for image pull and log delivery |
| Blocker | Security group opens all ports (0–65535) to `0.0.0.0/0` | Entire port range exposed to internet | Restricted to ports 80 and 8080 only |
| Blocker | SSH port 22 open to `0.0.0.0/0` | Fargate doesn't use SSH — pure attack surface | Removed entirely |
| Should-fix | No remote backend for Terraform state | State is local — no locking, no collaboration, state loss risk | Documented — should add S3 backend with DynamoDB locking |
| Should-fix | `DB_PASSWORD` hardcoded as variable default | Ends up in Terraform state file in plaintext | Documented — should use AWS Secrets Manager or SSM Parameter Store |
| Should-fix | `image_tag = "latest"` as default | Not reproducible, rollback is impossible | Documented — should use commit SHA as image tag |
| Should-fix | ALB listener is HTTP only (port 80) | Traffic unencrypted in transit | Documented — should add HTTPS with ACM certificate |
| Should-fix | ECS tasks assigned public IPs in public subnets | Tasks directly reachable from internet, bypassing ALB | Documented — should move to private subnets with NAT Gateway |
| Nice-to-have | ECR missing image scanning | Vulnerabilities in images go undetected | Documented — enable `scan_on_push = true` |
| Nice-to-have | No health check on ALB target group | ALB cannot detect unhealthy tasks | Documented — add health check pointing to `/health` |

---

### .github/workflows/deploy.yml

| Priority | Issue | Why it matters | Fix |
|---|---|---|---|
| Blocker | `continue-on-error: true` on test step | Pipeline deploys broken code even when tests fail | Removed — pipeline now stops on test failure |
| Blocker | Static AWS credentials in env | Long-lived keys stored in GitHub Secrets, rotation risk | Documented — should migrate to OIDC/Workload Identity Federation |
| Blocker | `terraform apply -auto-approve` without plan review | Infra changes apply without any human approval | Documented — should separate plan and apply, add manual approval gate |
| Blocker | Image pushed as `:latest` | Not reproducible, rollback impossible | Documented — should use `${{ github.sha }}` as image tag |
| Blocker | ECR URL with hardcoded account ID | AWS account ID exposed in source code | Documented — should move to GitHub variable or OIDC-derived value |
| Blocker | No ECR login step before `docker push` | Pipeline will fail on authentication | Documented — should add `aws-actions/amazon-ecr-login` step |
| Should-fix | Deploy directly to production on every push to main | No staging environment, no manual approval gate | Documented — should add environment protection rules |

---

## Terraform Validation Output

```bash
$ terraform fmt
# No output — configuration already formatted correctly

$ terraform validate
Success! The configuration is valid.
```

---

## Docker Image Size

| | Image | Size |
|---|---|---|
| Before | `python:latest` | 410MB |
| After | `python:3.12-slim` | 48.4MB |

Reduction: ~88% smaller image after switching to slim base, adding `.dockerignore`,
and using `--no-cache-dir`.

---

## Monitoring & Rollback

To know this service is down: ALB target group health checks will mark tasks unhealthy
when `/health` stops returning 200 — that's the first signal. CloudWatch Container
Insights on the ECS cluster surfaces CPU, memory, and task restart counts. An ALB 5xx
error rate alarm (threshold >1% over 5 minutes) sent to SNS covers the user-facing
symptom. With structured JSON logging from the app, CloudWatch Log Insights can query
error patterns across time windows.

To roll back a bad deploy: because image tags should be commit SHAs, rollback means
re-deploying the previous SHA. In the pipeline, re-run the deploy job with the prior
commit as `image_tag`. ECS does a rolling replacement — new task definition pointing
to the old image, old tasks drained after new ones pass health checks. If the task
definition itself is the problem, ECS keeps all previous revisions and you can force
it via `aws ecs update-service --task-definition <family>:<previous-revision>`.

---

## What I'd Do With More Time

- Move ECS tasks to private subnets with NAT Gateway — tasks should not be directly
  reachable from the internet
- Add HTTPS with ACM certificate on the ALB and redirect HTTP to HTTPS
- Replace static AWS credentials in the pipeline with OIDC — no long-lived keys stored
  in GitHub Secrets
- Add S3 remote backend with DynamoDB locking for Terraform state
- Move `DB_PASSWORD` to AWS Secrets Manager and reference it in the ECS task definition
- Pin Flask version in requirements.txt and add `pip audit` in CI to catch known CVEs
- Add ECR image scanning with a pipeline gate that fails on HIGH/CRITICAL findings
- Add structured JSON logging to the Flask app for better CloudWatch integration