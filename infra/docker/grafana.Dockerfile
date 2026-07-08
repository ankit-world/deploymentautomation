# Grafana, provisioned as code (see docs/ARCHITECTURE.md "Grafana" bullet, session 10).
#
# Build context is the REPO ROOT (same convention as backend.Dockerfile/frontend.Dockerfile — see
# infra/docker/docker-compose.yml's `build.context: ../..`), so the COPY below is rooted at
# "infra/docker/grafana/...".
#
# Datasource (CloudWatch, auth via the container's IAM task role — no static AWS keys, see
# provisioning/datasources/cloudwatch.yml) and dashboards (provisioning/dashboards/*.json) are
# baked into the image at build time, not configured via the UI or a mounted volume. This keeps
# the ECS service stateless: no EFS volume, no persistent disk, redeploying the image redeploys
# the dashboards. Grafana's own SQLite state (users, sessions, UI-made changes) lives in the
# container's ephemeral filesystem and is intentionally NOT persisted — acceptable because the
# only "state" that matters here (datasources, dashboards) is provisioned from files on every
# start, and `allowUiUpdates: false` in dashboards.yml keeps the UI from diverging from the
# provisioned JSON in the first place.
#
# grafana/grafana-oss (not the Enterprise `grafana/grafana` image) — no Enterprise features are
# needed here, and -oss keeps the image and its license footprint smaller. Pinned to a specific
# version (not `:latest`) for reproducible builds. The upstream image already creates and runs as
# a non-root `grafana` user (uid 472) and exposes 3000 — no need to redeclare either here.

FROM grafana/grafana-oss:11.3.0

COPY --chown=472:472 infra/docker/grafana/provisioning /etc/grafana/provisioning

EXPOSE 3000
