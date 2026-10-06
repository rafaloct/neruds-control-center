import sqlite3

import backup_store
import logging
import operations_logging


def test_backup_and_restore_roundtrip(tmp_path):
    database = tmp_path / "missions.sqlite3"
    with sqlite3.connect(database) as conn:
        conn.execute("CREATE TABLE sample (value TEXT)")
        conn.execute("INSERT INTO sample VALUES ('original')")

    saved = backup_store.backup(database, tmp_path / "backups")
    assert saved.is_file()
    assert saved.with_suffix(".sha256").is_file()

    with sqlite3.connect(database) as conn:
        conn.execute("UPDATE sample SET value='changed'")

    previous = backup_store.restore(saved, database)
    assert previous is not None and previous.is_file()
    with sqlite3.connect(database) as conn:
        assert conn.execute("SELECT value FROM sample").fetchone()[0] == "original"


def test_structured_logs_redact_sensitive_fields():
    formatter = operations_logging.JsonFormatter()
    record = logging.LogRecord("test", logging.INFO, "", 0, "event", (), None)
    record.access_token = "secret"
    record.component = "backup"
    data = formatter.format(record)
    assert "secret" not in data
    assert '"access_token": "[redacted]"' in data
    assert '"component": "backup"' in data
