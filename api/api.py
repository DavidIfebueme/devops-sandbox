#!/usr/bin/env python3
import json
import os
import subprocess
from pathlib import Path
from typing import Optional

from fastapi import FastAPI, HTTPException
from pydantic import BaseModel

PROJECT_DIR = Path(__file__).resolve().parent.parent
ENVS_DIR = PROJECT_DIR / "envs"
PLATFORM_DIR = PROJECT_DIR / "platform"
LOGS_DIR = PROJECT_DIR / "logs"

app = FastAPI(title="DevOps Sandbox API", version="1.0.0")


class CreateEnvRequest(BaseModel):
    name: str
    ttl: Optional[int] = 30


class OutageRequest(BaseModel):
    mode: str


def read_env_state(env_id: str) -> dict:
    state_file = ENVS_DIR / f"{env_id}.json"
    if not state_file.exists():
        raise HTTPException(status_code=404, detail=f"Environment {env_id} not found")
    return json.loads(state_file.read_text())


def get_all_envs() -> list[dict]:
    envs = []
    if not ENVS_DIR.exists():
        return envs
    for f in ENVS_DIR.glob("*.json"):
        try:
            data = json.loads(f.read_text())
            now = int(os.environ.get("NOW", __import__("time").time()))
            remaining = (data["created_at"] + data["ttl"]) - now
            data["ttl_remaining"] = max(0, remaining)
            envs.append(data)
        except (json.JSONDecodeError, KeyError):
            continue
    return envs


@app.post("/envs")
def create_env(req: CreateEnvRequest):
    if not req.name.replace("-", "").replace("_", "").isalnum():
        raise HTTPException(status_code=400, detail="Name must be alphanumeric (hyphens/underscores allowed)")
    if req.ttl < 1 or req.ttl > 1440:
        raise HTTPException(status_code=400, detail="TTL must be between 1 and 1440 minutes")
    try:
        result = subprocess.run(
            ["bash", str(PLATFORM_DIR / "create_env.sh"), req.name, str(req.ttl)],
            capture_output=True, text=True, timeout=30
        )
        if result.returncode != 0:
            raise HTTPException(status_code=500, detail=f"Failed to create env: {result.stderr}")
        envs = get_all_envs()
        newest = max(envs, key=lambda e: e["created_at"]) if envs else None
        return newest or {"message": "Environment created"}
    except subprocess.TimeoutExpired:
        raise HTTPException(status_code=500, detail="Environment creation timed out")


@app.get("/envs")
def list_envs():
    return get_all_envs()


@app.delete("/envs/{env_id}")
def destroy_env(env_id: str):
    state = read_env_state(env_id)
    result = subprocess.run(
        ["bash", str(PLATFORM_DIR / "destroy_env.sh"), env_id],
        capture_output=True, text=True, timeout=30
    )
    if result.returncode != 0:
        raise HTTPException(status_code=500, detail=f"Failed to destroy env: {result.stderr}")
    return {"message": f"Environment {env_id} destroyed", "env": state}


@app.get("/envs/{env_id}/logs")
def get_env_logs(env_id: str):
    read_env_state(env_id)
    log_file = LOGS_DIR / env_id / "app.log"
    if not log_file.exists():
        return {"env_id": env_id, "logs": []}
    lines = log_file.read_text().strip().split("\n")
    return {"env_id": env_id, "logs": lines[-100:]}


@app.get("/envs/{env_id}/health")
def get_env_health(env_id: str):
    read_env_state(env_id)
    health_log = LOGS_DIR / env_id / "health.log"
    if not health_log.exists():
        return {"env_id": env_id, "checks": []}
    lines = health_log.read_text().strip().split("\n")
    checks = []
    for line in lines[-10:]:
        parts = line.split("|")
        if len(parts) >= 3:
            checks.append({"timestamp": parts[0], "status": int(parts[1]), "latency": parts[2]})
    return {"env_id": env_id, "checks": checks}


@app.post("/envs/{env_id}/outage")
def trigger_outage(env_id: str, req: OutageRequest):
    read_env_state(env_id)
    valid_modes = ("crash", "pause", "network", "recover", "stress")
    if req.mode not in valid_modes:
        raise HTTPException(status_code=400, detail=f"Mode must be one of: {', '.join(valid_modes)}")
    result = subprocess.run(
        ["bash", str(PLATFORM_DIR / "simulate_outage.sh"), "--env", env_id, "--mode", req.mode],
        capture_output=True, text=True, timeout=30
    )
    if result.returncode != 0:
        raise HTTPException(status_code=500, detail=f"Simulation failed: {result.stderr}")
    return {"env_id": env_id, "mode": req.mode, "output": result.stdout}


@app.get("/health")
def api_health():
    return {"status": "ok", "service": "devops-sandbox-api"}
