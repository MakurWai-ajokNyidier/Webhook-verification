const express =require('express');
const crypto = require('crypto');
const mongoose =require('mongoose');
const item = require('./modelds/Item');

const itemSchema = new mongoose.Schema({
  sku: {type: String, required: true, unique: true},
  name: String,
  stockQuantity: {type; Number, required: true, default: 0}};
module.exports = mongoose.model('Item', itemSchema);

function verifySignature(req, res, next) {
  const secret = process.env.WEBHOOK_SECRET || 'your_shared_secret';
  const signature = req.headers['x-webhook-signature'];

  if(!signature) {
    return res.status(401).json({error: 'Missing sugnature header'});
  }

  //Expecting req.rawBody to be preserved for HMAC calculation
  const hmac = crypto.createHmac('sha256', secret);
  const digest = 'sha256' + hmac.update(req.rawBody).digest('hex');
  if (crypto.timeSafeEqual(Buffer.from(signature), Buffer.from(digest))){
    return next();
  }

  return res.status(403).json({error: 'Invalid signature'});
}

module.exports = verifySignature;

const verifySignature = require('./middleware/verifySignature');

const app = express();

//Parse JSON and preserve raw body for HMAC verification
app.use(express.json({
  verify:(req, res, buf) => {
    req.rawBody = buf;
  }
}));

//MongoDB connection
mongoose.connect('mongodb://127.0.0.1:27017/inventory_db')
.then(() => console.log('Connceted to MongoDB'))
.catch(err => console.errpr('MongoDB connect error:', err));

//webhook Route: verify signature and stock validity.
app.post('/webhook/check-stock', verifySignature, async (req, res) =>{
  try{
    const { sku, requestedQuantity} = req.body;

    if (!sku || !requestQuantity){
      return res.status(404).json({ status: 'not_found', valid: false, message: 'Item does not exist in the stock.'});
    }

    if (item.stockQunatity >= requestedQuantity){
      return res.status(200).json({
        status: 'success',
        valid: 'true',
        message: 'Item is valid in the stock',
        availableStock: item.stockQuantity
      });
    }

    return res.status(200).json({
      status: 'insufficient_stock',
      valid: false,
      message: 'Item exists but requested quantity exceeds stock.',
      availableStock: item.stockQuantity
    });
  } catch(error){
    return res.status(500).json({error: 'Internal server error', details: error.message});
  }
});
app.listen(3000, () => console.log('webhook server listening on port 3000'));

