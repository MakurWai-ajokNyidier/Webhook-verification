# Express.js & MongoDB Webhook Verification Service

A Node.js backend application built with Express.js and MongoDB to receive, authenticate, and process webhook payloads for warehouse stock verification.

## Features

* **HMAC Signature Verification:** Authenticates incoming webhooks using HMAC-SHA256 to ensure request integrity and prevent unauthorized payload delivery.
* **Raw Body Parsing:** Preserves original byte streams (`req.rawBody`) during JSON parsing to ensure signature match accuracy.
* **Stock Verification:** Queries MongoDB to validate item existence (`sku`) and check if available quantity meets or exceeds requested levels.

---

## Technical Stack

* **Runtime:** Node.js
* **Framework:** Express.js
* **Database:** MongoDB / Mongoose ODM
* **Security:** Crypto (HMAC-SHA256)

---

## Installation & Setup

1. **Clone the repository:**
   ```bash
   npm install
   PORT=3000
MONGODB_URI=mongodb://127.0.0.1:27017/inventory_db
WEBHOOK_SECRET=your_shared_secret_key
npm start
{
  "sku": "ITEM-101",
  "requestedQuantity": 5
}
{
  "status": "success",
  "valid": true,
  "message": "Item is valid and in stock.",
  "availableStock": 15
}
{
  "status": "insufficient_stock",
  "valid": false,
  "message": "Item exists but requested quantity exceeds stock.",
  "availableStock": 2
}
{
  "error": "Invalid signature"
}
   git clone [https://github.com/MakurWai-ajokNyidier/Webhook-verification.git](https://github.com/MakurWai-ajokNyidier/Webhook-verification.git)
   cd Webhook-verification
