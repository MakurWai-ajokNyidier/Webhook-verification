use serde::{Deserialize, Serialize};
use mongodb::bson::{oid::ObjectId, DateTime};

#[derive(Debug, Serialize, Deserialize, PartialEq, Clone)]
#[serde(rename_all = "snake_case")]
pub enum CheckInStatus {
    NotCheckedIn,
    PendingPrint,
    CheckedIn,
}

pub struct Attendee {
    #[serde(rename = "_id", skip_serializing_if = "Option::is_none")]
    pub id: Option<ObjectId>,
    pub qr_code: String,
    pub name: String,
    pub status: CheckInStatus,
    pub print_job_id: Option<String>,
    pub updated_at: DateTime,
}
pub struct ScanPayload {
    pub qr_code: String,
}

pub struct WebhookPayload {
    pub print_job_id: String,
    pub status: String, // "SUCCESS" or "FAILED"
    pub qr_code: String,
}
use axum::{
    extract::State,
    http::StatusCode,
    response::IntoResponse,
    routing::post,
    Json, Router,
};
use mongodb::{
    bson::{doc, DateTime},
    Client, Collection, Database,
};
use serde_json::json;
use std::sync::Arc;
use uuid::Uuid;

struct AppState {
    db: Database,
}

async fn main() {
    let client = Client::with_uri_str("mongodb://localhost:27017")
        .await
        .expect("Failed to connect to MongoDB");
    let db = client.database("solstice_events");
    let state = AppState { db };

    let app = Router::new()
        .route("/api/scan", post(handle_scan))
        .route("/api/webhook/print-completed", post(handle_webhook))
        .with_state(state);

    let listener = tokio::net::TcpListener::bind("0.0.0.0:3000").await.unwrap();
    println!("Server running on port 3000");
    axum::serve(listener, app).await.unwrap();
}

#Initial Scan
async fn handle_scan(
    State(state): State<AppState>,
    Json(payload): Json<ScanPayload>,
) -> impl IntoResponse {
    let collection: Collection<Attendee> = state.db.collection("attendees");
    let job_id = Uuid::new_v4().to_string();
    
    // update
    let filter = doc! {
        "qr_code": &payload.qr_code,
        "status": "not_checked_in"
    };
    let update = doc! {
        "$set": {
            "status": "pending_print",
            "print_job_id": &job_id,
            "updated_at": DateTime::now()
        }
    };

    let result = collection.find_one_and_update(filter, update, None).await;

    match result {
        Ok(Some(_)) => {
            // Mock publishing to vendor queue.
            tokio::spawn(mock_vendor_queue_publish(payload.qr_code.clone(), job_id));

            (
                StatusCode::ACCEPTED,
                Json(json!({
                    "status": "PENDING_PRINT",
                    "message": "Badge print job queued.",
                    "print_job_id": job_id
                })),
            )
        }
        Ok(None) => (
            StatusCode::CONFLICT,
            Json(json!({
                "status": "DUPLICATE_SCAN",
                "message": "Attendee is already checked in or print is pending."
            })),
        ),
        Err(err) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({ "error": err.to_to_string() })),
        ),
    }
}
// Async Webhook Callback
async fn handle_webhook(
    State(state): State<AppState>,
    Json(payload): Json<WebhookPayload>,
) -> impl IntoResponse {
    let collection: Collection<Attendee> = state.db.collection("attendees");

    if payload.status == "SUCCESS" {
        let filter = doc! {
            "qr_code": &payload.qr_code,
            "print_job_id": &payload.print_job_id,
            "status": "pending_print"
        };
        let update = doc! {
            "$set": {
                "status": "checked_in",
                "updated_at": DateTime::now()
            }
        };

        let result = collection.update_one(filter, update, None).await;

        match result {
            Ok(res) if res.modified_count > 0 => {
                (StatusCode::OK, Json(json!({ "status": "ACKNOWLEDGED" })))
            }
            _ => (
                StatusCode::OK,
                Json(json!({ "status": "IGNORED_OR_ALREADY_PROCESSED" })),
            ),
        }
    } else {
        // Rollback state if print job fails to allow retry
        let filter = doc! { "qr_code": &payload.qr_code, "print_job_id": &payload.print_job_id };
        let update = doc! { "$set": { "status": "not_checked_in", "print_job_id": null } };
        let _ = collection.update_one(filter, update, None).await;

        (StatusCode::OK, Json(json!({ "status": "PRINT_FAILED_RESET" })))
    }
}

async fn mock_vendor_queue_publish(_qr: String, _job_id: String) {
    // Simulates publishing message onto external vendor queue
}
#[tokio::test]
async fn test_async_check_in_flow() {
    let client = mongodb::Client::with_uri_str("mongodb://localhost:27017")
        .await
        .unwrap();
    let db = client.database("solstice_events_test");
    let attendees: mongodb::Collection<models::Attendee> = db.collection("attendees");
    
    attendees.drop(None).await.unwrap();

    // Seed 3 Test Attendees
    let test_data = vec![
        models::Attendee { id: None, qr_code: "QR_001".into(), name: "Alice".into(), status: models::CheckInStatus::NotCheckedIn, print_job_id: None, updated_at: mongodb::bson::DateTime::now() },
        models::Attendee { id: None, qr_code: "QR_002".into(), name: "Bob".into(), status: models::CheckInStatus::NotCheckedIn, print_job_id: None, updated_at: mongodb::bson::DateTime::now() },
        models::Attendee { id: None, qr_code: "QR_003".into(), name: "Charlie".into(), status: models::CheckInStatus::NotCheckedIn, print_job_id: None, updated_at: mongodb::bson::DateTime::now() },
    ];
    attendees.insert_many(test_data, None).await.unwrap();

    // First Scan for Alice -> Returns PENDING_PRINT
    let res1 = simulate_scan_request(&db, "QR_001").await;
    assert_eq!(res1["status"], "PENDING_PRINT");

    // Second Duplicate Scan for Alice while pending -> Blocked (DUPLICATE_SCAN)
    let res2 = simulate_scan_request(&db, "QR_001").await;
    assert_eq!(res2["status"], "DUPLICATE_SCAN");

    // Third Webhook fires for Alice -> Status updates to CHECKED_IN
    let job_id = res1["print_job_id"].as_str().unwrap();
    simulate_webhook_callback(&db, "QR_001", job_id, "SUCCESS").await;

    let alice = attendees.find_one(doc! { "qr_code": "QR_001" }, None).await.unwrap().unwrap();
    assert_eq!(alice.status, models::CheckInStatus::CheckedIn);

    // Forth Duplicate Scan for Alice after success -> Blocked (DUPLICATE_SCAN)
    let res3 = simulate_scan_request(&db, "QR_001").await;
    assert_eq!(res3["status"], "DUPLICATE_SCAN");

    // Fifth Scan Bob & Charlie
    let res_bob = simulate_scan_request(&db, "QR_002").await;
    assert_eq!(res_bob["status"], "PENDING_PRINT");
}
