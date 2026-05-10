use axum::{Json, Router, routing::get};
use serde_json::{json, Value};
use std::env;
use std::time::Instant;
use tokio::net::TcpListener;

static STARTED: std::sync::OnceLock<Instant> = std::sync::OnceLock::new();

async fn index() -> Json<Value> {
    let env_id = env::var("ENV_ID").unwrap_or_else(|_| "unknown".into());
    let started = STARTED.get().unwrap();
    let uptime = started.elapsed().as_secs();
    Json(json!({
        "message": format!("Hello from environment {}", env_id),
        "env_id": env_id,
        "uptime_seconds": uptime,
    }))
}

async fn health() -> Json<Value> {
    let env_id = env::var("ENV_ID").unwrap_or_else(|_| "unknown".into());
    Json(json!({"status": "healthy", "env_id": env_id}))
}

#[tokio::main]
async fn main() {
    STARTED.set(Instant::now()).unwrap();

    let app = Router::new()
        .route("/", get(index))
        .route("/health", get(health));

    let listener = TcpListener::bind("0.0.0.0:8080").await.unwrap();
    axum::serve(listener, app).await.unwrap();
}
