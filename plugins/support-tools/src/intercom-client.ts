import type { HttpClient } from "./http.js";

// Read-only Intercom reader used by dedupe_check to anchor ownership to the
// conversation's REAL author email (Intercom contact record), never to the
// customer-typed email in message text. Mirrors the proven support-side call
// in workspaces/support/skills/customer-credit-removal/scripts/remove-credits.sh
// (Intercom-Version 2.10, ?display_as=plaintext, .source.author.email).
const INTERCOM_API_BASE = process.env.MUSOAI_INTERCOM_API_BASE ?? "https://api.intercom.io";

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
  getLatestCustomerPart(conversationId: string, token: string): Promise<{ id: string; snippet: string } | null>;
}

// intercomAuthor is the structured author on a conversation source/part.
interface intercomAuthor {
  type?: string;
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
  conversation_parts?: { conversation_parts?: intercomPart[] };
}

// snippetOf reduces a message body (plaintext via display_as=plaintext, but
// defensively tag-stripped) to a short, injection-marker-free echo string.
const SNIPPET_MAX = 200;
function snippetOf(body: string | undefined): string {
  const text = (body ?? "").replace(/<[^>]*>/g, " ").replace(/\s+/g, " ").trim();
  return text.length > SNIPPET_MAX ? `${text.slice(0, SNIPPET_MAX)}…` : text;
}

// isContactAuthor reports whether an author is the customer (a contact), not a
// teammate or bot — the only author whose message can attest for the customer.
function isContactAuthor(a: intercomAuthor | undefined): boolean {
  return a?.type === "user" || a?.type === "lead";
}

export function createIntercomReader(http: HttpClient): IntercomReader {
  async function getConversation(conversationId: string, token: string): Promise<intercomConversation | null> {
    if (!conversationId || !token) return null;
    const url = `${INTERCOM_API_BASE}/conversations/${encodeURIComponent(conversationId)}?display_as=plaintext`;
    const resp = await http.get<intercomConversation>(url, {
      headers: {
        Authorization: `Bearer ${token}`,
        Accept: "application/json",
        "Intercom-Version": "2.10",
      },
    });
    return resp.ok ? resp.data : null;
  }

  return {
    async getAuthorEmail(conversationId, token) {
      const conv = await getConversation(conversationId, token);
      const email = conv?.source?.author?.email;
      return email ? email.toLowerCase() : null;
    },

    async getLatestCustomerPart(conversationId, token) {
      const conv = await getConversation(conversationId, token);
      if (!conv) return null;
      // Candidates: the initial source message, plus every conversation part.
      // Keep only contact-authored (user/lead) comments with an id + timestamp,
      // and pick the most recent — that is the customer's latest utterance,
      // which per the ask-then-confirm flow SHOULD be their same-artist
      // confirmation; the returned snippet lets the caller verify it is.
      let best: { id: string; snippet: string } | null = null;
      let bestAt = -1;
      const consider = (id: string | undefined, at: number | undefined, author: intercomAuthor | undefined, body: string | undefined, partType?: string) => {
        if (!id || typeof at !== "number") return;
        if (!isContactAuthor(author)) return;
        // A part_type may be a note/assignment/rating; only a "comment" is a
        // customer message. The source has no part_type (always a comment).
        if (partType && partType !== "comment") return;
        if (at > bestAt) {
          bestAt = at;
          best = { id, snippet: snippetOf(body) };
        }
      };
      consider(conv.source?.id, conv.source?.created_at ?? conv.created_at, conv.source?.author, conv.source?.body);
      for (const p of conv.conversation_parts?.conversation_parts ?? []) {
        consider(p.id, p.created_at, p.author, p.body, p.part_type);
      }
      return best;
    },
  };
}
