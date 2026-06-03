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
}

export function createIntercomReader(http: HttpClient): IntercomReader {
  return {
    async getAuthorEmail(conversationId, token) {
      if (!conversationId || !token) return null;
      const url = `${INTERCOM_API_BASE}/conversations/${encodeURIComponent(conversationId)}?display_as=plaintext`;
      const resp = await http.get<{ source?: { author?: { email?: string } } }>(url, {
        headers: {
          Authorization: `Bearer ${token}`,
          Accept: "application/json",
          "Intercom-Version": "2.10",
        },
      });
      if (!resp.ok) return null;
      const email = resp.data?.source?.author?.email;
      return email ? email.toLowerCase() : null;
    },
  };
}
