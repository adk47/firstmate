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

// --- PromptGuard injection scanning ---
const PROMPTGUARD_URL = process.env.PROMPTGUARD_URL || "http://localhost:18793";
// Budget, not a guess: PromptGuard 2 22M on one thread measured median 55 ms / p95 150 ms / max 194 ms
// on node-8-class hardware (promptguard/server.py, 512 tokens). The old 50 ms cap failed open on
// roughly HALF of all calls, which would make any shadow measurement blind by construction. 300 ms
// covers p95 at 2x and still hard-bounds the latency this adds to the live intake path.
const PROMPTGUARD_TIMEOUT_MS = 300; // hard cap: fail-open if slow
// SHADOW BY DEFAULT (caroline-promptguard-canary-p1, Fable safety lead §5). Bringing the sidecar up
// must not silently change what this lane DOES: before the sidecar existed every scan returned
// score 0, so nothing was ever blocked, and flipping the whole lane to "enforce" in the same change
// would make a classifier rollout into an intake-behavior change nobody measured. "shadow" records
// the verdict (log + #cs_chats badge) and posts normally; "enforce" restores the blocking behaviour
// written below. Flip with PROMPTGUARD_MODE=enforce in the unit's environment after the shadow
// window shows a zero false-positive rate.
const { resolvePromptguardMode } = require("./intercom-webhook-promptguard-mode.js");
const PROMPTGUARD = resolvePromptguardMode(process.env.PROMPTGUARD_MODE);
if (PROMPTGUARD.warning) {
  console.error(`[intercom-webhook] CRITICAL: ${PROMPTGUARD.warning}`);
}
const PROMPTGUARD_MODE = PROMPTGUARD.mode;
const PROMPTGUARD_ENFORCING = PROMPTGUARD.enforcing;
const BLOCK_THRESHOLD = parseFloat(process.env.PROMPTGUARD_BLOCK_THRESHOLD || "0.85");
const FLAG_THRESHOLD = parseFloat(process.env.PROMPTGUARD_FLAG_THRESHOLD || "0.3");
const OUTPUT_BLOCK_THRESHOLD = parseFloat(process.env.PROMPTGUARD_OUTPUT_BLOCK_THRESHOLD || "0.7");
if (isNaN(BLOCK_THRESHOLD) || isNaN(FLAG_THRESHOLD) || isNaN(OUTPUT_BLOCK_THRESHOLD)) {
  console.error("[intercom-webhook] FATAL: invalid PromptGuard threshold — must be numeric");
  process.exit(1);
}

// --- Quarantine ---
const QUARANTINE_PATH = process.env.QUARANTINE_PATH || "/app/sentinel/quarantine.json";
const fs = require("fs");

// --- Slack #cs_chats feed ---
const SLACK_CS_CHATS_WEBHOOK = process.env.SLACK_CS_CHATS_WEBHOOK || "";

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

// --- PromptGuard scan helper ---
async function scanWithPromptGuard(text) {
  try {
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), PROMPTGUARD_TIMEOUT_MS);
    const res = await fetch(`${PROMPTGUARD_URL}/v1/classify`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ text }),
      signal: controller.signal,
    });
    clearTimeout(timeout);
    if (!res.ok) {
      console.error(`[intercom-webhook] PromptGuard returned HTTP ${res.status}`);
      return { score: 0, label: "error", latency_ms: 0 };
    }
    return await res.json();
  } catch (err) {
    const isTimeout = err.name === "AbortError";
    console.error(`[intercom-webhook] PromptGuard ${isTimeout ? "timeout" : "error"}: ${err.message || err}`);
    return { score: 0, label: isTimeout ? "timeout" : "error", latency_ms: 0 }; // fail-open
  }
}

// --- Quarantine check helper ---
function getQuarantineMode() {
  try {
    const data = JSON.parse(fs.readFileSync(QUARANTINE_PATH, "utf8"));
    const VALID_MODES = new Set(["soft", "hard", "critical"]);
    const mode = data.support?.mode || null;
    if (mode && !VALID_MODES.has(mode)) {
      console.error(`[intercom-webhook] INVALID quarantine mode "${mode}" — treating as hard`);
      return "hard";
    }
    return mode;
  } catch (err) {
    if (err.code === "ENOENT") return null; // file not created yet
    console.error(`[intercom-webhook] QUARANTINE FILE UNREADABLE: ${err.message} — defaulting to hard quarantine`);
    return "hard"; // fail-closed: can't verify quarantine state, assume the worst
  }
}

// --- Slack #cs_chats feed ---
function stripHtml(str) {
  return (str || "").replace(/<[^>]*>/g, "").trim();
}

function truncate(str, len = 200) {
  const clean = stripHtml(str);
  return clean.length > len ? clean.substring(0, len) + "..." : clean;
}

async function postToCsChats(blocks) {
  if (!SLACK_CS_CHATS_WEBHOOK) return;
  try {
    const res = await fetch(SLACK_CS_CHATS_WEBHOOK, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ blocks }),
    });
    if (!res.ok) {
      const errBody = await res.text().catch(() => "");
      console.error(`[intercom-webhook] slack cs_chats post failed: HTTP ${res.status} ${errBody}`);
    }
  } catch (err) {
    console.warn(`[intercom-webhook] slack cs_chats post failed: ${err.message || err}`);
  }
}

function buildInboundBlocks({ convId, customerName, message, isNew, badges }) {
  const badgeStr = badges.length > 0 ? "  " + badges.join(" ") : "";
  const intercomUrl = `https://app.intercom.com/a/inbox/${WORKSPACE_ID}/inbox/conversation/${convId}`;
  const header = isNew ? ":speech_balloon: New conversation" : ":left_speech_bubble: Customer replied";
  const lines = [
    `*${header}*${badgeStr}`,
    `*From:* ${customerName || "Unknown"}`,
    `*Message:* ${truncate(message)}`,
    `<${intercomUrl}|View in Intercom>`,
  ];
  return [{ type: "section", text: { type: "mrkdwn", text: lines.join("\n") } }];
}

function buildOutcomeBlocks({ convId, outcome, detail }) {
  const intercomUrl = `https://app.intercom.com/a/inbox/${WORKSPACE_ID}/inbox/conversation/${convId}`;
  return [{ type: "context", elements: [{ type: "mrkdwn", text: `${outcome}${detail ? " — " + detail : ""}  |  <${intercomUrl}|conv>` }] }];
}

function extractCustomerInfo(payload) {
  const contact = payload.data?.item?.source?.author || payload.data?.item?.contacts?.contacts?.[0] || {};
  const name = contact.name || [contact.first_name, contact.last_name].filter(Boolean).join(" ") || null;
  const email = contact.email || null;
  return { name, email };
}

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
  if (!signature || !signature.startsWith("sha1=")) return false;
  const expected = "sha1=" + crypto.createHmac("sha1", WEBHOOK_SECRET).update(body).digest("hex");
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
        model: "openclaw:support",
        user: `intercom:${convId}`,
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

      // Extract customer info for Slack feed
      const { name: customerName } = extractCustomerInfo(payload);
      const isNewConv = topic === "conversation.user.created";

      // Escalation check
      const escalation = checkEscalation(customerBody);
      if (escalation) {
        session.handoffMode = "human_takeover";
        console.log(`[intercom-webhook] ESCALATED conv=${convId} category=${escalation.category} pattern=${escalation.pattern}`);
        await replyToIntercom(convId, "I'm connecting you with our support team for this. Someone will be with you shortly.");
        // Post to #cs_chats — escalation
        postToCsChats([
          ...buildInboundBlocks({ convId, customerName, message: customerBody, isNew: isNewConv, badges: [`:rotating_light: *ESCALATED (${escalation.category})*`] }),
          ...buildOutcomeBlocks({ convId, outcome: ":person_with_pouting_face: Handed to human rep", detail: `escalation: ${escalation.category}` }),
        ]);
        return;
      }

      // PromptGuard injection scan (input)
      const pgResult = await scanWithPromptGuard(customerBody);
      // Shadow mode records what ENFORCE would have refused and dispatches anyway. Computed once so
      // the badge below and the branch here can never disagree about what "would have blocked" means.
      const pgWouldBlock = pgResult.score > BLOCK_THRESHOLD;
      if (pgWouldBlock && !PROMPTGUARD_ENFORCING) {
        console.warn(
          `[intercom-webhook] SHADOW-WOULD-BLOCK conv=${convId} promptguard=${pgResult.score} label=${pgResult.label} threshold=${BLOCK_THRESHOLD} (dispatched unchanged)`,
        );
      } else if (pgWouldBlock) {
        console.warn(`[intercom-webhook] BLOCKED conv=${convId} promptguard=${pgResult.score} label=${pgResult.label}`);
        await replyToIntercom(convId, "I'd be happy to help! Could you rephrase your question about Muso.AI?");
        // Post to #cs_chats — blocked
        postToCsChats([
          ...buildInboundBlocks({ convId, customerName, message: customerBody, isNew: isNewConv, badges: [`:shield: *BLOCKED (pg=${pgResult.score.toFixed(2)})*`] }),
          ...buildOutcomeBlocks({ convId, outcome: ":no_entry: PromptGuard blocked — canned response sent" }),
        ]);
        return;
      }
      const pgFlagged = pgResult.score > FLAG_THRESHOLD;
      if (pgFlagged) {
        console.warn(`[intercom-webhook] FLAGGED conv=${convId} promptguard=${pgResult.score} label=${pgResult.label}`);
      }

      // Quarantine check — reads sentinel's quarantine state
      const quarantineMode = getQuarantineMode();
      if (quarantineMode === "hard" || quarantineMode === "critical") {
        session.handoffMode = "human_takeover";
        console.warn(`[intercom-webhook] QUARANTINED (${quarantineMode}) conv=${convId} — handing to human`);
        await replyToIntercom(convId, "I'm connecting you with a member of our support team. They'll be right with you.");
        // Post to #cs_chats — quarantine handoff
        postToCsChats([
          ...buildInboundBlocks({ convId, customerName, message: customerBody, isNew: isNewConv, badges: [`:lock: *QUARANTINE (${quarantineMode})*`] }),
          ...buildOutcomeBlocks({ convId, outcome: ":person_with_pouting_face: Handed to human rep", detail: `quarantine: ${quarantineMode}` }),
        ]);
        return;
      }

      // Suppress if not agent_active
      if (session.handoffMode !== "agent_active" || session.lifecycleState !== "open") {
        console.log(`[intercom-webhook] suppressed conv=${convId} mode=${session.handoffMode} lifecycle=${session.lifecycleState}`);
        return;
      }

      // Build badges for Slack notification
      const inboundBadges = [];
      if (pgWouldBlock && !PROMPTGUARD_ENFORCING) {
        // Visible in #cs_chats during the shadow window: a would-block that never reached a human
        // would leave the measurement invisible until the daily digest.
        inboundBadges.push(`:shield: shadow would-block pg=${pgResult.score.toFixed(2)}`);
      } else if (pgFlagged) inboundBadges.push(`:warning: pg=${pgResult.score.toFixed(2)}`);
      if (quarantineMode === "soft") inboundBadges.push(`:large_yellow_circle: FAQ-only`);

      // Post inbound to #cs_chats (async — don't block dispatch)
      const slackInboundBlocks = buildInboundBlocks({ convId, customerName, message: customerBody, isNew: isNewConv, badges: inboundBadges });

      // Dispatch to CS agent
      console.log(`[intercom-webhook] dispatching conv=${convId} body=${customerBody.substring(0, 100)}${pgFlagged ? ` [FLAGGED pg=${pgResult.score}]` : ""}`);
      const agentReply = await dispatchToAgent(convId, customerBody);

      if (agentReply) {
        session.consecutiveFailures = 0;

        // PromptGuard output scan — catch agent misbehavior before customer sees it
        const outputScan = await scanWithPromptGuard(agentReply);
        let finalReply = agentReply;
        let outputBlocked = false;
        if (outputScan.score > OUTPUT_BLOCK_THRESHOLD && !PROMPTGUARD_ENFORCING) {
          // SHADOW: the openclaw plugin's own output guard is the enforced gate on this lane; this
          // scan only records what the classifier would have added on top of it.
          console.warn(
            `[intercom-webhook] SHADOW-WOULD-BLOCK-OUTPUT conv=${convId} promptguard=${outputScan.score} label=${outputScan.label} threshold=${OUTPUT_BLOCK_THRESHOLD} (posted unchanged)`,
          );
        } else if (outputScan.score > OUTPUT_BLOCK_THRESHOLD) {
          console.error(`[intercom-webhook] OUTPUT BLOCKED conv=${convId} promptguard=${outputScan.score} label=${outputScan.label}`);
          finalReply = "I apologize, I'm having trouble with that question. Let me create a support ticket so our team can help you directly.";
          outputBlocked = true;
        } else if (outputScan.score > FLAG_THRESHOLD) {
          console.warn(`[intercom-webhook] OUTPUT FLAGGED conv=${convId} promptguard=${outputScan.score} label=${outputScan.label}`);
        }

        // Pre-send validation — recheck state after agent processing
        if (session.handoffMode !== "agent_active" || session.lifecycleState !== "open") {
          console.log(`[intercom-webhook] pre-send abort conv=${convId} — state changed during generation`);
          return;
        }

        const msgId = await replyToIntercom(convId, finalReply);
        if (msgId) {
          session.outboundMessageIds.add(msgId);
          if (session.outboundMessageIds.size > 500) {
            const oldest = session.outboundMessageIds.values().next().value;
            session.outboundMessageIds.delete(oldest);
          }
          console.log(`[intercom-webhook] replied conv=${convId} msgId=${msgId}`);
        }

        // Post to #cs_chats — AI handled
        const outcomeEmoji = outputBlocked ? ":warning: Output blocked — fallback sent" : ":robot_face: AI replied";
        const replyPreview = truncate(finalReply, 150);
        postToCsChats([
          ...slackInboundBlocks,
          ...buildOutcomeBlocks({ convId, outcome: outcomeEmoji, detail: replyPreview }),
        ]);
      } else {
        // LLM failure — track consecutive failures
        session.consecutiveFailures++;
        console.warn(`[intercom-webhook] agent failed conv=${convId} (${session.consecutiveFailures} consecutive)`);

        if (session.consecutiveFailures >= 3) {
          session.handoffMode = "human_takeover";
          console.warn(`[intercom-webhook] auto-escalated conv=${convId} — 3+ consecutive failures`);
          await replyToIntercom(convId, "I'm connecting you with our support team. Someone will be with you shortly.");
          // Post to #cs_chats — auto-escalated
          postToCsChats([
            ...slackInboundBlocks,
            ...buildOutcomeBlocks({ convId, outcome: ":person_with_pouting_face: Auto-escalated to human", detail: "3+ consecutive AI failures" }),
          ]);
        } else {
          await replyToIntercom(convId, "We're looking into this and will get back to you shortly.");
          // Post to #cs_chats — AI failed but retrying
          postToCsChats([
            ...slackInboundBlocks,
            ...buildOutcomeBlocks({ convId, outcome: ":hourglass: AI failed — retry pending", detail: `failure ${session.consecutiveFailures}/3` }),
          ]);
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
        const wasAgentActive = session.handoffMode === "agent_active";
        session.handoffMode = "human_takeover";
        console.log(`[intercom-webhook] human_takeover conv=${convId} admin=${adminId}`);

        // Post to #cs_chats — human took over
        if (wasAgentActive) {
          const intercomUrl = `https://app.intercom.com/a/inbox/${WORKSPACE_ID}/inbox/conversation/${convId}`;
          postToCsChats([{ type: "section", text: { type: "mrkdwn", text: `:person_with_pouting_face: *Human rep took over* conv \`${convId}\`\nAdmin ID: ${adminId}  |  <${intercomUrl}|View in Intercom>` } }]);
        }
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
