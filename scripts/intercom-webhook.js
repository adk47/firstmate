const http = require("http");
const crypto = require("crypto");

const PORT = 18792;
const WEBHOOK_SECRET = "713f9dde-a9d6-4206-9569-3176de225505";
const OPENCLAW_URL = "http://localhost:18789";
const BOT_ADMIN_ID = "10206197";
const INTERCOM_TOKEN = "dG9rOmM1NThhZWVhXzI5ZTRfNGQ2MF9iM2ZiX2M0MWQ5ZDZjYzI3ODoxOjA=";

function validateHmac(body, signature) {
  if (!signature || !signature.startsWith("sha256=")) return false;
  const expected = "sha256=" + crypto.createHmac("sha256", WEBHOOK_SECRET).update(body).digest("hex");
  return crypto.timingSafeEqual(Buffer.from(expected), Buffer.from(signature));
}

const server = http.createServer(async (req, res) => {
  if (req.method !== "POST" || req.url !== "/intercom/webhook") {
    res.writeHead(200, { "Content-Type": "application/json" });
    res.end(JSON.stringify({ ok: true, status: "ready" }));
    return;
  }

  let body = "";
  for await (const chunk of req) body += chunk;

  // HMAC validation
  const sig = req.headers["x-hub-signature"] || "";
  if (WEBHOOK_SECRET && !validateHmac(body, sig)) {
    console.log("[intercom-webhook] Invalid HMAC signature");
    res.writeHead(200);
    res.end(JSON.stringify({ ok: true }));
    return;
  }

  // Always respond 200 to Intercom immediately
  res.writeHead(200, { "Content-Type": "application/json" });
  res.end(JSON.stringify({ ok: true }));

  // Process async
  try {
    const payload = JSON.parse(body);
    const topic = payload.topic || "";
    const convId = payload.data?.item?.id;
    console.log(`[intercom-webhook] ${topic} conv=${convId}`);

    // Only dispatch customer messages to the CS agent
    if (topic === "conversation.user.created" || topic === "conversation.user.replied") {
      const customerBody = payload.data?.item?.conversation_parts?.conversation_parts?.[0]?.body
        || payload.data?.item?.conversation_message?.body
        || "[new conversation]";

      // TODO: dispatch to OpenClaw CS agent session via internal API
      console.log(`[intercom-webhook] dispatch: conv=${convId} body=${customerBody.substring(0, 100)}`);
    }
  } catch (err) {
    console.error(`[intercom-webhook] error: ${err}`);
  }
});

server.listen(PORT, "127.0.0.1", () => {
  console.log(`[intercom-webhook] listening on 127.0.0.1:${PORT}`);
});
