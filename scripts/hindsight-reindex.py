#!/usr/bin/env python3
"""Backfill historical state.db messages into the Hindsight memory bank.

Forward-only retention + lazy daemon means Hindsight starts empty at
install. This script walks messages written BEFORE the daemon was
enabled and calls retain_batch so semantic queries can reach them.

Idempotent: a checkpoint file tracks the last message id retained per
bank. Re-running continues where the previous run stopped (Ctrl-C,
daemon restart, whatever).

Resource-aware: single-message batches by default. The daemon holds one
batch at a time in memory while doing LLM entity extraction; --batch
tunes how many messages share one LLM call. Larger = less overhead but
more peak RAM during the call. On pi5 class hardware, default 1 is
safe; 5–10 is reasonable on a desktop.

Run with:
    python3 scripts/hindsight-reindex.py --dry-run
    python3 scripts/hindsight-reindex.py --limit 10       # sanity check
    python3 scripts/hindsight-reindex.py --resume         # full run
    python3 scripts/hindsight-reindex.py --since 2026-04-01
"""
from __future__ import annotations

import argparse
import asyncio
import inspect
import json
import os
import sqlite3
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

STATE_DB = Path.home() / ".hermes" / "state.db"
HINDSIGHT_CFG = Path.home() / ".hermes" / "hindsight" / "config.json"
HERMES_ENV = Path.home() / ".hermes" / ".env"
CHECKPOINT = Path.home() / ".hermes" / "hindsight" / "backfill.checkpoint"

# Skip messages that are almost certainly not worth indexing. The query
# already filters role + length; these are extra guards against boilerplate.
SKIP_CONTENT_PREFIXES = (
    "Session reset",
    "[system]",
)


def parse_env_file(path: Path) -> dict[str, str]:
    env: dict[str, str] = {}
    if not path.exists():
        return env
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, v = line.split("=", 1)
        env[k.strip()] = v.strip().strip('"').strip("'")
    return env


def load_hindsight_config() -> dict:
    if not HINDSIGHT_CFG.exists():
        sys.exit(f"hindsight config missing: {HINDSIGHT_CFG}")
    return json.loads(HINDSIGHT_CFG.read_text())


def load_checkpoint(bank_id: str) -> int:
    """Return the highest message id that has been retained for this bank."""
    if not CHECKPOINT.exists():
        return 0
    try:
        data = json.loads(CHECKPOINT.read_text())
    except Exception:
        return 0
    return int(data.get(bank_id, 0))


def save_checkpoint(bank_id: str, max_id: int) -> None:
    data: dict = {}
    if CHECKPOINT.exists():
        try:
            data = json.loads(CHECKPOINT.read_text())
        except Exception:
            pass
    data[bank_id] = max_id
    CHECKPOINT.parent.mkdir(parents=True, exist_ok=True)
    CHECKPOINT.write_text(json.dumps(data, indent=2))


def enumerate_messages(
    conn: sqlite3.Connection,
    *,
    after_id: int,
    since_ts: float | None,
    limit: int | None,
):
    """Oldest → newest so the entity graph builds incrementally."""
    where = [
        "m.role IN ('user', 'assistant')",
        "m.content IS NOT NULL",
        "LENGTH(TRIM(m.content)) > 20",
        "s.parent_session_id IS NULL",
        "s.source != 'tool'",
        f"m.id > {after_id}",
    ]
    if since_ts is not None:
        where.append(f"m.timestamp >= {since_ts}")
    sql = f"""
        SELECT m.id, m.session_id, m.role, m.content, m.timestamp,
               s.source, s.title
        FROM messages m JOIN sessions s ON s.id = m.session_id
        WHERE {' AND '.join(where)}
        ORDER BY m.id ASC
    """
    if limit:
        sql += f" LIMIT {limit}"
    for row in conn.execute(sql):
        yield row


def build_item(msg_id: int, session_id: str, role: str, content: str,
               timestamp: float, source: str, title: str | None) -> dict:
    ts_human = datetime.fromtimestamp(timestamp, tz=timezone.utc).isoformat()
    context = (
        f"Historical {role} turn from {source} session "
        f"{session_id[:12]} at {ts_human}"
    )
    if title:
        context += f" (session: {title})"
    return {
        "content": content,
        "timestamp": datetime.fromtimestamp(timestamp, tz=timezone.utc),
        "context": context,
        "metadata": {
            "source": "backfill",
            "session_id": session_id,
            "platform": source,
            "original_message_id": str(msg_id),
            "original_timestamp": str(timestamp),
            "role": role,
        },
        "tags": ["backfill", source],
    }


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--dry-run", action="store_true",
                    help="Count + preview; do not retain or update checkpoint.")
    ap.add_argument("--limit", type=int, default=None,
                    help="Stop after N messages (useful for --dry-run or smoke tests).")
    ap.add_argument("--batch", type=int, default=1,
                    help="Messages per retain_batch call. Default 1 (safest RAM). "
                         "5–10 reduces LLM overhead on non-Pi hardware.")
    ap.add_argument("--since", type=str, default=None,
                    help="Only messages at/after this ISO date (e.g. 2026-04-01).")
    ap.add_argument("--resume", action="store_true",
                    help="Continue from the checkpoint file. Default behaviour is "
                         "a fresh walk (checkpoint is IGNORED unless --resume).")
    ap.add_argument("--reset-checkpoint", action="store_true",
                    help="Delete the checkpoint and exit.")
    args = ap.parse_args()

    cfg = load_hindsight_config()
    bank_id: str = cfg.get("bank_id", "default")

    if args.reset_checkpoint:
        if CHECKPOINT.exists():
            CHECKPOINT.unlink()
            print(f"[reindex] removed {CHECKPOINT}")
        else:
            print("[reindex] no checkpoint file")
        return 0

    after_id = load_checkpoint(bank_id) if args.resume else 0
    since_ts: float | None = None
    if args.since:
        since_ts = datetime.fromisoformat(args.since).replace(tzinfo=timezone.utc).timestamp()

    if not STATE_DB.exists():
        sys.exit(f"state.db missing: {STATE_DB}")
    # Read-only connection so a concurrent hermes write can't corrupt
    # anything if the daemon is also touching state.db.
    conn = sqlite3.connect(f"file:{STATE_DB}?mode=ro", uri=True)
    conn.row_factory = sqlite3.Row

    print(f"[reindex] bank={bank_id} after_id={after_id} "
          f"since={args.since or '-'} batch={args.batch} "
          f"limit={args.limit or '-'} dry_run={args.dry_run}")

    items: list[dict] = []
    item_ids: list[int] = []
    last_id = after_id
    retained = 0
    skipped = 0

    if not args.dry_run:
        mode = cfg.get("mode", "local_embedded")
        if mode == "local_external":
            # HTTP client: server runs out-of-process (systemd unit
            # hindsight-server.service); LLM/embeddings/reranker config
            # lives on the server side, not here.
            try:
                from hindsight_client import Hindsight  # type: ignore
            except ModuleNotFoundError:
                sys.exit(
                    "hindsight_client not importable from this python.\n"
                    "Run with the hermes venv:\n"
                    f"  ~/.hermes/hermes-agent/venv/bin/python {sys.argv[0]} {' '.join(sys.argv[1:])}"
                )
            api_url = cfg.get("api_url", "http://127.0.0.1:8765")
            client = Hindsight(base_url=api_url)
        else:
            # local_embedded fallback (in-process LLM + DB).
            try:
                from hindsight import HindsightEmbedded  # type: ignore
            except ModuleNotFoundError:
                sys.exit(
                    "hindsight package missing. Install hindsight-all into the hermes "
                    "venv:\n  ~/.hermes/hermes-agent/venv/bin/pip3 install hindsight-all"
                )

            env = parse_env_file(HERMES_ENV)
            llm_provider = cfg.get("llm_provider", "openai_compatible")
            # The hindsight plugin normalizes openai_compatible/openrouter → openai.
            # Matching that normalization here so model auth matches whatever
            # the live daemon expects.
            if llm_provider in ("openai_compatible", "openrouter"):
                llm_provider = "openai"
            kwargs = dict(
                profile=cfg.get("profile", "hermes"),
                llm_provider=llm_provider,
                llm_api_key=env.get("HINDSIGHT_LLM_API_KEY", "") or env.get("OPENROUTER_API_KEY", ""),
                llm_model=cfg.get("llm_model", ""),
            )
            # openrouter's OpenAI-compatible endpoint — hindsight config doesn't
            # set this explicitly but it's required for the openai provider to
            # hit openrouter instead of api.openai.com.
            if cfg.get("llm_provider") in ("openrouter",):
                kwargs["llm_base_url"] = "https://openrouter.ai/api/v1"
            client = HindsightEmbedded(**kwargs)
    else:
        client = None

    def close_client() -> None:
        if client is None:
            return
        close = getattr(client, "close", None)
        if not callable(close):
            close = getattr(client, "aclose", None)
        if not callable(close):
            return
        result = close()
        if inspect.isawaitable(result):
            asyncio.run(result)

    def flush() -> None:
        nonlocal retained, last_id
        if not items:
            return
        if args.dry_run:
            preview = items[0]["content"][:80].replace("\n", " ")
            print(f"[reindex] would retain {len(items)} items "
                  f"(ids {item_ids[0]}..{item_ids[-1]}): {preview!r}")
        else:
            try:
                resp = client.retain_batch(bank_id=bank_id, items=items)
                count = getattr(resp, "item_count", None) or len(items)
                print(f"[reindex] retained {count} items "
                      f"(ids {item_ids[0]}..{item_ids[-1]})")
            except Exception as e:
                print(f"[reindex] ERROR retaining ids {item_ids[0]}..{item_ids[-1]}: {e}",
                      file=sys.stderr)
                # Don't update last_id — next run retries this batch.
                items.clear()
                item_ids.clear()
                raise
            retained += len(items)
            last_id = item_ids[-1]
            save_checkpoint(bank_id, last_id)
        items.clear()
        item_ids.clear()

    t0 = time.time()
    try:
        try:
            for row in enumerate_messages(conn, after_id=after_id, since_ts=since_ts, limit=args.limit):
                content = (row["content"] or "").strip()
                if any(content.startswith(p) for p in SKIP_CONTENT_PREFIXES):
                    skipped += 1
                    continue
                items.append(build_item(
                    msg_id=row["id"],
                    session_id=row["session_id"],
                    role=row["role"],
                    content=content,
                    timestamp=row["timestamp"],
                    source=row["source"],
                    title=row["title"],
                ))
                item_ids.append(row["id"])
                if len(items) >= args.batch:
                    flush()
            flush()  # drain tail
        except KeyboardInterrupt:
            print("[reindex] interrupted — checkpoint preserved; rerun with --resume",
                  file=sys.stderr)
            return 130
    finally:
        close_client()

    dt = time.time() - t0
    print(f"[reindex] done. retained={retained} skipped={skipped} "
          f"last_id={last_id} elapsed={dt:.1f}s")
    return 0


if __name__ == "__main__":
    sys.exit(main())
