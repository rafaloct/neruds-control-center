from __future__ import annotations

import json
import logging
import os
from datetime import datetime, timezone
from logging.handlers import RotatingFileHandler
from pathlib import Path

_SENSITIVE = ("password", "token", "cookie", "csrf", "authorization")


class JsonFormatter(logging.Formatter):
    def format(self, record: logging.LogRecord) -> str:
        event = {
            "time": datetime.now(timezone.utc).isoformat(),
            "level": record.levelname,
            "event": record.getMessage(),
        }
        for key, value in record.__dict__.items():
            if key.startswith("_") or key in {
                "args", "created", "exc_info", "exc_text", "filename", "levelname",
                "levelno", "lineno", "message", "module", "msecs", "msg", "name",
                "pathname", "process", "processName", "relativeCreated", "stack_info",
                "thread", "threadName",
            }:
                continue
            event[key] = "[redacted]" if any(part in key.lower() for part in _SENSITIVE) else value
        return json.dumps(event, ensure_ascii=False, default=str)


def configure_operations_logger() -> logging.Logger:
    logger = logging.getLogger("neruds.operations")
    if logger.handlers:
        return logger
    directory = Path(os.getenv("NERUDS_LOG_DIR", Path(__file__).resolve().parent.parent / "logs"))
    directory.mkdir(parents=True, exist_ok=True)
    handler = RotatingFileHandler(
        directory / "bridge.jsonl",
        maxBytes=5 * 1024 * 1024,
        backupCount=10,
        encoding="utf-8",
    )
    handler.setFormatter(JsonFormatter())
    logger.setLevel(logging.INFO)
    logger.addHandler(handler)
    logger.propagate = False
    return logger
