# Roadmap

**Live since session 08**: http://chatapp-alb-811403579.us-east-1.elb.amazonaws.com (HTTP only —
custom domain/HTTPS is session 12).

This project is deliberately split into isolated, focused sessions so no single Claude Code
session has to carry the whole build in its context window. Each session has a brief at
`docs/sessions/NN-name.md` that is self-contained: a fresh session (or a parallel one running in
a separate git worktree) should be able to read that one file plus `docs/ARCHITECTURE.md` and
start working without needing this conversation's history.

**How to use this file**: check a box when a session's "done criteria" (in its brief) are met.
Update `docs/ARCHITECTURE.md` if a session changes a decision made there.

**Running sessions in parallel**: sessions that don't touch overlapping files (e.g. session 1
"Backend core" and session 3 "Frontend core") can run concurrently in separate git worktrees.
Sessions with a hard dependency (e.g. session 8 needs session 7's VPC/ECR to exist) must run
sequentially.

## Sessions

- [x] 00 — Foundations & scaffolding
- [x] 01 — Backend core (auth + conversation/message CRUD)
- [x] 02 — Backend LLM + files (OpenAI streaming, file upload/parse/download)
- [x] 03 — Frontend core (scaffold, auth pages, protected layout, basic chat)
- [x] 04 — Frontend chat experience (streaming, file previews/downloads, markdown)
- [x] 05 — Dockerization & local end-to-end
- [x] 06 — AWS account bootstrap (CLI install, IAM user, OIDC role, budget alarm)
- [x] 07 — AWS networking + ECR (VPC, subnets, NAT, security groups, ECR repos)
- [x] 08 — AWS compute + ALB (ECS cluster, task defs, services, load balancer, Secrets Manager)
- [x] 09 — ElastiCache + CloudWatch (Redis, log groups, Container Insights, alarms)
- [x] 10 — Grafana on Fargate (config-as-code dashboards over CloudWatch)
- [x] 11 — CI/CD via GitHub Actions (OIDC, build/push/deploy pipeline)
- [ ] 12 — HTTPS/custom domain (deferred until a domain is available)

## Dependency order

```
00 ──┬──> 01 ──> 02 ──┐
     └──> 03 ──> 04 ──┴──> 05 ──> 06 ──> 07 ──> 08 ──┬──> 09 ──> 10
                                                       └──> 11 ──> 12
```

01/02 (backend) and 03/04 (frontend) can be built in parallel worktrees once 00 is merged; both
must land before 05 (needs both Dockerfiles). 06 is a hard gate for everything AWS. 09, 10, 11
can happen in any order once 08 is live; 12 needs a purchased/available domain.
