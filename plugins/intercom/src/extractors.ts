import type { KnownFacts } from "./types.js";

// Reuse the same email pattern shape as sanitize-email.ts for consistency.
const EMAIL_PATTERN = /\b[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}\b/;

// Obfuscated-email fallback. Catches "name AT domain DOT tld" or "name (at) domain (dot) tld"
// — common when users want to evade scrapers but still tell support their address.
// Tried only after the strict pattern misses, so a normal email is never re-matched.
const OBFUSCATED_EMAIL_PATTERN =
  /\b([a-zA-Z0-9._%+-]+)\s*(?:\(?at\)?|\[at\])\s*([a-zA-Z0-9.-]+)\s*(?:\(?dot\)?|\[dot\])\s*([a-zA-Z]{2,})\b/i;

const PROFILE_URL_PATTERN = /(https?:\/\/muso\.ai\/profile\/([a-zA-Z0-9-]{8,}))/i;

const MAX_BODY_LENGTH = 16_000;

function extractEmail(input: string): string | null {
  const direct = input.match(EMAIL_PATTERN);
  if (direct) return direct[0].toLowerCase();
  const obfuscated = input.match(OBFUSCATED_EMAIL_PATTERN);
  if (obfuscated) {
    return `${obfuscated[1]}@${obfuscated[2]}.${obfuscated[3]}`.toLowerCase();
  }
  return null;
}

export function updateKnownFacts(message: string, current: KnownFacts): KnownFacts {
  if (!message) return current;
  const input = message.length > MAX_BODY_LENGTH ? message.slice(0, MAX_BODY_LENGTH) : message;

  const next: KnownFacts = { ...current };
  let changed = false;

  if (!next.accountEmail) {
    const email = extractEmail(input);
    if (email) {
      next.accountEmail = email;
      changed = true;
    }
  }

  if (!next.musoProfileUrl) {
    const m = input.match(PROFILE_URL_PATTERN);
    if (m) {
      next.musoProfileUrl = m[1];
      next.musoProfileId = m[2];
      changed = true;
    }
  }

  if (changed) {
    next.factsLastUpdated = new Date().toISOString();
  }

  return next;
}
