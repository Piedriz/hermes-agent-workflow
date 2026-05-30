#!/usr/bin/env python3
"""Reconstruct NULL pgvector embeddings in memory_units after a restore.

Backups drop the bulky `embedding` column (see scripts/lib/chunked-table-dump.py
`--exclude-columns embedding`, wired in scripts/sync-hindsight-bank.sh). It is
derived data — ~96% of the table's dump bytes — so we store only the
source-of-truth columns and rebuild the vectors here, in place, on restore.

Faithful to the retain pipeline's embedding INPUT (this matters: a mismatch
between the doc-embedding input and the original silently degrades recall):

  * observation rows  (consolidation provenance — `source_memory_ids` set):
    the consolidator embeds the RAW `text`. Reconstruction is identity.

  * experience / world rows (retain provenance): retain embeds an AUGMENTED
    string built by hindsight's own
    `retain.embedding_processing.augment_texts_with_dates`:
        "{text} (happened in {Month Year})"   (or "from X to Y" for a range)
      + " [{', '.join(entities)}]"            (when the fact had entities)
    We reuse that function so the augmentation shape can't drift from the
    library. The date is reconstructed exactly from the stored
    occurred_start/occurred_end/mentioned_at columns. The entity suffix is
    BEST-EFFORT: the original used the raw pre-resolution LLM entity text,
    which is ephemeral; we substitute the resolved `entities.canonical_name`
    joined through `unit_entities` (names/order may differ slightly — accepted
    fidelity bar, since the embedding model is itself remote + unpinned so
    re-embeds are never bit-identical anyway).

Idempotent + resumable: only rows WHERE embedding IS NULL are touched, so a
re-run after a partial failure resumes cleanly.

Writes a sidecar manifest (model / provider / dim / utc-ts / count) so a
restored corpus carries a record of HOW its vectors were reconstructed.

Requires the hindsight env (HINDSIGHT_API_EMBEDDINGS_*) to be present — run via
the hindsight server venv python with ~/.hermes/.env sourced:

    set -a; . ~/.hermes/.env; set +a
    ~/.hermes/hindsight-server-venv/bin/python scripts/reembed-hindsight.py \
        --psql-host 127.0.0.1 --psql-port 5432 \
        --psql-user hindsight --psql-database hindsight

Env vars: PGPASSWORD (libpq), HINDSIGHT_API_EMBEDDINGS_* (provider/key/model).
Exits non-zero on any error (set -e safe).
"""
from __future__ import annotations

import argparse
import asyncio
import json
import os
import sys
from datetime import datetime, timezone

import asyncpg

from hindsight_api.engine.embeddings import create_embeddings_from_env
from hindsight_api.engine.retain.embedding_processing import augment_texts_with_dates
from hindsight_api.engine.retain.types import ExtractedFact


def _format_readable_date(dt: datetime) -> str:
    """Mirror MemoryEngine._format_readable_date ("Month Year", e.g. "June 2024").

    Kept in lockstep with hindsight_api/engine/memory_engine.py. The retain
    pipeline passes this as format_date_fn into augment_texts_with_dates; we
    replicate it so the date phrase is byte-identical to the original.
    """
    return f"{dt.strftime('%B')} {dt.strftime('%Y')}"


def _embedding_input(row: dict, entities: list[str]) -> str:
    """Reconstruct the exact text that retain/consolidation fed to encode().

    observation rows embed raw text; everything else gets the date+entity
    augmentation via hindsight's own augment_texts_with_dates.
    """
    text = row["text"]
    is_observation = bool(row["source_memory_ids"]) or row["fact_type"] == "observation"
    if is_observation:
        return text
    fact = ExtractedFact(
        fact_text=text,
        fact_type=row["fact_type"],
        entities=entities,
        occurred_start=row["occurred_start"],
        occurred_end=row["occurred_end"],
        mentioned_at=row["mentioned_at"],
    )
    return augment_texts_with_dates([fact], _format_readable_date)[0]


async def _fetch_entities(
    conn: asyncpg.Connection, unit_ids: list, schema: str
) -> dict:
    """Map unit_id -> [canonical_name, ...] for a batch of units.

    unit_entities carries no ordering column, so order is inherently
    best-effort; ORDER BY canonical_name makes it deterministic across runs.
    """
    if not unit_ids:
        return {}
    rows = await conn.fetch(
        f"""
        SELECT ue.unit_id, e.canonical_name
        FROM {schema}.unit_entities ue
        JOIN {schema}.entities e ON e.id = ue.entity_id
        WHERE ue.unit_id = ANY($1::uuid[])
        ORDER BY ue.unit_id, e.canonical_name
        """,
        unit_ids,
    )
    out: dict = {}
    for r in rows:
        out.setdefault(r["unit_id"], []).append(r["canonical_name"])
    return out


async def _run(args: argparse.Namespace) -> int:
    schema = args.schema

    backend = create_embeddings_from_env()
    await backend.initialize()
    dim = backend.dimension
    provider = backend.provider_name
    model = getattr(backend, "model", None)

    conn = await asyncpg.connect(
        host=args.psql_host,
        port=int(args.psql_port),
        user=args.psql_user,
        database=args.psql_database,
        password=os.environ.get("PGPASSWORD"),
    )
    try:
        total_null = await conn.fetchval(
            f"SELECT count(*) FROM {schema}.memory_units WHERE embedding IS NULL"
        )
        print(
            f"[reembed] {total_null} memory_units rows with NULL embedding "
            f"(provider={provider} model={model} dim={dim})"
        )
        if total_null == 0:
            print("[reembed] nothing to do.")
            _write_manifest(args, provider, model, dim, 0)
            return 0

        done = 0
        sampled = 0
        while True:
            batch = await conn.fetch(
                f"""
                SELECT id, text, fact_type, occurred_start, occurred_end,
                       mentioned_at, source_memory_ids
                FROM {schema}.memory_units
                WHERE embedding IS NULL
                ORDER BY id
                LIMIT $1
                """,
                args.batch_size,
            )
            if not batch:
                break

            ent_map = await _fetch_entities(conn, [r["id"] for r in batch], schema)
            inputs = [_embedding_input(r, ent_map.get(r["id"], [])) for r in batch]

            if args.dry_run:
                for r, txt in list(zip(batch, inputs))[: max(0, args.sample - sampled)]:
                    print(f"  [{r['fact_type']}] {r['id']}\n    -> {txt!r}")
                sampled += len(batch)
                done += len(batch)
                if sampled >= args.sample:
                    print(
                        f"[reembed] dry-run: would re-embed {total_null} rows; "
                        f"showed {args.sample} reconstructed inputs."
                    )
                    return 0
                continue

            vectors = backend.encode(inputs)
            if len(vectors) != len(batch):
                print(
                    f"[reembed] ERROR: encoder returned {len(vectors)} vectors "
                    f"for {len(batch)} inputs",
                    file=sys.stderr,
                )
                return 4

            await conn.executemany(
                f"UPDATE {schema}.memory_units SET embedding = $1::vector WHERE id = $2",
                [(str(vec), r["id"]) for vec, r in zip(vectors, batch)],
            )
            done += len(batch)
            print(f"[reembed] {done}/{total_null} done")

        if args.dry_run:
            print(f"[reembed] dry-run: would re-embed {total_null} rows.")
            return 0

        remaining = await conn.fetchval(
            f"SELECT count(*) FROM {schema}.memory_units WHERE embedding IS NULL"
        )
        if remaining:
            print(
                f"[reembed] WARNING: {remaining} rows still NULL after pass "
                f"(re-run to resume).",
                file=sys.stderr,
            )
        _write_manifest(args, provider, model, dim, done)
        print(f"[reembed] complete: re-embedded {done} rows.")
        return 0
    finally:
        await conn.close()


def _write_manifest(
    args: argparse.Namespace, provider: str, model, dim: int, count: int
) -> None:
    manifest = {
        "reembedded_at": datetime.now(timezone.utc).isoformat(),
        "provider": provider,
        "model": model,
        "dimension": dim,
        "count": count,
        "database": args.psql_database,
    }
    path = args.manifest
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        json.dump(manifest, f, indent=2, sort_keys=True)
        f.write("\n")
    print(f"[reembed] wrote manifest {path}")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--psql-host", default="127.0.0.1")
    ap.add_argument("--psql-port", default="5432")
    ap.add_argument("--psql-user", required=True)
    ap.add_argument("--psql-database", required=True)
    ap.add_argument("--schema", default="public")
    ap.add_argument(
        "--batch-size",
        type=int,
        default=500,
        help="rows fetched + updated per round (encoder self-batches inside)",
    )
    ap.add_argument(
        "--manifest",
        default=os.path.expanduser("~/.hermes/logs/reembed-hindsight-manifest.json"),
        help="where to write the re-embed manifest",
    )
    ap.add_argument(
        "--dry-run",
        action="store_true",
        help="reconstruct + count + print sample inputs, but do NOT call the "
        "encoder or write the DB",
    )
    ap.add_argument(
        "--sample",
        type=int,
        default=10,
        help="how many reconstructed inputs to print under --dry-run",
    )
    args = ap.parse_args()
    return asyncio.run(_run(args))


if __name__ == "__main__":
    sys.exit(main())
