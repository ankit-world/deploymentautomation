"""Application-level metrics via CloudWatch Embedded Metric Format (EMF).

Distinct from the infra-level metrics sessions 09-10 already cover (ECS CPU/memory via
Container Insights, ALB request count/latency/5xx, ElastiCache CPU/connections — all visible in
the Grafana `chatapp-infra` dashboard). Those describe the *containers*; these describe the
*application*: how many requests/chat messages/file uploads happen, how long the LLM actually
takes, error rates, token usage.

Why EMF instead of the more common "in-process counters + a periodic background flush task"
pattern: this app already ships every container's stdout to CloudWatch Logs via the `awslogs`
log driver (see infra/aws-cli-scripts/07-task-defs.sh). EMF is just a specially-shaped JSON log
line — write one to stdout and CloudWatch automatically extracts real metrics from it, no
separate metrics API client, no background task, no flush-on-shutdown race to get right. A
`MetricsLogger` per call, used directly (not the `@metric_scope` decorator, which would mean
wrapping every route handler) keeps this usable from middleware and from deep inside request
handling alike.

`AWS_EMF_ENVIRONMENT` forced to "local" below, before the library is even imported, rather than
left to its own auto-detection or set via task-def/`.env` config: this app always wants the
stdout sink (local dev prints to console, Docker/ECS ship stdout to CloudWatch via the `awslogs`
driver) — there's no deployment context this app runs in where the alternative (probing for an
EC2 instance-metadata endpoint, which Fargate blocks anyway, then falling back to a CloudWatch
agent daemon socket that doesn't exist here) is ever correct. Confirmed via a real failure during
testing: without this, `MetricsLogger.flush()` silently drops every metric trying to reach a
nonexistent agent socket (`[WinError 10049]` locally; would be a connection-refused equivalent in
a container) — logged as an error, not raised, so it fails invisibly rather than loudly. Since
this is a plain `os.environ.setdefault` (not an unconditional overwrite), it can still be
overridden by a real env var if some future deployment genuinely needs to — just isn't scattered
across multiple config surfaces for a value that's the same everywhere today.
"""

import logging
import os

os.environ.setdefault("AWS_EMF_ENVIRONMENT", "local")

from aws_embedded_metrics import MetricsLogger  # noqa: E402
from aws_embedded_metrics.environment.environment_detector import resolve_environment  # noqa: E402

logger = logging.getLogger(__name__)

NAMESPACE = "ChatApp"


def _new_logger() -> MetricsLogger:
    metrics = MetricsLogger(resolve_environment)
    metrics.set_namespace(NAMESPACE)
    return metrics


async def _flush(metrics: MetricsLogger, what: str) -> None:
    # Metrics are a nice-to-have, not a request-blocking dependency — a flush failure (e.g. a
    # sink error) should never turn into a 500 for the actual request.
    try:
        await metrics.flush()
    except Exception:
        logger.exception("Failed to flush %s metric", what)


async def record_request(route: str, method: str, status_code: int, duration_ms: float) -> None:
    """One call per HTTP request, from app.main's request-metrics middleware. No Route/Method
    *dimensions* (would multiply CloudWatch metric cardinality by every distinct path) — they're
    set as properties instead, so they're still visible/searchable in CloudWatch Logs Insights.
    """
    metrics = _new_logger()
    metrics.put_metric("RequestCount", 1, "Count")
    metrics.put_metric("RequestDuration", duration_ms, "Milliseconds")
    metrics.set_property("Route", route)
    metrics.set_property("Method", method)
    metrics.set_property("StatusCode", status_code)
    if status_code >= 500:
        metrics.put_metric("ServerErrorCount", 1, "Count")
    elif status_code >= 400:
        metrics.put_metric("ClientErrorCount", 1, "Count")
    await _flush(metrics, "request")


async def record_llm_call(
    model: str,
    duration_ms: float,
    success: bool,
    prompt_tokens: int | None = None,
    completion_tokens: int | None = None,
    total_tokens: int | None = None,
) -> None:
    """One call per chat completion, from the messages router around the LLM call itself — this
    is the accurate timing source for the chat endpoint (the generic request-duration metric
    above measures how long it took to *start* the SSE response, not how long the underlying LLM
    generation actually took, since StreamingResponse returns before its generator runs)."""
    metrics = _new_logger()
    # Success as a dimension (not just a property) so failure rate is a directly queryable
    # CloudWatch metric/Grafana panel, not something that needs a Logs Insights query.
    metrics.put_dimensions({"Model": model, "Success": str(success).lower()})
    metrics.put_metric("LlmCallDuration", duration_ms, "Milliseconds")
    metrics.put_metric("LlmCallCount", 1, "Count")
    if prompt_tokens is not None:
        metrics.put_metric("LlmPromptTokens", prompt_tokens, "Count")
    if completion_tokens is not None:
        metrics.put_metric("LlmCompletionTokens", completion_tokens, "Count")
    if total_tokens is not None:
        metrics.put_metric("LlmTotalTokens", total_tokens, "Count")
    await _flush(metrics, "llm_call")


async def record_chat_message() -> None:
    """One call per user-sent chat message (app/routers/messages.py)."""
    metrics = _new_logger()
    metrics.put_metric("ChatMessagesSent", 1, "Count")
    await _flush(metrics, "chat_message")


async def record_file_upload(kind: str, size_bytes: int) -> None:
    """One call per successful file upload (app/routers/files.py)."""
    metrics = _new_logger()
    metrics.put_dimensions({"Kind": kind})
    metrics.put_metric("FileUploadCount", 1, "Count")
    metrics.put_metric("FileUploadSize", size_bytes, "Bytes")
    await _flush(metrics, "file_upload")
