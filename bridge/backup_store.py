from __future__ import annotations

import argparse
import hashlib
import hmac
import shutil
import sqlite3
from datetime import datetime, timezone
from pathlib import Path


def _timestamp() -> str:
    return datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")


def _validate(database: Path) -> None:
    try:
        with sqlite3.connect(database) as conn:
            if conn.execute("PRAGMA integrity_check").fetchone()[0] != "ok":
                raise ValueError("O banco SQLite falhou na verificação de integridade.")
    except sqlite3.DatabaseError as exc:
        raise ValueError("O arquivo não é um banco SQLite íntegro.") from exc


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _verify_checksum(source: Path) -> None:
    checksum_file = source.with_suffix(".sha256")
    if not checksum_file.is_file():
        return
    expected = checksum_file.read_text(encoding="ascii").strip().split()[0]
    actual = _sha256(source)
    if not hmac.compare_digest(expected, actual):
        raise ValueError("O SHA-256 do backup não confere.")


def backup(source: Path, destination: Path) -> Path:
    if not source.is_file():
        raise FileNotFoundError(f"Banco não encontrado: {source}")
    destination.mkdir(parents=True, exist_ok=True)
    target = destination / f"{source.stem}-{_timestamp()}.sqlite3"
    temporary = target.with_suffix(".tmp")
    with sqlite3.connect(source) as source_conn, sqlite3.connect(temporary) as target_conn:
        source_conn.backup(target_conn)
    _validate(temporary)
    temporary.replace(target)
    digest = _sha256(target)
    target.with_suffix(".sha256").write_text(f"{digest}  {target.name}\n", encoding="ascii")
    return target


def restore(source: Path, destination: Path) -> Path | None:
    if not source.is_file():
        raise FileNotFoundError(f"Backup não encontrado: {source}")
    _verify_checksum(source)
    _validate(source)
    previous = None
    if destination.exists():
        previous = destination.with_name(f"{destination.stem}.before-restore-{_timestamp()}.sqlite3")
        shutil.copy2(destination, previous)
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = destination.with_suffix(".restore.tmp")
    shutil.copy2(source, temporary)
    _validate(temporary)
    temporary.replace(destination)
    return previous


def main() -> None:
    parser = argparse.ArgumentParser(description="Backup e restauração segura do mission store.")
    parser.add_argument("--database", type=Path, required=True)
    command = parser.add_subparsers(dest="command", required=True)
    backup_parser = command.add_parser("backup")
    backup_parser.add_argument("--destination", type=Path, required=True)
    restore_parser = command.add_parser("restore")
    restore_parser.add_argument("--source", type=Path, required=True)
    args = parser.parse_args()
    if args.command == "backup":
        print(backup(args.database, args.destination))
    else:
        previous = restore(args.source, args.database)
        print(previous or "restored")


if __name__ == "__main__":
    main()
