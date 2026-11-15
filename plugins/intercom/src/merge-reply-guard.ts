/**
 * Mechanical merge-reply guard for Caroline (firstmate 017, 2026-10-30).
 *
 * The merge doctrine (#1451, caroline-instructions-1029 §2.4) was prose-only: of 5 profile-merge
 * asks after deploy 11, one got the approved claim-first paragraph. The others got the document
 * thank-you (§2.2, triggered by the customer's PROFILE links), a status-chase line, or a bare
 * link ask. Before that deploy, one even got a judgement ("the whole ... profile shouldn't be
 * merged into yours"), which the never-reveal list forbids. A reply-time rule the model can skip
 * is not a rule, so this runs on every outbound reply, after the reasoning-leak guard:
 *
 *   1. merge intent is read from the CUSTOMER's message(s) of this turn (profile merges only;
 *      a track-only merge ask is left to its own doctrine);
 *   2. a merge JUDGEMENT sentence in the reply ("shouldn't be merged", "I can merge", "has been
 *      merged", "not eligible to merge", ...) is removed, whatever the intent;
 *   3. on a merge-intent turn, the §2.2 document thank-you is replaced: profile links are not
 *      proof documents;
 *   4. on a merge-intent turn, the approved §2.4 paragraph is inserted exactly once per
 *      conversation (before the hand-off line when there is one, else at the end). The caller
 *      persists `mergeParagraphSentAt` so it is never repeated.
 *
 * Pure and dependency-free, written in type-strippable TypeScript so the bats eval can run it
 * with `node --experimental-strip-types` against the real transcripts without a plugin build.
 */

export const MERGE_PARAGRAPH =
  "Merges work like this: claim every profile that is yours first (so we know they're all you), " +
  "then tell me which one should be the main profile. The merge is done by our verification team " +
  "and you get a message in this conversation when it's complete; credits from the duplicates move " +
  "onto the main profile. Profiles claimed by someone else, and company or label profiles, are " +
  "handled differently: I'll pass those on.";

// Detection and paragraph anchor only (captain 2026-11-14: nobody is assigned, so this sentence
// is never sent by anything): a model reply may still carry it, `unbacked-handoff.ts` removes it at
// send, and the paragraph is inserted before it when it is the closing sentence.
export const HANDOFF_LINE = "I'm pulling in a teammate to take this from here.";
// The model writes the apostrophe straight or curly (U+2019); both are the hand-off line.
const HANDOFF_RE = /I['’]m pulling in a teammate to take this from here\./;

// The §2.2 document thank-you, minus its leading "Thank you." (kept: it is just politeness).
const DOC_THANKS =
  /Everything you send here is recorded against your account and your open requests and goes to the verification team\.\s*(?:If anything else is needed, the message you get will say exactly what\.)?/i;

const PROFILE_WORD = String.raw`(?:muso\s+)?(?:profiles?|pages?|accounts?)`;

// Customer-side merge intent: an explicit merge/combine/consolidate about profiles, "two
// profiles" / "duplicate profile", or "this profile is also me/mine". Track-only merges are out.
const MERGE_INTENT: RegExp[] = [
  new RegExp(String.raw`\b(?:merg(?:e|ed|es|ing)|combin(?:e|ed|ing)|consolidat(?:e|ed|ing)|unif(?:y|ied)|join)\b[^.?!\n]{0,120}\b${PROFILE_WORD}\b`, "i"),
  new RegExp(String.raw`\b${PROFILE_WORD}\b[^.?!\n]{0,120}\b(?:merg(?:e|ed|es|ing)|combin(?:e|ed|ing)|consolidat(?:e|ed|ing))\b`, "i"),
  new RegExp(String.raw`\b(?:two|2|three|3|both|multiple|several|duplicate|duplicated|double|second)\s+(?:claimed\s+|separate\s+|different\s+)?${PROFILE_WORD}\b`, "i"),
  /\b(?:this|that|the other|another)\s+(?:muso\s+)?profile\s+is\s+(?:also\s+)?(?:me|mine)\b/i,
  /\bis also mine\b/i,
];
// Ambiguous merge verbs ("merge them", a message that starts with "merge") count only with a
// positive profile/account/page anchor: "merge my duplicate credits" is not a profile merge
// (QA on #1530).
const AMBIGUOUS_MERGE: RegExp[] = [
  /\bmerge\s+(?:it|them|those|these|both)\b/i,
  /^\s*merge\b/i,
];

const TRACK_ONLY = /\btracks?\b|\bsongs?\b|\brecordings?\b/i;
// Any profile / account / page word (or a profile URL) makes it a profile merge even when the
// customer also mentions tracks ("merge my two accounts, my tracks are split between them").
const PROFILE_ANCHOR = /\b(?:profiles?|accounts?|pages?)\b|muso\.ai\/profile\//i;

export function hasMergeIntent(customerText: string): boolean {
  // An ordinary line wrap is not a sentence break ("Could you merge\nmy profile with this one?";
  // QA on #1530). A blank line (separate message in a batch) still is, and every check below runs
  // PER MESSAGE, so two unrelated messages in one burst never combine into a merge ask.
  const t = (customerText || "").slice(0, 8000).replace(/(?<!\n[ \t]*)[ \t]*\r?\n(?![ \t]*\r?\n)[ \t]*/g, " ");
  return t.split(/\r?\n[ \t]*\r?\n/).some(blockHasMergeIntent);
}

// Words that make a merge verb about something other than a profile ("merge these duplicate
// tracks", "merge my duplicate credits").
const NON_PROFILE_TARGET = /\b(?:tracks?|songs?|recordings?|credits?|entries|entry|releases?|albums?)\b/i;

const PROFILE_TARGET = String.raw`(?:(?:my|the|these|those|both|our|all|two|2|three|3|duplicate|other|muso|artist|separate|different|old|new|of|them|together|with|into|and)\s+){0,5}(?:profiles?|accounts?|pages?\b|https?:\/\/(?:www\.)?muso\.ai\/profile\/)`;
const BOUND_PROFILE_MERGE = new RegExp(String.raw`\bmerg(?:e|es|ed|ing)\s+` + PROFILE_TARGET, "i");
// "my two profiles need merging", "both accounts merged": the profile noun right before the verb.
const PROFILE_OBJECT_MERGE = /\b(?:profiles|accounts|pages)\s+(?:(?:need|needs|to|be|get|should|merged|together|into|one)\s+){0,3}merg(?:e|ed|ing)\b/i;
const PROFILE_COUNT = new RegExp(String.raw`\b(?:two|2|three|3|both|multiple|several|duplicate|duplicated|double)\s+(?:claimed\s+|separate\s+|different\s+)?${PROFILE_WORD}\b`, "i");

// Sentences, split only on a terminator followed by whitespace, so "muso.ai/profile" stays whole.
function sentencesOf(block: string): string[] {
  return block.split(/(?<=[.?!])\s+/).filter((x) => x.trim());
}

function blockHasMergeIntent(block: string): boolean {
  // The explicit patterns are already sentence-bounded ([^.?!\n]); they are run per sentence
  // too, so nothing spans an unrelated sentence.
  const sentences = sentencesOf(block);
  return sentences.some((sentence, i) => {
    // When the sentence also names another target ("Merge duplicate credits in my account"),
    // the merge must be bound to the profiles themselves (QA on #1530): the verb directly
    // governs the profile word / URL, or the customer counts profiles ("my two accounts").
    if (NON_PROFILE_TARGET.test(sentence)) {
      const v = asMergeVerbs(sentence);
      return BOUND_PROFILE_MERGE.test(v) || PROFILE_COUNT.test(sentence) || PROFILE_OBJECT_MERGE.test(v);
    }
    if (MERGE_INTENT.some((re) => re.test(sentence))) {
      // "merge these two tracks" with no profile word is a track merge, not this guard's.
      return !(TRACK_ONLY.test(sentence) && !PROFILE_ANCHOR.test(sentence));
    }
    // The merge verb and the profile anchor must be in the SAME sentence (QA on #1530:
    // "Merge these duplicate tracks. My profile page is slow to load." is not a profile merge).
    // The one exception is a bare follow-up verb ("merge them") right after a sentence that
    // names the profiles, and only when the verb sentence names no other target.
    const verb = /\bmerg(?:e|es|ed|ing)\b/i.test(asMergeVerbs(sentence));
    if (!verb) return false;
    if (PROFILE_ANCHOR.test(sentence)) return true;
    const prev = i > 0 ? sentences[i - 1] : "";
    return (
      AMBIGUOUS_MERGE.some((re) => re.test(sentence)) &&
      !NON_PROFILE_TARGET.test(sentence) &&
      PROFILE_ANCHOR.test(prev) &&
      !NON_PROFILE_TARGET.test(prev)
    );
  });
}

// Reply-side merge judgements and merge-action claims (never-reveal list + hand-off-only rule).
const JUDGEMENT: RegExp[] = [
  /\b(?:should(?:n['’]t| not)|can(?:no|['’])?t|cannot|won['’]t|will not|must not|mustn['’]t|(?:is|are|isn['’]t|aren['’]t)\s+(?:not\s+)?(?:able|eligible|allowed)\s+to|not\s+(?:able|eligible|allowed)\s+to)\s+be\s+merged\b/i,
  /\b(?:is|are|isn['’]t|aren['’]t)\s+(?:not\s+)?(?:eligible|allowed|able)\s+(?:for|to)\s+(?:be\s+|a\s+)?merg/i,
  // Modal passives, positive or negative (QA on #1530: "The profiles will be merged soon.",
  // "Your profiles can be merged."). Only adverbs may sit between the modal and "be", so a
  // question like "Which profile should the duplicates be merged into?" is not caught.
  /\b(?:will|can|could|would|should|may|might|must|shall|(?:is|are)\s+going\s+to)\s+(?:(?:now|soon|then|easily|definitely|certainly|probably|also|both|all|likely|surely)\s+)*(?:be|get)\s+merged\b/i,
  /\b(?:['’]ll|['’]d)\s+(?:(?:now|soon|then|easily|definitely|also|both|all)\s+)*(?:be|get)\s+merged\b/i,
  /\bnot\s+(?:eligible|allowed)\s+(?:for|to)\s+(?:a\s+)?merg/i,
  /\b(?:we|i)\s+(?:won['’]t|will not|can(?:no|['’])?t|cannot|don['’]t|do not)\s+merge\b/i,
  // Any first-person or team promise to merge, singular or plural (QA on #1530: "We can merge
  // your two profiles", "We'll merge", "our team will merge"). Synonyms map via asMergeVerbs.
  // Generalized (QA on #1530: "We are merging your two profiles now", "Our team is merging
  // them"): a first-person / team subject followed within four words by a VERB form of merge
  // (merge / merges / merged / merging; synonyms via asMergeVerbs). A noun use ("your merge
  // request", "the merge") is excluded by the determiner check.
  /\b(?:I|we|us|our\s+(?:verification\s+)?team|the\s+(?:verification\s+)?team|someone|they)\b(?:['’](?:ll|d|re|m|ve))?(?:[\s,]+[\w'’]+){0,4}?\s+(?<!\b(?:a|an|the|your|my|this|that|our|their|its|any)\s)merg(?:e|es|ed|ing)\b/i,
  /\bI['’]ll\s+merge\b/i,
  /\blet\s+me\s+merge\b/i,
  /\b(?:has|have)\s+(?:now\s+)?been\s+merged\b/i,
  /\b(?:I|we)(?:['’]ve|\s+have)?\s+merged\b/i,
  /\b(?:doesn['’]t|does not|don['’]t|do not)\s+(?:look|seem|appear)\s+(?:to be\s+)?(?:like\s+)?(?:the same|yours|you)\b/i,
  /\bnot\s+the\s+same\s+(?:person|artist)\b/i,
  // Unverified outcome claims in the passive voice (QA on #1530: "Your profiles were merged").
  /\b(?:is|are|was|were|been|got|gets|get)\s+(?:now\s+|already\s+|successfully\s+|fully\s+|just\s+)?merged\b/i,
  /\b(?:the\s+|your\s+)?merge\s+(?:is|was|has\s+been|is\s+now)\s+(?:now\s+)?(?:complete|completed|done(?!\s+by)|finished|approved|rejected|declined)\b/i,
  // Separation judgements (QA on #1530: "These profiles should stay separate").
  /\b(?:should|must|will|need(?:s)?\s+to|ha(?:ve|s)\s+to|ought\s+to)\s+(?:stay|remain|be\s+kept|be\s+left|be)\s+(?:separate|apart|split|distinct|unmerged)\b/i,
  /\bkeep(?:ing)?\s+(?:them|these|those|both|the\s+(?:two\s+)?profiles|your\s+(?:two\s+)?profiles)\s+(?:separate|apart)\b/i,
];

// combine / consolidate / unify are the same act as merge (QA on #1530: "I cannot combine your
// two profiles", "not eligible to be combined", "I can consolidate them" got through). Matching
// runs on a copy with the synonyms mapped to merge forms; the delivered text is never rewritten.
function asMergeVerbs(text: string): string {
  return text
    .replace(/\b(?:combin|consolidat|unifi)ed\b/gi, "merged")
    .replace(/\bunified\b/gi, "merged")
    .replace(/\b(?:combin|consolidat)ing\b/gi, "merging")
    .replace(/\b(?:combine|consolidate|unify)\b/gi, "merge");
}

function isJudgement(sentence: string): boolean {
  const t = asMergeVerbs(sentence);
  return JUDGEMENT.some((re) => re.test(t));
}

export function findJudgements(reply: string): string[] {
  const t = asMergeVerbs(reply);
  return JUDGEMENT.filter((re) => re.test(t)).map((re) => re.source);
}

// A logical sentence runs to its terminator, across single line wraps ("These profiles
// shouldn't\nbe merged." is ONE sentence; QA on #1530). A blank line still ends it.
function splitSentences(text: string): string[] {
  // A terminator ends a sentence only when whitespace or the end follows it, so a URL
  // ("https://muso.ai/profile/abc") or "e.g." mid-word is never cut (QA on #1530: removing a
  // forbidden sentence used to deliver the fragment "ai/profile/abc?").
  return text.match(/(?:[^.?!\n]|[.?!]+(?=[^\s.?!])|\n(?!\s*\n))+(?:[.?!]+(?=\s|$)|\n\s*\n|$)/g) ?? [text];
}

// ALLOW-LIST, keyed on the word family, not the grammar (r5 ruling on #1530): a deny-list of
// judgement phrasings can never be complete, so ANY model sentence that talks about merging is
// dropped unless it is byte-identical to a sentence of the approved §2.4 paragraph or to the
// hand-off line, the only merge-mentioning texts Caroline may send. JUDGEMENT stays as a
// second net for judgements that avoid the family words.
const MERGE_FAMILY = new RegExp(
  [
    String.raw`\bmerg(?:e|ed|es|ing|er|ers)\b`,
    String.raw`\bcombin(?:e|ed|es|ing)\b`,
    String.raw`\bconsolidat(?:e|ed|es|ing)\b`,
    String.raw`\bunif(?:y|ied|ies|ying)\b`,
    String.raw`\bduplicate[sd]?\s+(?:muso\s+)?(?:profile|account|page)s?\b`,
    String.raw`\b(?:keep|keeps|keeping|stay|stays|staying|remain|remains|left|kept)\s+(?:them\s+|these\s+|those\s+|both\s+|it\s+|the\s+(?:two\s+)?profiles\s+|your\s+(?:two\s+)?profiles\s+)?(?:as\s+(?:they|it)\s+(?:are|is)|separate|separated|apart|split|distinct|unmerged)\b`,
    String.raw`\blink(?:ed|ing|s)?\s+(?:up\s+)?(?:(?:the|your|these|those|both|two|2|my|all)\s+){1,3}(?:muso\s+)?(?:profile|account|page)s?\b`,
    String.raw`\bwent\s+through\b`,
  ].join("|"),
  "i",
);
const ALLOWED_SENTENCES = new Set<string>([
  ...(MERGE_PARAGRAPH.match(/[^.?!]+[.?!]+/g) ?? []).map((x) => x.trim()),
  HANDOFF_LINE,
  HANDOFF_LINE.replace("'", "’"),
]);

function isForbiddenSentence(sentence: string): boolean {
  const t = sentence.trim();
  if (!t || ALLOWED_SENTENCES.has(t)) return false;
  return MERGE_FAMILY.test(asMergeVerbs(t)) || isJudgement(t);
}

function dropJudgementSentences(reply: string): { body: string; dropped: string[] } {
  const dropped: string[] = [];
  // The exact approved paragraph and hand-off line are kept whole (never split and re-tested).
  const esc = (x: string) => x.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const protectedRe = new RegExp(`(${esc(MERGE_PARAGRAPH)}|${HANDOFF_RE.source})`, "g");
  const parts = reply.split(protectedRe);
  const out = parts.map((part, i) => {
    if (i % 2 === 1) return part;
    return splitSentences(part)
      .filter((s) => {
        if (isForbiddenSentence(s)) {
          dropped.push(s.trim());
          return false;
        }
        return true;
      })
      .join("");
  });
  return { body: out.join("").replace(/[ \t]{2,}/g, " ").replace(/[ \t]+\n/g, "\n").replace(/\n{3,}/g, "\n\n").trim(), dropped };
}

export interface MergeGuardInput {
  customerText: string;
  reply: string;
  // true once an earlier customer turn in this conversation showed merge intent (persisted by
  // the caller): "merge 2 profiles" then, two turns later, a bare link is still a merge thread.
  mergeIntentEarlier?: boolean;
  // true once §2.4 was sent in this conversation (persisted by the caller).
  paragraphAlreadySent: boolean;
}

export interface MergeGuardResult {
  body: string;
  mergeIntent: boolean;
  actions: Array<"dropped_judgement" | "replaced_doc_thanks" | "inserted_paragraph" | "dropped_repeat_paragraph" | "replaced_altered_paragraph">;
  droppedJudgements: string[];
  // true when the returned body carries §2.4 (the caller sets mergeParagraphSentAt).
  paragraphSent: boolean;
  // true when THIS turn's customer text shows merge intent (the caller sets mergeIntentAt).
  mergeIntentThisTurn: boolean;
}

const PROFILE_LINK = /muso\.ai\/profile\//i;
const ANY_LINK = /https?:\/\/\S+/gi;

// The customer's turn carries only Muso PROFILE links (the merge pair), no other link: a §2.2
// "everything you send is recorded / goes to verification" reply to it is the wrong paragraph.
function onlyProfileLinks(text: string): boolean {
  const links = text.match(ANY_LINK) ?? [];
  return links.length > 0 && links.every((l) => PROFILE_LINK.test(l));
}

function cutVariant(body: string, at: number): string {
  const rest = body.slice(at);
  const ends = [rest.indexOf("\n\n"), (HANDOFF_RE.exec(rest) ?? { index: -1 }).index].filter((i) => i > 0);
  const end = ends.length ? Math.min(...ends) : rest.length;
  return (body.slice(0, at) + rest.slice(end)).replace(/[ \t]{2,}/g, " ").replace(/\n{3,}/g, "\n\n").trim();
}

export function applyMergeReplyGuard(input: MergeGuardInput): MergeGuardResult {
  const actions: MergeGuardResult["actions"] = [];
  const mergeIntentThisTurn = hasMergeIntent(input.customerText);
  const mergeIntent = mergeIntentThisTurn || !!input.mergeIntentEarlier;
  let body = input.reply ?? "";


  // Only the exact approved paragraph counts. A variant that starts like it but says something
  // else is removed (from its first words to the end of that paragraph or the hand-off line)
  // and the canonical text goes in instead.
  const lead = "Merges work like this";
  let altered = false;
  for (let guardN = 0; guardN < 5; guardN++) {
    const at = body.indexOf(lead);
    if (at < 0) break;
    if (body.startsWith(MERGE_PARAGRAPH, at)) {
      const next = body.indexOf(lead, at + MERGE_PARAGRAPH.length);
      if (next < 0) break;
      // a second (possibly altered) copy after an exact one: cut it
      body = cutVariant(body, next);
      altered = true;
      continue;
    }
    body = cutVariant(body, at);
    altered = true;
  }
  if (altered) actions.push("replaced_altered_paragraph");

  const j = dropJudgementSentences(body);
  if (j.dropped.length > 0) {
    body = j.body;
    actions.push("dropped_judgement");
  }
  // A Muso profile link is not proof: the §2.2 document thank-you never answers a turn that
  // carries only profile links, or a merge ask, whether or not merge intent was recognised
  // (QA on #1530).
  const docThanksStripped = DOC_THANKS.test(body) && (mergeIntentThisTurn || onlyProfileLinks(input.customerText));
  if (docThanksStripped) {
    body = body.replace(DOC_THANKS, "").replace(/[ \t]{2,}/g, " ").replace(/[ \t]+\n/g, "\n").replace(/\n{3,}/g, "\n\n").trim();
    actions.push("replaced_doc_thanks");
  }
  const hasParagraph = body.includes(MERGE_PARAGRAPH);
  if (!mergeIntent) {
    // A reply that was ONLY a judgement must not turn into silence (QA on #1530). This module
    // writes no customer line of its own any more: the caller posts the AI-queue fallback line
    // for an emptied body (channel.ts).
    return { body: body.trim() ? body : "", mergeIntent, actions, droppedJudgements: j.dropped, paragraphSent: hasParagraph, mergeIntentThisTurn };
  }


  let paragraphSent = hasParagraph;
  if (hasParagraph && input.paragraphAlreadySent) {
    // Exactly once per conversation: the model repeating it on a later turn is dropped.
    body = body.replace(MERGE_PARAGRAPH, "").replace(/[ \t]{2,}/g, " ").replace(/\n{3,}/g, "\n\n").trim();
    actions.push("dropped_repeat_paragraph");
    paragraphSent = false;
  } else if (!hasParagraph && !input.paragraphAlreadySent) {
    const m = HANDOFF_RE.exec(body);
    const idx = m ? m.index : -1;
    if (idx >= 0) {
      const before = body.slice(0, idx).trimEnd();
      body = (before ? `${before}\n\n` : "") + `${MERGE_PARAGRAPH}\n\n${body.slice(idx)}`;
    } else {
      body = (body ? `${body}\n\n` : "") + MERGE_PARAGRAPH;
    }
    actions.push("inserted_paragraph");
    paragraphSent = true;
  }
  if (!body.trim()) {
    body = input.paragraphAlreadySent ? "" : MERGE_PARAGRAPH;
    paragraphSent = paragraphSent || !input.paragraphAlreadySent;
  }
  return { body, mergeIntent, actions, droppedJudgements: j.dropped, paragraphSent, mergeIntentThisTurn };
}

// --- send boundary --------------------------------------------------------------------------
// The per-conversation markers must reflect what the customer actually RECEIVED (QA on #1530):
// mergeParagraphSentAt is committed only after a delivered reply, so a failed or gate-dropped
// send never suppresses the paragraph next turn; mergeIntentAt describes the customer's own
// message and is committed either way. commit() returns true when the state changed, so the
// caller persists it (a restart must not forget the paragraph went out and repeat it).
export interface MergeGuardState {
  mergeIntentAt?: string | null;
  mergeParagraphSentAt?: string | null;
}

export interface PreparedMergeReply {
  body: string;
  result: MergeGuardResult;
  commit(delivered: boolean): boolean;
}

export function prepareMergeReply(
  state: MergeGuardState, customerText: string, reply: string, now: string,
): PreparedMergeReply {
  const result = applyMergeReplyGuard({
    customerText, reply,
    mergeIntentEarlier: !!state.mergeIntentAt,
    paragraphAlreadySent: !!state.mergeParagraphSentAt,
  });
  let committed = false;
  return {
    body: result.body,
    result,
    commit(delivered: boolean): boolean {
      if (committed) return false;
      committed = true;
      let changed = false;
      if (result.mergeIntentThisTurn && !state.mergeIntentAt) { state.mergeIntentAt = now; changed = true; }
      if (delivered && result.paragraphSent && !state.mergeParagraphSentAt) { state.mergeParagraphSentAt = now; changed = true; }
      return changed;
    },
  };
}

// --- §2.4 already in the thread (r5 504 / firstmate 028) -------------------------------------
// The same approved paragraph can reach a thread WITHOUT this plugin: the verify gate posts
// fable-copy-1031-r5/w ("Hi {first}, merges work like this: ...", §2.4 verbatim after the
// greeting) as Caroline's admin, and operators re-contact through intercom-ops-write.sh. Neither
// sets mergeParagraphSentAt, so the guard would add §2.4 a second time on the customer's next
// merge ask. The live conversation read (handler.ts) runs this over Caroline's own visible parts:
// HTML stripped, whitespace collapsed, the first letter compared case-insensitively (the ref
// lowercases it after the greeting); every other byte must match.
export function containsMergeParagraph(text: string): boolean {
  const plain = (text || "")
    .replace(/<[^>]*>/g, " ")
    .replace(/&nbsp;/g, " ")
    .replace(/&amp;/g, "&")
    .replace(/&#39;|&apos;|&rsquo;/g, "'")
    .replace(/[’]/g, "'")
    .replace(/\s+/g, " ");
  const tail = MERGE_PARAGRAPH.slice(1);
  let at = plain.indexOf(tail);
  while (at > 0) {
    if (plain[at - 1].toLowerCase() === MERGE_PARAGRAPH[0].toLowerCase()) return true;
    at = plain.indexOf(tail, at + 1);
  }
  return false;
}
