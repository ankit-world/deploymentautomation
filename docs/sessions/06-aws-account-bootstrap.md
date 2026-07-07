# Session 06 — AWS Account Bootstrap

**Status**: done (2026-07-08), run interactively with the user (not a background agent — this
session inherently needs a human present for account-level decisions and console-only steps).

**What was built**: `infra/aws-cli-scripts/00-account-bootstrap.sh` (idempotent) creates a $20/mo
budget alarm (80% actual / 100% forecasted email thresholds), an IAM OIDC provider trusting
`token.actions.githubusercontent.com`, and an IAM role `chatapp-github-deploy` GitHub Actions can
assume — trust policy scoped to `repo:ankit-world/deploymentautomation:ref:refs/heads/main` only
(not other branches/PRs), permissions scoped to ECR push + ECS deploy actions + a
condition-restricted `iam:PassRole` (not admin). Verified: `aws sts get-caller-identity`, budget/
OIDC-provider/role all confirmed present via direct `aws` queries against account `788070448326`.

**Deviations from the original plan, both decided by the user directly, not by Claude Code:**
- **The local-CLI IAM user is `ankitexp` with full `AdministratorAccess`**, not the
  least-privilege scoped policy the brief originally called for — the user created this user
  themselves before the session started and chose to use it as-is rather than have a second,
  narrower user created on top of it. Documented here as an accepted tradeoff, not an oversight.
- **The AWS account is `788070448326`**, not whatever account a pre-existing, unrelated
  `default` CLI profile (IAM user `github`, also `AdministratorAccess`) pointed at — that profile
  predates this project, is left completely untouched, and must never be used for this project.

**Real incident during this session, worth knowing about for any future AWS CLI work here**: this
machine has `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` set as environment variables from a
source that could not be identified (not a Windows User/Machine-level env var, not in any standard
shell profile file). Environment-variable credentials silently override `--profile`/`AWS_PROFILE`
in the AWS CLI's credential chain — there is no flag to force profile-based credentials to win.
The bootstrap script's first run consequently created the budget/OIDC-provider/role in the *wrong*
account (`837453223154`, the unrelated `github` user's account) despite explicitly requesting the
`chatapp` profile. All three were confirmed created only moments earlier (via `CreateDate`/absence
checks) and deleted from that account before re-running correctly. Every script in
`infra/aws-cli-scripts/` now starts with `unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
AWS_SESSION_TOKEN` — see `infra/aws-cli-scripts/README.md` for the full warning. **Any ad-hoc
`aws` command run outside these scripts must do the same unset first**, or it risks silently
hitting the wrong account again.

**Follow-up (same day)**: the user corrected the region to `us-east-1` (was mistakenly set up as
`ap-south-1`) and separately cleaned up `~/.aws/credentials`/`~/.aws/config` directly — removing
the old unrelated `github`/`837453223154` `default` profile entry and the separate `chatapp`
profile entry, leaving a single `default` profile that IS `ankitexp`/`788070448326`/`us-east-1`.
All scripts/docs were updated accordingly (`AWS_PROFILE=default`, not `chatapp`). The stray
env-var override problem described above is unchanged by this — confirmed still present, and now
overrides `default` itself rather than a separately-named wrong profile, so the `unset` step
matters just as much as before.

**Still outstanding — a console-only step only the user can do**: root account MFA is not yet
enabled (`aws iam get-account-summary` shows `AccountMFAEnabled: 0`). This cannot be done via the
CLI; the user needs to enable it themselves in the AWS Console (IAM → root user → MFA) with an
authenticator app or hardware key. Also: the budget's email notification subscription (
`ankitmarwaha7@gmail.com`) likely needs a one-time confirmation click from an AWS email before
alerts actually fire — worth checking that inbox.

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
