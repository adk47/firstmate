const http = require("http");
const crypto = require("crypto");

// --- Config from environment (never hardcode secrets) ---
const PORT = parseInt(process.env.INTERCOM_WEBHOOK_PORT || "18792", 10);
const WEBHOOK_SECRET = process.env.INTERCOM_WEBHOOK_SECRET || "";
const OPENCLAW_URL = process.env.OPENCLAW_URL || "http://localhost:18789";
const OPENCLAW_TOKEN = process.env.OPENCLAW_TOKEN || "";
const BOT_ADMIN_ID = process.env.INTERCOM_BOT_ADMIN_ID || "";
const INTERCOM_TOKEN = process.env.INTERCOM_TOKEN || "";
const WORKSPACE_ID = process.env.INTERCOM_WORKSPACE_ID || "";
const DISPATCH_TIMEOUT_MS = parseInt(process.env.DISPATCH_TIMEOUT_MS || "15000", 10);
const MAX_RETRIES = 3;

// --- Required env vars — refuse to start without them ---
const REQUIRED_VARS = { INTERCOM_WEBHOOK_SECRET: WEBHOOK_SECRET, INTERCOM_TOKEN, INTERCOM_BOT_ADMIN_ID: BOT_ADMIN_ID, OPENCLAW_TOKEN };
const missing = Object.entries(REQUIRED_VARS).filter(([, v]) => !v).map(([k]) => k);
if (missing.length > 0) {
  console.error(`[intercom-webhook] FATAL: missing required env vars: ${missing.join(", ")}`);
  process.exit(1);
}

// --- State ---
const sessions = new Map();
const processedEvents = new Set();
const MAX_PROCESSED_EVENTS = 5000;

// --- Escalation patterns (word-boundary, case-insensitive) ---
const ESCALATION_RULES = [
  { category: "billing", patterns: [/\brefund\b/i, /\bchargeback\b/i, /\bbilling dispute\b/i, /\binvoice dispute\b/i, /\bpayment failed\b/i, /\bunauthorized charge\b/i] },
  { category: "legal", patterns: [/\blawyer\b/i, /\battorney\b/i, /\blawsuit\b/i, /\bsue\b/i, /\bcourt\b/i, /\bsubpoena\b/i, /\blegal action\b/i, /\blegal threat\b/i] },
  { category: "security", patterns: [/\bhacked\b/i, /\bcompromised\b/i, /\bunauthorized access\b/i, /\bstolen account\b/i, /\bpassword breach\b/i] },
  { category: "abuse", patterns: [/\bharassment\b/i, /\babuse report\b/i, /\bthreatening\b/i, /\bphishing\b/i] },
];

function checkEscalation(message) {
  if (!message) return null;
  const stripped = message.replace(/<[^>]*>/g, ""); // strip HTML tags
  for (const rule of ESCALATION_RULES) {
    for (const pattern of rule.patterns) {
      if (pattern.test(stripped)) return { category: rule.category, pattern: pattern.source };
    }
  }
  return null;
}

// --- HMAC validation ---
function validateHmac(body, signature) {
  if (!signature || !signature.startsWith("sha256=")) return false;
  const expected = "sha256=" + crypto.createHmac("sha256", WEBHOOK_SECRET).update(body).digest("hex");
  if (expected.length !== signature.length) return false;
  return crypto.timingSafeEqual(Buffer.from(expected), Buffer.from(signature));
}

// --- Session management ---
function getSession(convId) {
  if (!sessions.has(convId)) {
    sessions.set(convId, {
      conversationId: convId,
      handoffMode: "agent_active",
      lifecycleState: "open",
      currentAssigneeId: null,
      outboundMessageIds: new Set(),
      consecutiveFailures: 0,
    });
  }
  return sessions.get(convId);
}

// --- Intercom API with retry ---
async function replyToIntercom(convId, body, retries = MAX_RETRIES) {
  for (let attempt = 1; attempt <= retries; attempt++) {
    const res = await fetch(`https://api.intercom.io/conversations/${convId}/reply`, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${INTERCOM_TOKEN}`,
        "Content-Type": "application/json",
        Accept: "application/json",
        "Intercom-Version": "2.11",
      },
      body: JSON.stringify({
        message_type: "comment",
        type: "admin",
        admin_id: BOT_ADMIN_ID,
        body,
      }),
    });

    if (res.status === 429) {
      const retryAfter = parseInt(res.headers.get("Retry-After") || "5", 10);
      const delay = Math.min((Number.isFinite(retryAfter) && retryAfter > 0 ? retryAfter : 5) * 1000, 10000);
      const jitter = Math.random() * 1000;
      console.warn(`[intercom-webhook] rate limited (attempt ${attempt}/${retries}), waiting ${Math.round(delay + jitter)}ms`);
      if (attempt < retries) {
        await new Promise(r => setTimeout(r, delay + jitter));
        continue;
      }
      return null;
    }

    if (!res.ok) {
      const errBody = await res.text().catch(() => "");
      console.error(`[intercom-webhook] reply failed: ${res.status} ${errBody}`);
      return null;
    }

    const data = await res.json().catch(() => ({}));
    return data.id || null;
  }
  return null;
}

// --- OpenClaw dispatch with timeout ---
async function dispatchToAgent(convId, customerMessage) {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), DISPATCH_TIMEOUT_MS);

  try {
    const res = await fetch(`${OPENCLAW_URL}/v1/chat/completions`, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${OPENCLAW_TOKEN}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        model: "support",
        messages: [{ role: "user", content: customerMessage }],
        metadata: {
          channel: "intercom",
          conversationId: convId,
          workspaceId: WORKSPACE_ID,
        },
      }),
      signal: controller.signal,
    });

    if (!res.ok) {
      const errBody = await res.text().catch(() => "");
      console.error(`[intercom-webhook] agent dispatch failed: ${res.status} ${errBody}`);
      return null;
    }

    const data = await res.json().catch(() => ({}));
    return data.choices?.[0]?.message?.content || null;
  } catch (err) {
    if (err.name === "AbortError") {
      console.error(`[intercom-webhook] agent dispatch timed out after ${DISPATCH_TIMEOUT_MS}ms conv=${convId}`);
    } else {
      console.error(`[intercom-webhook] agent dispatch error: ${err.message || err}`);
    }
    return null;
  } finally {
    clearTimeout(timeout);
  }
}

// --- Webhook handler ---
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
  if (!validateHmac(body, sig)) {
    console.log("[intercom-webhook] invalid HMAC signature — rejected");
    res.writeHead(200);
    res.end(JSON.stringify({ ok: true }));
    return;
  }

  // Respond 200 immediately (Intercom expects fast response)
  res.writeHead(200, { "Content-Type": "application/json" });
  res.end(JSON.stringify({ ok: true }));

  // Process async
  try {
    const payload = JSON.parse(body);
    const topic = payload.topic || "";
    const eventId = payload.id;
    const convId = payload.data?.item?.id;

    if (!convId || !topic || !eventId) {
      console.log("[intercom-webhook] malformed payload — skipping");
      return;
    }

    // Idempotency — reject duplicate events
    if (processedEvents.has(eventId)) {
      console.log(`[intercom-webhook] duplicate event ${eventId} — skipping`);
      return;
    }
    processedEvents.add(eventId);
    if (processedEvents.size > MAX_PROCESSED_EVENTS) {
      const first = processedEvents.values().next().value;
      processedEvents.delete(first);
    }

    console.log(`[intercom-webhook] ${topic} conv=${convId} event=${eventId}`);

    const session = getSession(convId);

    // --- Event routing ---

    if (topic === "conversation.user.created" || topic === "conversation.user.replied") {
      // Handle implicit reopen — restore mode based on assignee
      if (session.lifecycleState === "closed") {
        session.lifecycleState = "open";
        if (session.currentAssigneeId && session.currentAssigneeId !== BOT_ADMIN_ID) {
          session.handoffMode = "human_takeover";
        } else {
          session.handoffMode = "agent_active";
        }
        console.log(`[intercom-webhook] implicit reopen conv=${convId} mode=${session.handoffMode}`);
      }

      const customerBody =
        payload.data?.item?.conversation_parts?.conversation_parts?.slice(-1)?.[0]?.body ||
        payload.data?.item?.conversation_message?.body ||
        payload.data?.item?.source?.body ||
        "";

      if (!customerBody) {
        console.log(`[intercom-webhook] empty message body conv=${convId} — skipping`);
        return;
      }

      // Escalation check
      const escalation = checkEscalation(customerBody);
      if (escalation) {
        session.handoffMode = "human_takeover";
        console.log(`[intercom-webhook] ESCALATED conv=${convId} category=${escalation.category} pattern=${escalation.pattern}`);
        // TODO: post escalation card to fallbackSlackSupervisionChannel
        await replyToIntercom(convId, "I'm connecting you with our support team for this. Someone will be with you shortly.");
        return;
      }

      // Suppress if not agent_active
      if (session.handoffMode !== "agent_active" || session.lifecycleState !== "open") {
        console.log(`[intercom-webhook] suppressed conv=${convId} mode=${session.handoffMode} lifecycle=${session.lifecycleState}`);
        return;
      }

      // Dispatch to CS agent
      console.log(`[intercom-webhook] dispatching conv=${convId} body=${customerBody.substring(0, 100)}`);
      const agentReply = await dispatchToAgent(convId, customerBody);

      if (agentReply) {
        session.consecutiveFailures = 0;

        // Pre-send validation — recheck state after agent processing
        if (session.handoffMode !== "agent_active" || session.lifecycleState !== "open") {
          console.log(`[intercom-webhook] pre-send abort conv=${convId} — state changed during generation`);
          return;
        }

        const msgId = await replyToIntercom(convId, agentReply);
        if (msgId) {
          session.outboundMessageIds.add(msgId);
          if (session.outboundMessageIds.size > 500) {
            const oldest = session.outboundMessageIds.values().next().value;
            session.outboundMessageIds.delete(oldest);
          }
          console.log(`[intercom-webhook] replied conv=${convId} msgId=${msgId}`);
        }
      } else {
        // LLM failure — track consecutive failures
        session.consecutiveFailures++;
        console.warn(`[intercom-webhook] agent failed conv=${convId} (${session.consecutiveFailures} consecutive)`);

        if (session.consecutiveFailures >= 3) {
          session.handoffMode = "human_takeover";
          console.warn(`[intercom-webhook] auto-escalated conv=${convId} — 3+ consecutive failures`);
          await replyToIntercom(convId, "I'm connecting you with our support team. Someone will be with you shortly.");
        } else {
          await replyToIntercom(convId, "We're looking into this and will get back to you shortly.");
        }
      }

    } else if (topic === "conversation.admin.replied") {
      const adminId = payload.data?.item?.conversation_parts?.conversation_parts?.slice(-1)?.[0]?.author?.id || "";
      const messageId = payload.data?.item?.conversation_parts?.conversation_parts?.slice(-1)?.[0]?.id || "";

      // Self-reply filter (Set-based O(1) lookup)
      if (session.outboundMessageIds.has(messageId)) {
        console.log(`[intercom-webhook] self-reply filtered conv=${convId} msgId=${messageId}`);
        return;
      }

      // Non-bot admin reply → implicit takeover
      if (adminId && adminId !== BOT_ADMIN_ID) {
        session.handoffMode = "human_takeover";
        console.log(`[intercom-webhook] human_takeover conv=${convId} admin=${adminId}`);
      }

    } else if (topic === "conversation.admin.assigned") {
      const assigneeId = payload.data?.item?.assignee?.id || "";
      session.currentAssigneeId = assigneeId;
      if (assigneeId === BOT_ADMIN_ID) {
        session.handoffMode = "agent_active";
      } else if (assigneeId) {
        session.handoffMode = "human_takeover";
      }
      console.log(`[intercom-webhook] assigned conv=${convId} to=${assigneeId} mode=${session.handoffMode}`);

    } else if (topic === "conversation.admin.closed") {
      session.lifecycleState = "closed";
      console.log(`[intercom-webhook] closed conv=${convId}`);

    } else if (topic === "conversation.admin.snoozed") {
      session.lifecycleState = "snoozed";
      console.log(`[intercom-webhook] snoozed conv=${convId}`);

    } else if (topic === "conversation.admin.opened") {
      session.lifecycleState = "open";
      console.log(`[intercom-webhook] opened conv=${convId}`);

    } else if (topic === "conversation.admin.noted") {
      // Internal notes — ignore
    } else {
      console.log(`[intercom-webhook] unknown topic: ${topic}`);
    }

  } catch (err) {
    console.error(`[intercom-webhook] error: ${err.message || err}`);
  }
});

// --- Graceful shutdown ---
function shutdown(signal) {
  console.log(`[intercom-webhook] ${signal} received, shutting down`);
  server.close(() => process.exit(0));
  setTimeout(() => process.exit(1), 5000);
}
process.on("SIGTERM", () => shutdown("SIGTERM"));
process.on("SIGINT", () => shutdown("SIGINT"));

server.listen(PORT, "127.0.0.1", () => {
  console.log(`[intercom-webhook] listening on 127.0.0.1:${PORT}`);
  console.log(`[intercom-webhook] OpenClaw: ${OPENCLAW_URL} | bot: ${BOT_ADMIN_ID ? "configured" : "MISSING"} | workspace: ${WORKSPACE_ID ? "configured" : "MISSING"}`);
});
