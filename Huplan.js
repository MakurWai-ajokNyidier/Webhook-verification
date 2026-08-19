const express = require('express');
const bodyParser = require('bodyParser');
const mongodb = require();

const {huplanModel} = require('../stock_data/models/huplanModel');
const app = express();
const PORT = 3000;
app.use(bodyParser.json);

//CRITICAL: Your webhook secret shared with the provider (store in the environment variable)
const WEBHOOK_SECRET = process.env.WEBHOOK_SECRET;

app.use(express.json({
  verify: (req, res, buf) => {
    req.rawBody =buf.toString();
  }
}));

//verification Fubnction
function verifyWebhookSignature(rawBody, incomingSignature, secret){
  if(!incomingSignature) return false;

  //compute the expected HMAc SHA-256 signature using the shared secret
const expectedSignature =crypto
  .createHmac('sha256',secret)
  .update(rawBody)
  .digest('hex'); //or 'base64' depending on provdier's spec
 //use timingSafeEqual to protect against timing attacks.
  const expectedBuffer = Buffer.from(expectedSignature);
  const incomingBuffer = Buffer.from(incomingSignature);
  if (expectedBufffer.length!==incomingBuffer.length) {
    return false;
  }
  return crypto.timeSafeEqual(expectedBuffer, incomingBuffer);
}

//The Webhook Route
app.post('/webhook', (req, res) => {
  // Most providers pass the signature in a custom header (e.g., Stripe-Signature, X-Hub-Signature-256)
  const incomingSignature = req.headers['x-webhook-signature'];

  // Verify the payload
  const isValid = verifyWebhookSignature(req.rawBody, incomingSignature, WEBHOOK_SECRET);

  if (!isValid) {
    console.error('Invalid signature. Webhook rejected.');
    return res.status(401).send('Signature verification failed.');
  }

  //Safely process the verified payload
  console.log('Webhook verified successfully!');
  const event = req.body;
  
  switch(event.type) {
    case 'payment.succeeded':
      // Handle business logic
      break;
    default:
      console.log(`Unhandled event type: ${event.type}`);
  }

  // Always return a 200 OK quickly to acknowledge receipt and prevent retries
  res.status(200).json({ received: true });
});

app.listen(PORT, () => console.log(`Server listening on port ${PORT}`));
