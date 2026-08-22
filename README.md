[package]
name = "webhook_verification"
version = "0.1.0"
edition = "2021"

[dependencies]
axum = "0.7"
tokio = { version = "1.0", features = ["full"] }
mongodb = "2.8"
serde = { version = "1.0", features = ["derive"] }
serde_json = "1.0"
hmac = "0.12"
sha2 = "0.10"
hex = "0.4"
subtle = "2.5"
uuid = { version = "1.6", features = ["v4"] }
use axum::{body::Bytes, http::StatusCode};
use hmac::{Hmac, Mac};
use sha2::Sha256;
use subtle::ConstantTimeEq;

type HmacSha256 = Hmac<Sha256>;

pub fn verify_webhook_signature(
    secret: &str,
    signature_header: Option<&str>,
    body: &Bytes,
) -> Result<(), StatusCode> {
    let signature = signature_header
        .and_then(|header| header.strip_prefix("sha256="))
        .ok_or(StatusCode::UNAUTHORIZED)?;

    let expected_bytes = hex::decode(signature).map_err(|_| StatusCode::BAD_REQUEST)?;

    let mut mac = HmacSha256::new_from_slice(secret.as_bytes())
        .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
    mac.update(body);

    let result = mac.finalize().into_bytes();

    if result.ct_eq(&expected_bytes[..]).into() {
        Ok(())
    } else {
        Err(StatusCode::FORBIDDEN)
    }
}
use axum::{
    body::Bytes,
    extract::State,
    http::{HeaderMap, StatusCode},
    response::IntoResponse,
    routing::post,
    Json, Router,
};
use mongodb::{
    bson::{doc, DateTime},
    Client, Collection, Database,
};
use serde::{Deserialize, Serialize};
use serde_json::json;
use uuid::Uuid;

mod middleware;

#[derive(Clone)]
struct AppState {
    db: Database,
    webhook_secret: String,
}

#[derive(Debug, Serialize, Deserialize)]
struct Attendee {
    pub qr_code: String,
    pub status: String,
    pub print_job_id: Option<String>,
}

#[derive(Debug, Deserialize)]
struct WebhookPayload {
    pub qr_code: String,
    pub print_job_id: String,
    pub status: String,
}

#[tokio::main]
async fn main() {
    let client = Client::with_uri_str("mongodb://localhost:27017")
        .await
        .expect("MongoDB connection failed");

    let state = AppState {
        db: client.database("solstice_events"),
        webhook_secret: std::env::var("WEBHOOK_SECRET").unwrap_or_else(|_| "secret_key".into()),
    };

    let app = Router::new()
        .route("/api/scan", post(handle_scan))
        .route("/api/webhook/print-completed", post(handle_webhook))
        .with_state(state);

    let listener = tokio::net::TcpListener::bind("0.0.0.0:3000").await.unwrap();
    println!("Server running on http://0.0.0.0:3000");
    axum::serve(listener, app).await.unwrap();
}

async fn handle_scan(
    State(state): State<AppState>,
    Json(payload): Json<serde_json::Value>,
) -> impl IntoResponse {
    let qr_code = payload["qr_code"].as_str().unwrap_or_default();
    let collection: Collection<Attendee> = state.db.collection("attendees");
    let job_id = Uuid::new_v4().to_string();

    // Atomic update: transition to pending_print only if current status is "not_checked_in"
    let filter = doc! { "qr_code": qr_code, "status": "not_checked_in" };
    let update = doc! {
        "$set": {
            "status": "pending_print",
            "print_job_id": &job_id,
            "updated_at": DateTime::now()
        }
    };

    match collection.find_one_and_update(filter, update, None).await {
        Ok(Some(_)) => (
            StatusCode::ACCEPTED,
            Json(json!({ "status": "PENDING_PRINT", "print_job_id": job_id })),
        ),
        _ => (
            StatusCode::CONFLICT,
            Json(json!({ "status": "DUPLICATE_SCAN", "message": "Already checked in or processing." })),
        ),
    }
}

async fn handle_webhook(
    State(state): State<AppState>,
    headers: HeaderMap,
    body: Bytes,
) -> impl IntoResponse {
    // 1. Authenticate signature using raw body bytes
    let sig_header = headers.get("x-webhook-signature").and_then(|h| h.to_str().ok());
    if let Err(status) = middleware::auth::verify_webhook_signature(&state.webhook_secret, sig_header, &body) {
        return (status, Json(json!({ "error": "Invalid signature" })));
    }

    // 2. Parse payload after authentication
    let payload: WebhookPayload = match serde_json::from_slice(&body) {
        Ok(p) => p,
        Err(_) => return (StatusCode::BAD_REQUEST, Json(json!({ "error": "Malformed JSON" }))),
    };

    let collection: Collection<Attendee> = state.db.collection("attendees");

    if payload.status == "SUCCESS" {
        let filter = doc! {
            "qr_code": &payload.qr_code,
            "print_job_id": &payload.print_job_id,
            "status": "pending_print"
        };
        let update = doc! { "$set": { "status": "checked_in", "updated_at": DateTime::now() } };

        let _ = collection.update_one(filter, update, None).await;
        (StatusCode::OK, Json(json!({ "status": "ACKNOWLEDGED" })))
    } else {
        // Reset state on print failure to allow re-scans
        let filter = doc! { "qr_code": &payload.qr_code, "print_job_id": &payload.print_job_id };
        let update = doc! { "$set": { "status": "not_checked_in", "print_job_id": null } };
        let _ = collection.update_one(filter, update, None).await;
        (StatusCode::OK, Json(json!({ "status": "RESET_DUE_TO_FAILURE" })))
    }
}
