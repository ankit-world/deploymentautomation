# Session 06 — AWS Account Bootstrap

## Goal

Get from "AWS account exists, nothing else configured" to "AWS CLI works locally with a scoped
IAM user, and GitHub Actions can assume a deploy role via OIDC" — the hard gate before any
infrastructure provisioning.

## Prerequisites

- Session 00 done (this doesn't depend on the app being built — can run any time).
- The user has an AWS account with root/console access.

## This session is mostly user-driven

Root-account-level actions (enabling IAM, initial account settings) generally require the AWS
console and the account owner. Claude Code's role here is to give precise, step-by-step
instructions and to run the AWS CLI commands once credentials exist locally — not to act
autonomously on the AWS account without the user present and confirming each step.

## Deliverables

- AWS CLI installed locally (`aws --version` works).
- A budget alarm (e.g. $20/month) set up in AWS Budgets, so runaway spend is caught early —
  worth doing before any real resources exist.
- An IAM user (not root) with a scoped policy (ECR, ECS, VPC, ELB, ElastiCache, CloudWatch,
  Secrets Manager, IAM PassRole for ECS task roles) for local CLI use, access key configured via
  `aws configure --profile <project-name>`.
- An IAM OIDC identity provider for `token.actions.githubusercontent.com`, plus an IAM role
  GitHub Actions can assume (trust policy scoped to this specific repo), with a policy scoped
  to ECR push + ECS deploy — used starting in session 11, but the role is created here since it's
  an account-bootstrap concern.
- MFA enabled on the root account (console step, not CLI).

## Done criteria

- `aws sts get-caller-identity --profile <project-name>` returns the new IAM user, not root.
- Budget alarm visible in the AWS Budgets console.
- OIDC provider + deploy role exist (`aws iam list-open-id-connect-providers`,
  `aws iam get-role --role-name <deploy-role-name>`).
