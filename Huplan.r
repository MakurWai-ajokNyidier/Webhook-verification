use axum::{
    body::Bytes,
    extract::State,
    http::{HeaderMap, StatusCode},
    response::IntoResponse,
    routing::post,
};
use mongodb::{bson::{doc, DateTime}, Client, Collection, Database};
use serde::{Deserialize, Serialize};
use serde_json::json;


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
    
    let state = AppState {
        db: client.database("solstice_events"),
        webhook_secret: std::env::var("WEBHOOK_SECRET").unwrap_or_else(|_| "secret_key".into()),
    };

    let app = Router::new()
        .route("/api/scan", post(handle_scan))
        .route("/api/webhook/print-completed", post(handle_webhook))
        .with_state(state);

    let listener = tokio::net::TcpListener::bind("0.0.0.0:3000").await.unwrap();
    axum::serve(listener, app).await.unwrap();
}

async fn handle_scan(
    State(state): State<AppState>,
    Json(payload): Json<serde_json::Value>,
) -> impl IntoResponse {
    let qr_code = payload["qr_code"].as_str().unwrap_or_default();
    let collection: Collection<Attendee> = state.db.collection("attendees");
    let job_id = Uuid::new_v4().to_string();

    // Atomic update: only lock if status is currently "not_checked_in"
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
    // 1. Authenticate incoming webhook payload signature
    let sig_header = headers.get("x-webhook-signature").and_then(|h| h.to_str().ok());
    if let Err(status) = middleware::auth::verify_webhook_signature(&state.webhook_secret, sig_header, &body) {
        return (status, Json(json!({ "error": "Invalid signature" })));
    }

    // 2. Parse payload after successful verification
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
        // Reset state on print failure
        let filter = doc! { "qr_code": &payload.qr_code, "print_job_id": &payload.print_job_id };
        let update = doc! { "$set": { "status": "not_checked_in", "print_job_id": null } };
        let _ = collection.update_one(filter, update, None).await;
        (StatusCode::OK, Json(json!({ "status": "RESET_DUE_TO_FAILURE" })))
    }
}
