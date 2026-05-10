#!/usr/bin/env python3
import json
import os
import time
import requests
from pathlib import Path

PROJECT_DIR = Path(__file__).resolve().parent.parent
ENVS_DIR = PROJECT_DIR / "envs"
POLL_INTERVAL = 30
FAILURE_THRESHOLD = 3
NGINX_BASE = os.environ.get("NGINX_BASE_URL", "http://localhost")


def get_active_envs():
    envs = []
    if not ENVS_DIR.exists():
        return envs
    for f in ENVS_DIR.glob("*.json"):
        try:
            data = json.loads(f.read_text())
            if data.get("status") in ("running", "degraded"):
                envs.append(data)
        except (json.JSONDecodeError, KeyError):
            continue
    return envs


def check_health(env_id):
    url = f"{NGINX_BASE}/{env_id}/health"
    try:
        start = time.monotonic()
        resp = requests.get(url, timeout=5)
        latency = round((time.monotonic() - start) * 1000, 2)
        return resp.status_code, latency
    except requests.RequestException:
        return 0, -1


def write_health_log(env_id, timestamp, status_code, latency_ms):
    log_dir = PROJECT_DIR / "logs" / env_id
    log_dir.mkdir(parents=True, exist_ok=True)
    log_file = log_dir / "health.log"
    with open(log_file, "a") as f:
        f.write(f"{timestamp}|{status_code}|{latency_ms}ms\n")


def update_env_status(env_id, new_status):
    state_file = ENVS_DIR / f"{env_id}.json"
    if not state_file.exists():
        return
    data = json.loads(state_file.read_text())
    if data.get("status") != new_status:
        data["status"] = new_status
        tmp = state_file.with_suffix(".tmp")
        tmp.write_text(json.dumps(data, indent=2))
        tmp.rename(state_file)


def get_consecutive_failures(env_id):
    log_file = PROJECT_DIR / "logs" / env_id / "health.log"
    if not log_file.exists():
        return 0
    lines = log_file.read_text().strip().split("\n")
    count = 0
    for line in reversed(lines):
        parts = line.split("|")
        if len(parts) < 2:
            continue
        code = int(parts[1])
        if code != 200:
            count += 1
        else:
            break
    return count


def main():
    print(f"Health poller started (every {POLL_INTERVAL}s)")
    while True:
        envs = get_active_envs()
        for env_data in envs:
            env_id = env_data["id"]
            timestamp = time.strftime("%Y-%m-%dT%H:%M:%S%z")
            status_code, latency = check_health(env_id)
            write_health_log(env_id, timestamp, status_code, latency)

            if status_code != 200:
                failures = get_consecutive_failures(env_id)
                if failures >= FAILURE_THRESHOLD:
                    update_env_status(env_id, "degraded")
                    ts = time.strftime("%H:%M:%S")
                    print(f"[{ts}] WARNING: {env_id} is DEGRADED ({failures} consecutive failures)")
                else:
                    ts = time.strftime("%H:%M:%S")
                    print(f"[{ts}] {env_id} health check failed ({failures}/{FAILURE_THRESHOLD})")
            else:
                current_status = env_data.get("status")
                if current_status == "degraded":
                    update_env_status(env_id, "running")
                    ts = time.strftime("%H:%M:%S")
                    print(f"[{ts}] {env_id} recovered, status → running")

        time.sleep(POLL_INTERVAL)


if __name__ == "__main__":
    main()
