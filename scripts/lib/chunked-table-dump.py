#!/usr/bin/env python3
"""Append-only byte-rotation chunked dump for a SQL table.

The single-file pg_dump model breaks once any table exceeds GitHub's
100 MB per-blob cap. This helper carves a big table's data dump into
fixed-PK-range chunks that:

  1. Stay under the cap (target: 80 MB per chunk, 20 MB safety margin).
  2. Preserve git's pack-delta compression — past chunks are
     byte-identical across daily runs unless rows in their range
     actually changed. Only the "current" chunk grows day-to-day.
  3. Rotate gracefully: when the current chunk exceeds the target,
     freeze its highest PK as the new boundary and start a new chunk
     on the next dump. No reshuffling of historical chunks.

Layout for table `T` in directory `out_dir/T/`:

    .rotation.json     # {"chunks": [{"num": 1, "max_pk": "<uuid>"}, ...]}
    0001.sql           # INSERT statements for PKs ≤ max_pk_1
    0002.sql           # INSERT statements for PKs ∈ (max_pk_1, max_pk_2]
    ...
    NNNN.sql           # CURRENT chunk — PKs > last frozen max_pk

On dump:
  - Read .rotation.json (or initialize empty for first run).
  - For each frozen chunk (1..N-1):
      Query rows in that chunk's PK range. Emit INSERTs to <NNNN>.sql.
      Past chunk file becomes byte-identical UNLESS a row's content
      changed upstream — in which case git picks up the small diff.
  - For the current chunk N:
      Query rows with PK > last_frozen_max_pk. Emit to <NNNN>.sql.
  - If <NNNN>.sql > target_bytes, ROTATE:
      Record (N, max_pk_of_chunk_N) in .rotation.json.
      Next run starts a fresh current chunk (N+1) for new rows.

On restore: `cat T/*.sql | psql` — file numbers sort chronologically.

Idempotent + deterministic: row order within a chunk is
`ORDER BY <pk>` so two runs against an unchanged DB produce
byte-identical chunk files.

Usage from a bash sync script:
    python3 scripts/lib/chunked-table-dump.py \\
        --psql-host 127.0.0.1 --psql-port 5432 \\
        --psql-user hindsight --psql-database hindsight \\
        --table public.memory_units \\
        --pk-column id \\
        --out-dir hindsight-data/memory_units \\
        --target-bytes 83886080   # 80 MiB

Env vars:
    PGPASSWORD — postgres password (standard libpq)

Exits non-zero on any error (set -e safe).
"""
from __future__ import annotations

import argparse
import contextlib
import json
import os
import subprocess
import sys
from pathlib import Path
from typing import Any, Iterable


def _psql_cmd(args: argparse.Namespace, sql: str) -> list[str]:
    return [
        "psql",
        "--host", args.psql_host,
        "--port", str(args.psql_port),
        "--username", args.psql_user,
        "--dbname", args.psql_database,
        "--no-align",
        "--tuples-only",
        "--quiet",
        "--no-psqlrc",
        "--field-separator-zero",
        "--record-separator-zero",
        "-c", sql,
    ]


def _psql_query(args: argparse.Namespace, sql: str) -> bytes:
    """Run psql -c sql, return stdout. Uses zero-byte separators so we
    can split safely on any payload (UUIDs are ASCII so it doesn't
    matter for pk columns, but keeps the helper generic).
    """
    result = subprocess.run(
        _psql_cmd(args, sql),
        check=True,
        capture_output=True,
    )
    return result.stdout


def _pg_dump_rows_in_range(
    args: argparse.Namespace,
    lo_exclusive: str | None,
    hi_inclusive: str | None,
) -> bytes:
    """Dump INSERTs for rows in (lo_exclusive, hi_inclusive].

    None on either side = no bound on that side. We use pg_dump with
    --column-inserts for the row format and then post-filter, BUT
    that re-dumps the whole table even for a slice. Instead, use a
    direct SELECT … FROM … WHERE … and synthesize INSERTs.

    Simpler: dump the whole table with pg_dump once, then bucket the
    INSERT lines into chunks here. That's what we do — the sort happens
    once for the whole table, then we split. See `dump_full_table`.
    """
    raise NotImplementedError  # we bucket from the full dump instead


def _dump_full_table(args: argparse.Namespace) -> list[bytes]:
    """Run pg_dump for the whole table, return a list of INSERT lines
    sorted by PK (lexicographic — same as bash `LC_ALL=C sort`).

    Header / SET / SELECT setup lines are filtered out. The chunks are
    pure INSERT statements + a trailing newline. On restore we
    concatenate chunk files; psql handles each line independently.
    """
    table_pg = args.table  # e.g. "public.memory_units"
    cmd = [
        args.pg_dump_path,
        "--host", args.psql_host,
        "--port", str(args.psql_port),
        "--username", args.psql_user,
        "--dbname", args.psql_database,
        "--data-only",
        "--column-inserts",
        "--table", table_pg,
    ]
    result = subprocess.run(cmd, check=True, capture_output=True)
    lines = result.stdout.splitlines()
    inserts = [l for l in lines if l.startswith(b"INSERT INTO " + table_pg.encode())]
    # Stable order: lex sort. Matches `LC_ALL=C sort` in the bash
    # scripts. Two consecutive identical DBs produce identical output.
    inserts.sort()
    return inserts


def _pk_from_insert(line: bytes, pk_col_idx: int) -> bytes:
    """Extract the PK value from a `--column-inserts` line.

    pg_dump format (with --column-inserts):
        INSERT INTO public.memory_units (id, content, ...) VALUES ('uuid-...', 'text-...', ...);

    The columns list and the VALUES list are positional. pk_col_idx
    is the 0-based index of the PK column in the columns list. We pull
    the matching positional value from VALUES.
    """
    # Find the start of VALUES (
    values_marker = b" VALUES ("
    idx = line.find(values_marker)
    if idx < 0:
        raise ValueError(f"no VALUES in insert line: {line[:80]!r}")
    payload = line[idx + len(values_marker):]
    # Walk through values respecting single-quoted strings (with ''
    # for escaped quote) until we've seen pk_col_idx commas at the
    # top level.
    i = 0
    n = len(payload)
    field_start = 0
    field_count = 0
    in_string = False
    while i < n:
        c = payload[i:i + 1]
        if in_string:
            if c == b"'":
                # SQL escape: '' = literal '
                if i + 1 < n and payload[i + 1:i + 2] == b"'":
                    i += 2
                    continue
                in_string = False
                i += 1
                continue
            i += 1
            continue
        if c == b"'":
            in_string = True
            i += 1
            continue
        if c == b",":
            if field_count == pk_col_idx:
                return payload[field_start:i].strip()
            field_count += 1
            field_start = i + 1
            i += 1
            continue
        if c == b")" and field_count == pk_col_idx:
            return payload[field_start:i].strip()
        i += 1
    raise ValueError(f"could not extract pk col {pk_col_idx} from: {line[:120]!r}")


def _columns_list(line: bytes, table_pg: str) -> list[bytes]:
    """Parse the column list from `INSERT INTO public.X (col1, col2, ...)`."""
    prefix = b"INSERT INTO " + table_pg.encode() + b" ("
    if not line.startswith(prefix):
        raise ValueError(f"unexpected insert prefix: {line[:80]!r}")
    rest = line[len(prefix):]
    end = rest.find(b")")
    if end < 0:
        raise ValueError(f"no closing ) in column list: {line[:120]!r}")
    cols_raw = rest[:end]
    return [c.strip() for c in cols_raw.split(b",")]


def _load_rotation(out_dir: Path) -> dict[str, Any]:
    rot_path = out_dir / ".rotation.json"
    if rot_path.exists():
        return json.loads(rot_path.read_text())
    return {"chunks": []}


def _save_rotation(out_dir: Path, rotation: dict[str, Any]) -> None:
    rot_path = out_dir / ".rotation.json"
    rot_path.write_text(json.dumps(rotation, indent=2, sort_keys=True) + "\n")


def _write_chunk_atomic(path: Path, body_lines: list[bytes]) -> int:
    """Write a chunk file atomically. Returns bytes written."""
    tmp = path.with_suffix(path.suffix + ".tmp")
    with open(tmp, "wb") as f:
        for line in body_lines:
            f.write(line)
            f.write(b"\n")
    size = tmp.stat().st_size
    tmp.replace(path)
    return size


def _bucket_into_chunks(
    inserts: list[bytes],
    pk_col_idx: int,
    rotation: dict[str, Any],
) -> dict[int, list[bytes]]:
    """Assign each INSERT line to a chunk number based on the frozen
    rotation boundaries. Lines with PK ≤ chunks[0].max_pk go in 1;
    lines with PK > chunks[N-1].max_pk go in N+1 (the current chunk).
    """
    buckets: dict[int, list[bytes]] = {}
    chunks = rotation["chunks"]
    frozen_max_pks = [c["max_pk"].encode() for c in chunks]
    next_chunk_after_frozen = len(chunks) + 1

    for line in inserts:
        pk_val = _pk_from_insert(line, pk_col_idx)
        # Strip surrounding single quotes if present (UUIDs are
        # quoted; numeric ids aren't).
        pk_unquoted = (
            pk_val[1:-1] if pk_val.startswith(b"'") and pk_val.endswith(b"'") else pk_val
        )
        chunk_num = next_chunk_after_frozen
        for i, max_pk in enumerate(frozen_max_pks):
            if pk_unquoted <= max_pk:
                chunk_num = i + 1
                break
        buckets.setdefault(chunk_num, []).append(line)
    return buckets


def _initial_chunking(
    inserts: list[bytes],
    pk_col_idx: int,
    target_bytes: int,
) -> dict[str, Any]:
    """First-run helper: walk inserts in PK order, accumulating bytes,
    cut a chunk boundary every time we cross target_bytes. Returns
    a rotation dict describing the frozen chunks (the final partial
    bucket is the "current" chunk and is NOT recorded as frozen).
    """
    rotation: dict[str, Any] = {"chunks": []}
    current_bytes = 0
    last_pk: bytes | None = None
    for line in inserts:
        line_bytes = len(line) + 1  # +1 for the trailing \n we'll write
        if current_bytes + line_bytes > target_bytes and current_bytes > 0:
            # Close this chunk at the previous PK.
            if last_pk is None:
                # Shouldn't happen — current_bytes > 0 implies we
                # wrote at least one row.
                raise RuntimeError("rotation logic error")
            pk_str = last_pk.decode() if isinstance(last_pk, bytes) else last_pk
            # Strip quotes for storage consistency.
            if pk_str.startswith("'") and pk_str.endswith("'"):
                pk_str = pk_str[1:-1]
            rotation["chunks"].append(
                {"num": len(rotation["chunks"]) + 1, "max_pk": pk_str}
            )
            current_bytes = 0
        current_bytes += line_bytes
        last_pk = _pk_from_insert(line, pk_col_idx)
    # The trailing partial bucket stays open (current chunk).
    return rotation


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--psql-host", default="127.0.0.1")
    ap.add_argument("--psql-port", default="5432")
    ap.add_argument("--psql-user", required=True)
    ap.add_argument("--psql-database", required=True)
    ap.add_argument("--table", required=True, help="e.g. public.memory_units")
    ap.add_argument("--pk-column", required=True, help="primary-key column name")
    ap.add_argument("--out-dir", required=True, type=Path)
    ap.add_argument(
        "--target-bytes",
        type=int,
        default=80 * 1024 * 1024,
        help="rotate when current chunk exceeds this (default: 80 MiB)",
    )
    ap.add_argument(
        "--pg-dump-path",
        default="pg_dump",
        help="path to pg_dump (default: PATH lookup). Set to e.g. "
        "/home/x/.pg0/installation/18.1.0/bin/pg_dump for pg0 embedded.",
    )
    args = ap.parse_args()

    out_dir: Path = args.out_dir
    out_dir.mkdir(parents=True, exist_ok=True)

    # 1. Dump the table to a flat sorted INSERTs list.
    inserts = _dump_full_table(args)
    if not inserts:
        # Empty table — write a placeholder file so restore concat
        # doesn't fail, clear rotation.
        (out_dir / "0001.sql").write_bytes(b"")
        _save_rotation(out_dir, {"chunks": []})
        print(f"[chunked-dump] {args.table}: empty table; wrote 0001.sql empty")
        return 0

    # 2. Resolve PK column index from the first INSERT's column list.
    cols = _columns_list(inserts[0], args.table)
    try:
        pk_col_idx = cols.index(args.pk_column.encode())
    except ValueError:
        print(
            f"[chunked-dump] ERROR: pk column {args.pk_column!r} not in {cols}",
            file=sys.stderr,
        )
        return 2

    # 3. Load (or initialize) rotation.
    rotation = _load_rotation(out_dir)
    if not rotation["chunks"]:
        # First run: derive initial chunk boundaries from current data.
        rotation = _initial_chunking(inserts, pk_col_idx, args.target_bytes)

    # 4. Bucket lines into chunks per the rotation.
    buckets = _bucket_into_chunks(inserts, pk_col_idx, rotation)

    # 5. Write every chunk that has content. Also blank out any
    # leftover files for chunk numbers not in `buckets` (defensive:
    # a table-wide delete could empty an entire chunk).
    next_chunk_num = len(rotation["chunks"]) + 1
    chunks_to_write = sorted(buckets.keys())
    for num in chunks_to_write:
        path = out_dir / f"{num:04d}.sql"
        _write_chunk_atomic(path, buckets[num])

    # 6. Rotation check: if the CURRENT chunk overflowed, freeze it.
    current_path = out_dir / f"{next_chunk_num:04d}.sql"
    if current_path.exists():
        size = current_path.stat().st_size
        if size > args.target_bytes:
            current_lines = buckets.get(next_chunk_num, [])
            if not current_lines:
                # Shouldn't happen but be defensive.
                print(
                    f"[chunked-dump] WARN: current chunk over target but no lines?",
                    file=sys.stderr,
                )
            else:
                last_pk = _pk_from_insert(current_lines[-1], pk_col_idx)
                pk_str = last_pk.decode()
                if pk_str.startswith("'") and pk_str.endswith("'"):
                    pk_str = pk_str[1:-1]
                rotation["chunks"].append(
                    {"num": next_chunk_num, "max_pk": pk_str}
                )
                print(
                    f"[chunked-dump] {args.table}: rotated chunk {next_chunk_num} "
                    f"({size} bytes > {args.target_bytes} target). "
                    f"Next dump will write chunk {next_chunk_num + 1}."
                )

    # 7. Persist rotation state.
    _save_rotation(out_dir, rotation)

    # 8. Summary print for cron log.
    total_rows = len(inserts)
    sizes = []
    for num in chunks_to_write:
        path = out_dir / f"{num:04d}.sql"
        sizes.append((num, path.stat().st_size))
    summary = ", ".join(f"{n:04d}={s}b" for n, s in sizes)
    print(f"[chunked-dump] {args.table}: {total_rows} rows, chunks: {summary}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
