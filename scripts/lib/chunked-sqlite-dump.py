#!/usr/bin/env python3
"""Append-only byte-rotation chunked dump for a SQLite table.

The SQLite analog of scripts/lib/chunked-table-dump.py (Postgres). It exists
to slim hermes-data/: the old monolithic `sqlite3 .dump` of state.db re-wrote
a ~70 MB plaintext blob every day, and every snapshot re-committed the whole
thing, so git history accumulated the full file hundreds of times over. This
helper carves the bulk table (messages, keyed by its INTEGER PRIMARY KEY) into
fixed-id-range chunks that:

  1. Stay under GitHub's 100 MB per-blob cap (target 80 MB, 15 MB margin).
  2. Preserve git's pack-delta compression — frozen chunks are byte-identical
     across daily runs unless rows in their id range actually change. Because
     messages.id is a monotonic AUTOINCREMENT key, new rows always land in the
     CURRENT chunk; frozen chunks never change. Daily cost in the pack
     collapses to ~the new rows' size.
  3. Rotate gracefully: when the current chunk exceeds the target, recompute
     boundaries from the current sorted rows (one larger diff, never an
     unpushable blob).

Two output modes (mutually exclusive):

  --out-dir DIR    chunked layout for a bulk table:
      DIR/.rotation.json   {"chunks": [{"num": 1, "max_pk": <int>}, ...]}
      DIR/0001.sql         INSERTs for rows with pk <= max_pk_1
      DIR/NNNN.sql         CURRENT chunk — pk > last frozen max_pk
    Requires --pk-column (must be an INTEGER column; boundaries compare
    numerically).

  --out-file FILE  single flat dump for a small table (sessions, state_meta,
    schema_version). Ordered by rowid. No chunking.

Both modes emit EXPLICIT-COLUMN INSERTs:
    INSERT INTO "messages"("id","session_id",...) VALUES(...);
built from SQLite's own quote() per column, so:
  - any payload (newlines, quotes, blobs, NULLs) is escaped correctly without
    fragile text-parsing of the INSERT line, and
  - frozen chunks survive schema migrations: a column ALTERed in later stays
    out of historical chunks (those rows take the new column's default on
    restore) while the current chunk picks it up — keeping old chunks
    byte-identical.

Schema is NOT emitted here — restore applies hermes-data/schema.sql first, then
replays these data files. Deterministic: rows are ORDER BY the chunk key, so
two runs against an unchanged DB produce byte-identical files.

Usage:
    python3 scripts/lib/chunked-sqlite-dump.py --db /path/state.db \\
        --table messages --pk-column id --out-dir hermes-data/messages
    python3 scripts/lib/chunked-sqlite-dump.py --db /path/state.db \\
        --table sessions --out-file hermes-data/sessions.sql

Exits non-zero on any error (set -e safe).
"""
from __future__ import annotations

import argparse
import json
import sqlite3
import sys
from pathlib import Path
from typing import Any


def _qident(name: str) -> str:
    return '"' + name.replace('"', '""') + '"'


def _columns(conn: sqlite3.Connection, table: str, exclude: set[str]) -> list[str]:
    info = conn.execute(f"PRAGMA table_info({_qident(table)})").fetchall()
    if not info:
        raise ValueError(f"table {table!r} not found (or has no columns)")
    cols = [row[1] for row in info]
    if exclude:
        cols = [c for c in cols if c not in exclude]
    return cols


def _fetch_statements(
    conn: sqlite3.Connection,
    table: str,
    columns: list[str],
    order_expr: str,
    pk_select: str | None,
) -> list[tuple[Any, bytes]]:
    """Return [(pk_or_None, insert_statement_bytes), ...] ordered by order_expr.

    Each value is rendered via SQLite quote(), which yields a ready SQL literal
    for every type (text/int/real/blob/NULL). The statement is terminated with
    ';\\n'; payloads may contain embedded newlines — restore parses by
    statement (semicolon), not by line.
    """
    quoted = ", ".join(f"quote({_qident(c)})" for c in columns)
    select_list = (f"{pk_select}, " if pk_select else "") + quoted
    colnames = ",".join(_qident(c) for c in columns)
    prefix = f"INSERT INTO {_qident(table)}({colnames}) VALUES("
    out: list[tuple[Any, bytes]] = []
    cur = conn.execute(
        f"SELECT {select_list} FROM {_qident(table)} ORDER BY {order_expr}"
    )
    val_start = 1 if pk_select else 0
    for row in cur:
        pk = row[0] if pk_select else None
        values = ",".join(row[val_start:])
        out.append((pk, (prefix + values + ");\n").encode()))
    return out


def _load_rotation(out_dir: Path) -> dict[str, Any]:
    rot_path = out_dir / ".rotation.json"
    if rot_path.exists():
        return json.loads(rot_path.read_text())
    return {"chunks": []}


def _save_rotation(out_dir: Path, rotation: dict[str, Any]) -> None:
    (out_dir / ".rotation.json").write_text(
        json.dumps(rotation, indent=2, sort_keys=True) + "\n"
    )


def _initial_chunking(
    rows: list[tuple[Any, bytes]], target_bytes: int
) -> dict[str, Any]:
    """Walk rows in pk order, cut a frozen boundary each time the accumulated
    chunk would cross target_bytes. The trailing partial bucket stays open as
    the current chunk (NOT recorded as frozen)."""
    rotation: dict[str, Any] = {"chunks": []}
    current = 0
    last_pk: Any = None
    for pk, stmt in rows:
        b = len(stmt)
        if current + b > target_bytes and last_pk is not None:
            rotation["chunks"].append(
                {"num": len(rotation["chunks"]) + 1, "max_pk": last_pk}
            )
            current = 0
        current += b
        last_pk = pk
    return rotation


def _bucket(
    rows: list[tuple[Any, bytes]], rotation: dict[str, Any]
) -> dict[int, list[bytes]]:
    buckets: dict[int, list[bytes]] = {}
    frozen = [c["max_pk"] for c in rotation["chunks"]]
    next_chunk = len(frozen) + 1
    for pk, stmt in rows:
        chunk_num = next_chunk
        for i, max_pk in enumerate(frozen):
            if pk <= max_pk:
                chunk_num = i + 1
                break
        buckets.setdefault(chunk_num, []).append(stmt)
    return buckets


def _bucket_size(stmts: list[bytes]) -> int:
    return sum(len(s) for s in stmts)


def _write_atomic(path: Path, stmts: list[bytes]) -> int:
    tmp = path.with_suffix(path.suffix + ".tmp")
    with open(tmp, "wb") as f:
        for s in stmts:
            f.write(s)
    size = tmp.stat().st_size
    tmp.replace(path)
    return size


def _remove_stale_chunks(out_dir: Path, live: set[int]) -> None:
    for path in out_dir.glob("*.sql"):
        try:
            num = int(path.stem)
        except ValueError:
            continue
        if num not in live:
            path.unlink()


def _run_chunked(args: argparse.Namespace, conn: sqlite3.Connection) -> int:
    out_dir: Path = args.out_dir
    out_dir.mkdir(parents=True, exist_ok=True)

    cols = _columns(conn, args.table, set(args.exclude_columns))
    if args.pk_column not in cols:
        print(
            f"[chunked-sqlite] ERROR: pk column {args.pk_column!r} not in {cols}",
            file=sys.stderr,
        )
        return 2

    rows = _fetch_statements(
        conn, args.table, cols, _qident(args.pk_column), _qident(args.pk_column)
    )
    if not rows:
        (out_dir / "0001.sql").write_bytes(b"")
        _save_rotation(out_dir, {"chunks": []})
        print(f"[chunked-sqlite] {args.table}: empty; wrote 0001.sql empty")
        return 0

    if args.target_bytes >= args.max_bytes:
        print(
            f"[chunked-sqlite] ERROR: target-bytes ({args.target_bytes}) must be "
            f"< max-bytes ({args.max_bytes})",
            file=sys.stderr,
        )
        return 2
    biggest = max(len(stmt) for _, stmt in rows)
    if biggest > args.max_bytes:
        print(
            f"[chunked-sqlite] ERROR: one row is {biggest} bytes, above "
            f"max-bytes {args.max_bytes}; cannot create a pushable chunk",
            file=sys.stderr,
        )
        return 3

    rotation = _load_rotation(out_dir)
    if not rotation["chunks"]:
        rotation = _initial_chunking(rows, args.target_bytes)

    buckets = _bucket(rows, rotation)
    oversized = next(
        (
            (n, _bucket_size(s))
            for n, s in sorted(buckets.items())
            if _bucket_size(s) > args.target_bytes
        ),
        None,
    )
    if oversized:
        num, size = oversized
        print(
            f"[chunked-sqlite] {args.table}: chunk {num:04d} is {size}b > "
            f"{args.target_bytes} target; repairing rotation."
        )
        rotation = _initial_chunking(rows, args.target_bytes)
        buckets = _bucket(rows, rotation)

    written = sorted(buckets.keys())
    for num in written:
        path = out_dir / f"{num:04d}.sql"
        size = _write_atomic(path, buckets[num])
        if size > args.max_bytes:
            print(
                f"[chunked-sqlite] ERROR: {path} is {size}b > max-bytes "
                f"{args.max_bytes}",
                file=sys.stderr,
            )
            return 3
    _remove_stale_chunks(out_dir, set(written))
    _save_rotation(out_dir, rotation)

    sizes = ", ".join(f"{n:04d}={(out_dir / f'{n:04d}.sql').stat().st_size}b" for n in written)
    print(f"[chunked-sqlite] {args.table}: {len(rows)} rows, chunks: {sizes}")
    return 0


def _run_single(args: argparse.Namespace, conn: sqlite3.Connection) -> int:
    out_file: Path = args.out_file
    out_file.parent.mkdir(parents=True, exist_ok=True)
    cols = _columns(conn, args.table, set(args.exclude_columns))
    # Small tables: order by rowid for a stable, deterministic dump without
    # needing a declared PK (schema_version has none).
    rows = _fetch_statements(conn, args.table, cols, "rowid", None)
    size = _write_atomic(out_file, [stmt for _, stmt in rows])
    print(f"[chunked-sqlite] {args.table}: {len(rows)} rows -> {out_file} ({size}b)")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--db", required=True, help="path to the SQLite database file")
    ap.add_argument("--table", required=True)
    ap.add_argument("--pk-column", help="INTEGER chunk key (required with --out-dir)")
    ap.add_argument(
        "--exclude-columns",
        default="",
        help="comma-separated columns to omit (parity with the PG helper; "
        "may not include the pk column)",
    )
    ap.add_argument("--out-dir", type=Path, help="chunked layout output dir")
    ap.add_argument("--out-file", type=Path, help="single flat dump output file")
    ap.add_argument("--target-bytes", type=int, default=80 * 1024 * 1024)
    ap.add_argument("--max-bytes", type=int, default=95 * 1024 * 1024)
    args = ap.parse_args()

    args.exclude_columns = [
        c.strip() for c in args.exclude_columns.split(",") if c.strip()
    ]
    if bool(args.out_dir) == bool(args.out_file):
        print("[chunked-sqlite] ERROR: pass exactly one of --out-dir / --out-file", file=sys.stderr)
        return 2
    if args.out_dir and not args.pk_column:
        print("[chunked-sqlite] ERROR: --pk-column is required with --out-dir", file=sys.stderr)
        return 2
    if args.pk_column and args.pk_column in args.exclude_columns:
        print(f"[chunked-sqlite] ERROR: --exclude-columns may not include pk {args.pk_column!r}", file=sys.stderr)
        return 2

    conn = sqlite3.connect(f"file:{args.db}?mode=ro", uri=True)
    conn.text_factory = str
    try:
        if args.out_dir:
            return _run_chunked(args, conn)
        return _run_single(args, conn)
    finally:
        conn.close()


if __name__ == "__main__":
    sys.exit(main())
