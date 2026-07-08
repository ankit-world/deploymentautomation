"""Structured (JSON) logging, shipped to CloudWatch via the same `awslogs` stdout pipeline every
container already uses (see infra/aws-cli-scripts/07-task-defs.sh).

Gap this fills: prior to this, the entire backend had exactly two `logger.` calls in it (an LLM-
failure and a text-extraction-failure exception handler) — everything else was gunicorn's bare
access log (method/path/status/timing, no user identity). The original project brief explicitly
asked to "log each and everything... inside CloudWatch" including "user information," which
plain access logs don't capture. This adds structured, greppable/queryable (CloudWatch Logs
Insights) log records for every request and every user-facing action (signup, login, logout,
conversation create/delete, message sent, file upload/download), each carrying a `user_id` when
one is resolvable.

A small hand-rolled JSON formatter rather than a third-party dependency (e.g. python-json-logger)
— the format needed is simple enough (timestamp, level, logger name, message, plus whatever
`extra` fields a call site passes) that a dependency isn't worth it, consistent with this
project's general bias toward fewer dependencies for straightforward needs (see the reasoning in
app/core/metrics.py for the same tradeoff made the other way, where the EMF wire format is
genuinely fiddly enough to warrant the official library).
"""

import json
import logging
import sys
from datetime import datetime, timezone

# Fields every Python LogRecord has that aren't useful to re-emit (either redundant with what we
# already put in the JSON envelope, or internals no one queries).
_STANDARD_LOG_RECORD_FIELDS = frozenset(
    logging.LogRecord(
        name="", level=0, pathname="", lineno=0, msg="", args=(), exc_info=None
    ).__dict__.keys()
) | {"message", "asctime"}


class JsonFormatter(logging.Formatter):
    def format(self, record: logging.LogRecord) -> str:
        payload = {
            "timestamp": datetime.fromtimestamp(record.created, tz=timezone.utc).isoformat(),
            "level": record.levelname,
            "logger": record.name,
            "message": record.getMessage(),
        }
        # Anything passed via logger.info(..., extra={...}) lands as extra attributes directly
        # on the record — pull those back out rather than requiring callers to nest them.
        for key, value in record.__dict__.items():
            if key not in _STANDARD_LOG_RECORD_FIELDS:
                payload[key] = value
        if record.exc_info:
            payload["exception"] = self.formatException(record.exc_info)
        return json.dumps(payload, default=str)


def setup_logging(level: str = "INFO") -> None:
    """Call once, at import time in app.main, before any other module's logger is used."""
    root = logging.getLogger()
    root.setLevel(level.upper())

    handler = logging.StreamHandler(sys.stdout)
    handler.setFormatter(JsonFormatter())

    root.handlers.clear()
    root.addHandler(handler)

    # Quiet down noisy third-party loggers at DEBUG; leave everything else at the configured
    # level so app.* loggers are as verbose as requested.
    logging.getLogger("botocore").setLevel(max(root.level, logging.INFO))
    logging.getLogger("boto3").setLevel(max(root.level, logging.INFO))
