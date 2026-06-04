#!/usr/bin/env python3
"""Rotate Hermes cron scheduling timezone and refresh next_run_at values.

TARGET_HERMES_TIMEZONE controls the target IANA timezone; defaults to Europe/London.
This intentionally preserves wall-clock times for one-shot and interval jobs when
moving between travel timezones, while cron expressions are recomputed as future
runs in the target zone.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
from datetime import datetime, timedelta
from pathlib import Path
from zoneinfo import ZoneInfo

import yaml
from croniter import croniter

HOME = Path.home() / ".hermes"
CONFIG_PATH = HOME / "config.yaml"
JOBS_PATH = HOME / "cron" / "jobs.json"
TARGET = os.environ.get("TARGET_HERMES_TIMEZONE", "Europe/London").strip() or "Europe/London"
TARGET_TZ = ZoneInfo(TARGET)


def aware(dt: datetime) -> datetime:
    if dt.tzinfo is None:
        return dt.replace(tzinfo=datetime.now().astimezone().tzinfo).astimezone(TARGET_TZ)
    return dt.astimezone(TARGET_TZ)


def parse_dt(value: str | None) -> datetime | None:
    if not value:
        return None
    try:
        return aware(datetime.fromisoformat(str(value)))
    except Exception:
        return None


def preserve_wall(value: str | None) -> str | None:
    if not value:
        return None
    try:
        old = datetime.fromisoformat(str(value))
    except Exception:
        return None
    return old.replace(tzinfo=TARGET_TZ).isoformat()


def set_config_timezone() -> str | None:
    cfg = {}
    old = None
    if CONFIG_PATH.exists():
        cfg = yaml.safe_load(CONFIG_PATH.read_text(encoding="utf-8")) or {}
        old = cfg.get("timezone")
    cfg["timezone"] = TARGET
    CONFIG_PATH.write_text(yaml.safe_dump(cfg, sort_keys=False, allow_unicode=True), encoding="utf-8")
    try:
        os.chmod(CONFIG_PATH, 0o600)
    except OSError:
        pass
    return old


def rotate_jobs() -> tuple[int, Path | None]:
    if not JOBS_PATH.exists():
        return 0, None

    data = json.loads(JOBS_PATH.read_text(encoding="utf-8"))
    jobs = data.get("jobs", [])
    backup = JOBS_PATH.with_name(f"jobs.json.bak-tz-{datetime.now().strftime('%Y%m%d%H%M%S')}")
    shutil.copy2(JOBS_PATH, backup)

    now = datetime.now(TARGET_TZ)
    changed = 0

    for job in jobs:
        schedule = job.get("schedule") or {}
        if not isinstance(schedule, dict):
            continue
        kind = schedule.get("kind")
        state = job.get("state", "scheduled")
        enabled = job.get("enabled", True)

        # Completed one-shots stay completed.
        if kind == "once" and job.get("last_run_at"):
            continue

        if kind == "cron":
            expr = schedule.get("expr")
            if not expr:
                continue
            # Recompute the next future wall-clock occurrence in the target timezone.
            next_run = croniter(expr, now).get_next(datetime).isoformat()
            if enabled and state != "paused":
                job["next_run_at"] = next_run
                changed += 1

        elif kind == "interval":
            minutes = int(schedule.get("minutes") or 0)
            if minutes <= 0:
                continue
            existing_next = parse_dt(job.get("next_run_at"))
            preserved = preserve_wall(job.get("next_run_at"))
            if preserved and existing_next and existing_next >= now:
                next_run = preserved
            else:
                next_run = (now + timedelta(minutes=minutes)).isoformat()
            if enabled and state != "paused":
                job["next_run_at"] = next_run
                changed += 1

        elif kind == "once":
            run_at = schedule.get("run_at")
            shifted = preserve_wall(run_at)
            if not shifted:
                continue
            schedule["run_at"] = shifted
            if enabled and state != "paused":
                shifted_dt = parse_dt(shifted)
                job["next_run_at"] = shifted if shifted_dt and shifted_dt >= now else None
                changed += 1

    data["updated_at"] = now.isoformat()
    tmp = JOBS_PATH.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(data, indent=2, ensure_ascii=False), encoding="utf-8")
    tmp.replace(JOBS_PATH)
    try:
        os.chmod(JOBS_PATH, 0o600)
    except OSError:
        pass
    return changed, backup


def maybe_restart_gateway() -> None:
    if os.environ.get("RESTART_HERMES_GATEWAY", "1").lower() in {"0", "false", "no"}:
        return
    # Delay so cron delivery/current replies have a chance to flush before the gateway restarts.
    subprocess.Popen(
        ["bash", "-lc", "sleep 8; systemctl --user restart hermes-gateway >/tmp/hermes-cron-tz-restart.log 2>&1"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
    )


def main() -> None:
    old = set_config_timezone()
    changed, backup = rotate_jobs()
    maybe_restart_gateway()
    print(f"Hermes cron timezone: {old or '(unset/server-local)'} → {TARGET}. Refreshed {changed} job(s). Backup: {backup}")


if __name__ == "__main__":
    main()
