# infra/aws-cli-scripts

Numbered, idempotent AWS CLI shell scripts, one AWS concern each. Populated starting session 06
(account bootstrap) — see `docs/sessions/06-aws-account-bootstrap.md` onward.

Each script writes the resource IDs it creates to `.env.aws` (gitignored) so later scripts can
reference them without re-querying the AWS API.

## Before running any script on this machine: read this

This machine has `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` set as environment variables from an
unidentified source (confirmed not a Windows User/Machine env var, not in the usual shell profile
files — the source was never located). **Environment-variable credentials always take precedence
over `--profile`/`AWS_PROFILE` in the AWS CLI's credential chain, with no way to override that via
flags — this now includes overriding `default` itself**, since `default` was later repointed to
the correct `ankitexp` user but these stray env vars still win over it. In other words: a bare
`aws` command with zero flags on this machine still silently hits the wrong AWS account. Every
script in this directory starts with:

```bash
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
```

Do not remove this line, and do not run any ad-hoc `aws` command on this machine for this project
without the same `unset` first (or you'll silently hit whatever unrelated AWS account those env
vars point to — this happened once already during session 06 and had to be cleaned up). Verify
you're on the right account before anything stateful:

```bash
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
aws sts get-caller-identity   # must show Account: 788070448326, user ankitexp
```

## Second Windows gotcha: MSYS path conversion

Git-Bash-on-Windows (MSYS2) auto-converts any CLI argument that looks like a Unix absolute path
into a Windows path *before* the AWS CLI ever sees it — e.g. `--health-check-path /login` silently
becomes `--health-check-path C:/Program Files/Git/login`, which then fails AWS's validation (or
worse, would silently "succeed" with the wrong value if it happened to pass validation). This bit
`06-alb.sh` during session 08 (health-check paths and ALB path-pattern conditions like `/auth*`).
Every script with a leading-`/` argument sets:

```bash
export MSYS_NO_PATHCONV=1
```

If you're writing a new script with any argument starting with `/` (S3 keys, URL paths, IAM
resource paths, etc.), add this line too.

## Profile / account for this project

- AWS CLI profile: `default` (in `~/.aws/credentials` and `~/.aws/config`, region `us-east-1`).
  There is no separate named profile for this project — a previously-created `chatapp` profile
  and an old, unrelated `default` profile/IAM user (`github`, a different AWS account) were both
  removed by the project owner directly; `default` now IS this project's identity.
- IAM user: `ankitexp`, **AdministratorAccess** (created directly by the project owner, not by a
  script — see `docs/sessions/06-aws-account-bootstrap.md` for why this deviates from the
  originally-planned least-privilege local-CLI user).
- Account: `788070448326`.
