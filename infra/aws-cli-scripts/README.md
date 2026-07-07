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
flags.** Every script in this directory starts with:

```bash
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
```

Do not remove this line, and do not run any ad-hoc `aws` command on this machine for this project
without the same `unset` first (or you'll silently hit whatever unrelated AWS account those env
vars point to — this happened once already during session 06 and had to be cleaned up). Verify
you're on the right account before anything stateful:

```bash
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
AWS_PROFILE=chatapp aws sts get-caller-identity   # must show Account: 788070448326, user ankitexp
```

## Profile / account for this project

- AWS CLI profile: `chatapp` (in `~/.aws/credentials` and `~/.aws/config`, region `us-east-1`).
- IAM user: `ankitexp`, **AdministratorAccess** (created directly by the project owner, not by a
  script — see `docs/sessions/06-aws-account-bootstrap.md` for why this deviates from the
  originally-planned least-privilege local-CLI user).
- Account: `788070448326`.
- There is also an unrelated pre-existing `default` profile/IAM user (`github`, a different AWS
  account, also admin) on this machine from other work — never use it for this project.
