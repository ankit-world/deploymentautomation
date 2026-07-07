# infra/aws-cli-scripts

Numbered, idempotent AWS CLI shell scripts, one AWS concern each. Populated starting session 06
(account bootstrap) — see `docs/sessions/06-aws-account-bootstrap.md` onward.

Each script writes the resource IDs it creates to `.env.aws` (gitignored) so later scripts can
reference them without re-querying the AWS API.
