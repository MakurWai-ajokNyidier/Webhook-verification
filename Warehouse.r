[package]
name = "warehouse_polling_service"
version = "0.1.0"
edition = "2021"

[dependencies]
axum = "0.7"
tokio = { version = "1.0", features = ["full"] }
mongodb = "2.8"
reqwest = { version = "0.11", features = ["json"] }
serde = { version = "1.0", features = ["derive"] }
serde_json = "1.0"
use axum::{
    extract::{Path, State},
    http::StatusCode,
    response::IntoResponse,
    routing::get,
    Json, Router,
};
use mongodb::{
    bson::{doc, DateTime},
    Client, Collection, Database,
};
use serde::{Deserialize, Serialize};
use serde_json::json;
use std::time::Duration;

#[derive(Clone)]
struct AppState {
    db: Database,
}

#[derive(Debug, Serialize, Deserialize)]
struct InventoryItem {
    pub sku: String,
    pub name: String,
    pub stock_quantity: i32,
    pub last_synced_at: DateTime,
}

#[tokio::main]
async fn main() {
    let client = Client::with_uri_str("mongodb://localhost:27017")
        .await
        .expect("Failed to connect to MongoDB");
    let db = client.database("warehouse_db");
    let state = AppState { db: db.clone() };

    // Spawn background worker to poll warehouse API every 5 minutes (300 seconds)
    tokio::spawn(async move {
        poll_warehouse_cron(db).await;
    });

    let app = Router::new()
        .route("/api/stock/:sku", get(get_cached_stock))
        .with_state(state);

    let listener = tokio::net::TcpListener::bind("0.0.0.0:3000").await.unwrap();
    println!("Server running on http://0.0.0.0:3000");
    axum::serve(listener, app).await.unwrap();
}

// Background Cron Task: Polls external API every 5 minutes
async fn poll_warehouse_cron(db: Database) {
    let mut interval = tokio::time::interval(Duration::from_secs(300));
    let client = reqwest::Client::new();
    let warehouse_url = std::env::var("WAREHOUSE_API_URL")
        .unwrap_or_else(|_| "https://api.warehouse.example.com/v1/inventory".into());

    loop {
        interval.tick().await;
        println!("Polling warehouse API for stock updates...");

        match client.get(&warehouse_url).send().await {
            Ok(response) => {
                if let Ok(items) = response.json::<Vec<serde_json::Value>>().await {
                    let collection: Collection<InventoryItem> = db.collection("inventory");

                    for item in items {
                        if let (Some(sku), Some(qty)) = (
                            item["sku"].as_str(),
                            item["stock_quantity"].as_i64(),
                        ) {
                            let filter = doc! { "sku": sku };
                            let update = doc! {
                                "$set": {
                                    "sku": sku,
                                    "name": item["name"].as_str().unwrap_or("Unknown"),
                                    "stock_quantity": qty as i32,
                                    "last_synced_at": DateTime::now()
                                }
                            };
                            let options = mongodb::options::UpdateOptions::builder()
                                .upsert(true)
                                .build();

                            let _ = collection.update_one(filter, update, options).await;
                        }
                    }
                    println!("Successfully updated cached inventory stock.");
                }
            }
            Err(err) => eprintln!("Failed to poll warehouse API: {}", err),
        }
    }
}

// Query Endpoint: Exposes cached stock data from MongoDB
async fn get_cached_stock(
    State(state): State<AppState>,
    Path(sku): Path<String>,
) -> impl IntoResponse {
    let collection: Collection<InventoryItem> = state.db.collection("inventory");

    match collection.find_one(doc! { "sku": &sku }, None).await {
        Ok(Some(item)) => (
            StatusCode::OK,
            Json(json!({
                "sku": item.sku,
                "name": item.name,
                "stock_quantity": item.stock_quantity,
                "last_synced_at": item.last_synced_at
            })),
        ),
        Ok(None) => (
            StatusCode::NOT_FOUND,
            Json(json!({ "error": "Item SKU not found in cache" })),
        ),
        Err(err) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({ "error": err.to_string() })),
        ),
    }
}
