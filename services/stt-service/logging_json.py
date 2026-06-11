"""Structured JSON logging for STT service."""
from __future__ import annotations

import json
import logging
import os
import sys
import uuid
from contextvars import ContextVar
from datetime import datetime, timezone
from typing import Any

SERVICE_NAME = "stt-service"
request_id_var: ContextVar[str | None] = ContextVar("request_id", default=None)


def get_request_id() -> str:
    rid = request_id_var.get()
    return rid if rid else str(uuid.uuid4())


def set_request_id(request_id: str) -> None:
    request_id_var.set(request_id)


class JsonLogFormatter(logging.Formatter):
    def format(self, record: logging.LogRecord) -> str:
        payload: dict[str, Any] = {
            "ts": datetime.now(timezone.utc).isoformat(),
            "level": record.levelname,
            "service": getattr(record, "service", SERVICE_NAME),
            "logger": record.name,
            "message": record.getMessage(),
        }
        if getattr(record, "request_id", None):
            payload["request_id"] = record.request_id
        if getattr(record, "event", None):
            payload["event"] = record.event
        if getattr(record, "extra", None):
            payload["extra"] = record.extra
        return json.dumps(payload, default=str)


class _SkipUvicornHealthAccessLog(logging.Filter):
    def filter(self, record: logging.LogRecord) -> bool:
        try:
            msg = record.getMessage()
        except Exception:
            return True
        return "GET /health HTTP" not in msg and "GET /v1/models HTTP" not in msg


def suppress_uvicorn_health_access_logs() -> None:
    log = logging.getLogger("uvicorn.access")
    if any(getattr(f, "_telecom_skip_health", False) for f in log.filters):
        return
    f = _SkipUvicornHealthAccessLog()
    f._telecom_skip_health = True
    log.addFilter(f)


def configure_logging() -> None:
    level = os.getenv("LOG_LEVEL", "INFO").upper()
    root = logging.getLogger()
    root.handlers.clear()
    root.setLevel(level)
    h = logging.StreamHandler(sys.stdout)
    h.setFormatter(JsonLogFormatter())
    root.addHandler(h)
    suppress_uvicorn_health_access_logs()


def log_event(
    event: str,
    request_id: str | None = None,
    *,
    extra: dict[str, Any] | None = None,
    level: int = logging.INFO,
) -> None:
    rid = request_id if request_id is not None else "unknown"
    logging.getLogger("telecom.trace").log(
        level,
        event,
        extra={
            "service": SERVICE_NAME,
            "request_id": rid,
            "event": event,
            "extra": extra or {},
        },
    )
