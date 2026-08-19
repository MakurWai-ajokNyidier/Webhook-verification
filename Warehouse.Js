import Redis from 'ioredis';
import express from 'express';
import axios from 'axios';
import cron from 'node-cron';

const app = express();
const redis = new Redis(process.env.REDIS_URL);

// Function to update cache in bulk
async function updateStockCache(stockData) {
  const pipeline = redis.pipeline();
  
  for (const item of stockData) {
    // Key format: stock:<SKU> -> value: JSON string
    pipeline.set(`stock:${item.sku}`, JSON.stringify({
      quantity: item.quantity,
      location: item.location,
      updatedAt: new Date().toISOString()
    }), 'EX', 900); // 15-minute expiration safety window
  }

  await pipeline.exec();
}

async function pollWarehouseAPI() {
  try {
    const response = await axios.get('WAREHOUSE_API_KEY', {
      headers: { 'Authorization': `Bearer ${process.env.WAREHOUSE_API_KEY}` },
      timeout: 10000 // 10s timeout
    });

    const inventory = response.data.items; // Array of { sku, quantity, location }
    await updateStockCache(inventory);
    console.log(`[${new Date().toISOString()}] Successfully synced ${inventory.length} items.`);
  } catch (error) {
    console.error(`[${new Date().toISOString()}] Polling failed:`, error.message);
    // Optional: Alert on persistent failures via Slack/PagerDuty
  }
}

// Run immediately on startup, then every 5 minutes
pollWarehouseAPI();
cron.schedule('*/5 * * * *', () => {
  pollWarehouseAPI();
});

app.get('/api/stock/:sku', async (req, res) => {
  const { sku } = req.params;
  const data = await redis.get(`stock:${sku}`);

  if (!data) {
    return res.status(404).json({ error: 'SKU not found or cache stale' });
  }

  return res.json(JSON.parse(data));
});

app.listen(3000, () => console.log('Query API running on port 3000'));