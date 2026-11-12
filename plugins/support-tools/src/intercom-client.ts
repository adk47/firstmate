import type { HttpClient } from "./http.js";

// Read-only Intercom reader used by dedupe_check to anchor ownership to the
// conversation's REAL author email (Intercom contact record), never to the
// customer-typed email in message text. Mirrors the proven support-side call
// in workspaces/support/skills/customer-credit-removal/scripts/remove-credits.sh
// (Intercom-Version 2.10, ?display_as=plaintext, .source.author.email).
const INTERCOM_API_BASE = process.env.MUSOAI_INTERCOM_API_BASE ?? "https://api.intercom.io";
// Retrieve-conversation returns at most the 500 most recent parts, and its total_count
// counts the returned parts, so a full page cannot prove the history is complete.
const INTERCOM_MAX_PARTS = 500;

export interface IntercomReader {
  // Returns the author email lowercased, or null on ANY unverifiable path
  // (missing convId/token, API error, or no email on the contact). The caller
  // MUST treat null as fail-closed (owner_undetermined) — never as verified.
  getAuthorEmail(conversationId: string, token: string): Promise<string | null>;

  // Returns the CUSTOMER's most recent message in the conversation (the
  // initial source or any comment part authored by the contact — author.type
  // user/lead, never admin/bot) as {id, snippet}, or null on any unverifiable
  // path. This is the attestation reference the consolidate tool passes to
  // muso: the part id is resolved deterministically HERE, never chosen freely
  // by the model, so a prompt injection cannot point the attestation at an
  // arbitrary message. The snippet is echoed back to the agent so it can
  // verify the resolved message IS the customer's confirmation before
  // applying (and pin that exact id across preview→apply). muso re-verifies
  // the part's provenance (author == the actor's contact, recent)
  // server-side regardless.
  // `text` is the COMPLETE plaintext of that part; `snippet` is its first 200 characters
  // (a "…" marks truncation). A decision that reads the customer's words must read `text`
  // and fail closed when it is absent (QA #1873 r9).
  getLatestCustomerPart(conversationId: string, token: string): Promise<{ id: string; snippet: string; text?: string } | null>;

  // Did the bot admin post a comment containing any of `markers` (case-insensitive,
  // whitespace-normalized) in one of this conversation's contact's OTHER conversations
  // updated after `sinceUnix`? "unknown" on ANY unverifiable
  // path (lookup failure, no single contact, more than `limit` conversations, a truncated
  // or 500-part-capped part list); the caller MUST NOT read "unknown" as "not_found".
  // The conversation's ONE contact (Intercom contact record, never message text), with the facts the
  // owner anchor's spoof screen needs. null on ANY unverifiable path: no single contact, API error, no
  // email, or a contact-authored source whose email differs. Optional so older test stubs still compile;
  // a reader without it anchors nothing (fail closed).
  getContactIdentity?(conversationId: string, token: string): Promise<ContactIdentity | null>;

  findBotMarkerInOtherConversations(params: {
    conversationId: string;
    token: string;
    botAdminId: string;
    markers: string[];
    sinceUnix: number;
    limit: number;
  }): Promise<"found" | "not_found" | "unknown">;
}

export interface ContactIdentity {
  email: string;
  role: string; // "user" | "lead" (anything else is refused by the reader)
  externalId: string | null;
  contactCreatedAt: number | null; // unix seconds
  conversationCreatedAt: number | null;
}

// intercomAuthor is the structured author on a conversation source/part.
interface intercomAuthor {
  type?: string;
  id?: string | number;
  email?: string;
}
interface intercomPart {
  id?: string;
  part_type?: string;
  created_at?: number;
  body?: string;
  author?: intercomAuthor;
}
interface intercomConversation {
  source?: { id?: string; created_at?: number; body?: string; author?: intercomAuthor };
  created_at?: number;
  conversation_parts?: { conversation_parts?: intercomPart[]; total_count?: number };
  contacts?: { contacts?: Array<{ id?: string }> };
}
interface intercomSearchPage {
  conversations?: Array<{ id?: string | number }>;
  total_count?: number;
}

function normalizedText(body: string | undefined): string {
  return (body ?? "").replace(/<[^>]*>/g, " ").replace(/\s+/g, " ").trim().toLowerCase();
}

// snippetOf reduces a message body (plaintext via display_as=plaintext, but
// defensively tag-stripped) to a short, injection-marker-free echo string.
const SNIPPET_MAX = 200;
function plaintextOf(body: string | undefined): string {
  return (body ?? "").replace(/<[^>]*>/g, " ").replace(/\s+/g, " ").trim();
}
function snippetOf(body: string | undefined): string {
  const text = plaintextOf(body);
  return text.length > SNIPPET_MAX ? `${text.slice(0, SNIPPET_MAX)}…` : text;
}

// isContactAuthor reports whether an author is the customer (a contact), not a
// teammate or bot — the only author whose message can attest for the customer.
function isContactAuthor(a: intercomAuthor | undefined): boolean {
  return a?.type === "user" || a?.type === "lead";
}

export function createIntercomReader(http: HttpClient): IntercomReader {
  const headersFor = (token: string) => ({
    Authorization: `Bearer ${token}`,
    Accept: "application/json",
    "Intercom-Version": "2.10",
  });

  async function getConversation(conversationId: string, token: string): Promise<intercomConversation | null> {
    if (!conversationId || !token) return null;
    const url = `${INTERCOM_API_BASE}/conversations/${encodeURIComponent(conversationId)}?display_as=plaintext`;
    const resp = await http.get<intercomConversation>(url, { headers: headersFor(token) });
    return resp.ok ? resp.data : null;
  }

  return {
    async getAuthorEmail(conversationId, token) {
      const conv = await getConversation(conversationId, token);
      const email = conv?.source?.author?.email;
      return email ? email.toLowerCase() : null;
    },

    async getContactIdentity(conversationId, token) {
      const conv = await getConversation(conversationId, token);
      const contacts = conv?.contacts?.contacts ?? [];
      if (!conv || contacts.length !== 1 || !contacts[0].id) return null;
      const url = `${INTERCOM_API_BASE}/contacts/${encodeURIComponent(String(contacts[0].id))}`;
      const resp = await http.get<{ role?: string; email?: string; external_id?: string | null; created_at?: number }>(
        url, { headers: headersFor(token) });
      if (!resp.ok || !resp.data) return null;
      const role = resp.data.role ?? "";
      if (role !== "user" && role !== "lead") return null;
      const email = (resp.data.email ?? "").trim().toLowerCase();
      if (!email) return null;
      const author = conv.source?.author;
      if (isContactAuthor(author) && author?.email && author.email.toLowerCase() !== email) return null;
      const num = (v: unknown) => (typeof v === "number" && Number.isFinite(v) ? v : null);
      const ext = resp.data.external_id;
      return {
        email,
        role,
        externalId: ext !== null && ext !== undefined && String(ext).trim() ? String(ext).trim() : null,
        contactCreatedAt: num(resp.data.created_at),
        conversationCreatedAt: num(conv.created_at),
      };
    },

    async getLatestCustomerPart(conversationId, token) {
      const conv = await getConversation(conversationId, token);
      if (!conv) return null;
      // Candidates: the initial source message, plus every conversation part.
      // Keep only contact-authored (user/lead) comments with an id + timestamp,
      // and pick the most recent — that is the customer's latest utterance,
      // which per the ask-then-confirm flow SHOULD be their same-artist
      // confirmation; the returned snippet lets the caller verify it is.
      let best: { id: string; snippet: string; text: string } | null = null;
      let bestAt = -1;
      const consider = (id: string | undefined, at: number | undefined, author: intercomAuthor | undefined, body: string | undefined, partType?: string) => {
        if (!id || typeof at !== "number") return;
        if (!isContactAuthor(author)) return;
        // A part_type may be a note/assignment/rating; only a "comment" is a
        // customer message. The source has no part_type (always a comment).
        if (partType && partType !== "comment") return;
        if (at > bestAt) {
          bestAt = at;
          best = { id, snippet: snippetOf(body), text: plaintextOf(body) };
        }
      };
      consider(conv.source?.id, conv.source?.created_at ?? conv.created_at, conv.source?.author, conv.source?.body);
      for (const p of conv.conversation_parts?.conversation_parts ?? []) {
        consider(p.id, p.created_at, p.author, p.body, p.part_type);
      }
      return best;
    },

    async findBotMarkerInOtherConversations({ conversationId, token, botAdminId, markers, sinceUnix, limit }) {
      const needles = (Array.isArray(markers) ? markers : []).map(normalizedText).filter(Boolean);
      if (!conversationId || !token || !botAdminId || needles.length === 0 || limit < 1) return "unknown";
      const hasNeedle = (body: string | undefined) => {
        const text = normalizedText(body);
        return needles.some((n) => text.includes(n));
      };
      const current = await getConversation(conversationId, token);
      const contactIds = (current?.contacts?.contacts ?? []).map((c) => String(c?.id ?? "")).filter(Boolean);
      if (contactIds.length !== 1) return "unknown";
      const search = await http.post<intercomSearchPage>(`${INTERCOM_API_BASE}/conversations/search`, {
        headers: headersFor(token),
        body: {
          query: {
            operator: "AND",
            value: [
              { field: "contact_ids", operator: "=", value: contactIds[0] },
              { field: "id", operator: "!=", value: conversationId },
              { field: "updated_at", operator: ">", value: Math.floor(sinceUnix) },
            ],
          },
          pagination: { per_page: limit },
        },
      });
      if (!search.ok) return "unknown";
      const rows = search.data?.conversations;
      const total = search.data?.total_count;
      if (!Array.isArray(rows) || typeof total !== "number" || total > rows.length || rows.length > limit) return "unknown";
      let incomplete = false;
      for (const row of rows) {
        const id = String(row?.id ?? "");
        if (!id) return "unknown";
        if (id === conversationId) continue;
        const conv = await getConversation(id, token);
        const parts = conv?.conversation_parts?.conversation_parts;
        const partsTotal = conv?.conversation_parts?.total_count;
        if (!conv || !Array.isArray(parts) || parts.length >= INTERCOM_MAX_PARTS || (typeof partsTotal === "number" && partsTotal > parts.length)) {
          incomplete = true;
          continue;
        }
        const byBot = (a: intercomAuthor | undefined) => a?.type === "admin" && String(a.id ?? "") === botAdminId;
        if (byBot(conv.source?.author) && hasNeedle(conv.source?.body)) return "found";
        if (parts.some((p) => p.part_type === "comment" && byBot(p.author) && hasNeedle(p.body))) return "found";
      }
      return incomplete ? "unknown" : "not_found";
    },
  };
}
