import { describe, expect, it } from "vitest";
import { readFileSync } from "node:fs";
import {
  applyMergeReplyGuard,
  prepareMergeReply,
  containsMergeParagraph,
  findJudgements,
  hasMergeIntent,
  MERGE_PARAGRAPH,
  MERGE_PARAGRAPH_RETIRED,
  HANDOFF_LINE,
} from "../src/merge-reply-guard.js";

const fx = JSON.parse(
  readFileSync(new URL("./fixtures/caroline-merge-transcripts-1030.json", import.meta.url), "utf8"),
) as {
  conversations: Array<{ id: string; turns: Array<{ customer: string; reply: string }> }>;
  controls: Array<{ why: string; customer: string; reply: string }>;
};
const KEY = MERGE_PARAGRAPH.slice(0, 60);
const count = (s: string, sub: string) => s.split(sub).length - 1;

function replay(turns: Array<{ customer: string; reply: string }>) {
  let mergeIntentAt: string | null = null;
  let sentAt: string | null = null;
  return turns.map((t) => {
    const out = applyMergeReplyGuard({
      customerText: t.customer, reply: t.reply,
      mergeIntentEarlier: !!mergeIntentAt, paragraphAlreadySent: !!sentAt,
    });
    if (out.mergeIntentThisTurn) mergeIntentAt ??= "x";
    if (out.paragraphSent) sentAt ??= "x";
    return out;
  });
}

describe("merge-reply guard on the 2026-10-30 transcripts (firstmate 017)", () => {
  for (const conv of fx.conversations) {
    it(`${conv.id}: §2.4 exactly once, no judgement`, () => {
      const outs = replay(conv.turns);
      expect(outs.reduce((n, o) => n + count(o.body, KEY), 0)).toBe(conv.expectParagraphs ?? 1);
      for (const o of outs) expect(findJudgements(o.body)).toEqual([]);
    });
  }

  it("puts §2.4 before the hand-off line, straight or curly apostrophe", () => {
    for (const handoff of [HANDOFF_LINE, "I’m pulling in a teammate to take this from here."]) {
      const out = applyMergeReplyGuard({ customerText: "please merge my two profiles", reply: `Thanks. ${handoff}`, paragraphAlreadySent: false });
      expect(out.body.indexOf(KEY)).toBeLessThan(out.body.indexOf("pulling in a teammate"));
      expect(out.body.trim().endsWith(handoff)).toBe(true);
    }
  });

  it("drops the document thank-you on a profile-link turn of a merge thread", () => {
    const [, , last] = replay(fx.conversations[0].turns);
    expect(last.body).not.toContain("Everything you send here is recorded");
    expect(last.actions).toContain("replaced_doc_thanks");
  });

  it("removes a merge judgement even outside a merge thread", () => {
    const out = applyMergeReplyGuard({ customerText: "hi", reply: "Thanks. Those profiles shouldn't be merged. I'm pulling in a teammate to take this from here.", paragraphAlreadySent: false });
    expect(out.body).not.toMatch(/merged/);
    expect(out.actions).toContain("dropped_judgement");
  });

  it("never repeats §2.4 once sent, even if the model writes it again", () => {
    const out = applyMergeReplyGuard({ customerText: "merge my profiles", reply: `${MERGE_PARAGRAPH}\n\n${HANDOFF_LINE}`, paragraphAlreadySent: true });
    expect(out.body).not.toContain(KEY);
    expect(out.body).toContain("pulling in a teammate");
  });

  it("leaves the controls (billing, duplicate tracks, a real document) untouched", () => {
    for (const c of fx.controls) {
      expect(applyMergeReplyGuard({ customerText: c.customer, reply: c.reply, paragraphAlreadySent: false }).body).toBe(c.reply);
    }
  });

  it("intent: profile merges yes, track-only merges and unrelated text no", () => {
    expect(hasMergeIntent("merge 2 profiles together")).toBe(true);
    expect(hasMergeIntent("this profile is also mine: https://muso.ai/profile/x")).toBe(true);
    expect(hasMergeIntent("I have two profiles on Muso.ai")).toBe(true);
    expect(hasMergeIntent("please merge the duplicate tracks")).toBe(false);
    expect(hasMergeIntent("my credit is missing")).toBe(false);
  });

  // --- send boundary (QA on #1530) ---------------------------------------------------------
  it("a failed or gate-dropped delivery does not mark §2.4 as sent; the next turn sends it", () => {
    const state: { mergeIntentAt?: string | null; mergeParagraphSentAt?: string | null } = {};
    const first = prepareMergeReply(state, "please merge my two profiles", "Could you send both links?", "t1");
    expect(first.body).toContain(MERGE_PARAGRAPH);
    expect(first.commit(false)).toBe(true);
    expect(state.mergeIntentAt).toBe("t1");
    expect(state.mergeParagraphSentAt ?? null).toBeNull();
    const second = prepareMergeReply(state, "https://muso.ai/profile/a", "Thanks. I'm pulling in a teammate to take this from here.", "t2");
    expect(second.body).toContain(MERGE_PARAGRAPH);
    expect(second.commit(true)).toBe(true);
    expect(state.mergeParagraphSentAt).toBe("t2");
    const third = prepareMergeReply(state, "ok", `${MERGE_PARAGRAPH} ${HANDOFF_LINE}`, "t3");
    expect(third.body).not.toContain(KEY);
    expect(third.result.actions).toContain("dropped_repeat_paragraph");
    expect(third.commit(true)).toBe(false);
  });

  it("commit is idempotent and reports no change for a non-merge turn (no-op path)", () => {
    const state = {};
    const p = prepareMergeReply(state, "I was charged twice", "I'm pulling in a teammate to take this from here.", "t");
    expect(p.result.actions).toEqual([]);
    expect(p.body).toBe("I'm pulling in a teammate to take this from here.");
    expect(p.commit(true)).toBe(false);
    expect(p.commit(true)).toBe(false);
    expect(state).toEqual({});
  });

  it("an altered paragraph with the approved opening is replaced by the exact canonical text", () => {
    const out = applyMergeReplyGuard({
      customerText: "merge my two profiles",
      reply: "Merges work like this: Caroline merges them right away. I'm pulling in a teammate to take this from here.",
      paragraphAlreadySent: false,
    });
    expect(out.body).toContain(MERGE_PARAGRAPH);
    expect(out.body).not.toContain("Caroline merges them right away");
    expect(out.actions).toEqual(expect.arrayContaining(["replaced_altered_paragraph", "inserted_paragraph"]));
    expect(out.paragraphSent).toBe(true);
  });

  it("an altered paragraph after §2.4 was already sent is removed, not re-sent", () => {
    const out = applyMergeReplyGuard({ customerText: "?", reply: "Merges work like this: just wait. Thanks.", mergeIntentEarlier: true, paragraphAlreadySent: true });
    expect(out.body).not.toContain("Merges work like this");
    expect(out.paragraphSent).toBe(false);
  });

  it("a reply that was ONLY a judgement is emptied, and a merge reply keeps just the paragraph", () => {
    const state = {};
    const p = prepareMergeReply(state, "Help with my credits", "Those profiles should not be merged.", "t");
    expect(p.result.actions).toEqual(["dropped_judgement"]);
    expect(p.body).toBe("");
    // inside a merge thread the approved paragraph is the whole reply
    const m = prepareMergeReply({}, "merge my two profiles", "These shouldn't be merged.", "t");
    expect(m.body).toBe(MERGE_PARAGRAPH);
  });

  it("the guard never writes a customer line of its own: an emptied reply stays empty for the caller", () => {
    for (const customer of ["hi", "merge my profiles", "refund please"]) {
      for (const reply of ["Those profiles should not be merged.", "I can merge them. They have been merged."]) {
        for (const paragraphAlreadySent of [true, false]) {
          const body = applyMergeReplyGuard({ customerText: customer, reply, paragraphAlreadySent }).body;
          expect(body).not.toMatch(/teammate|specialist|a person|human/i);
        }
      }
      expect(applyMergeReplyGuard({ customerText: customer, reply: "Those profiles should not be merged.", paragraphAlreadySent: true }).body).toBe("");
    }
  });

  it("credit merges are not profile merges: no §2.4 on 'merge my duplicate credits' (QA on #1530)", () => {
    for (const t of ["Merge my duplicate credits", "Please merge these two credit entries", "merge them", "merge these, they're the same credit"]) {
      expect(hasMergeIntent(t)).toBe(false);
      const out = applyMergeReplyGuard({ customerText: t, reply: HANDOFF_LINE, paragraphAlreadySent: false });
      expect(out.body).toBe(HANDOFF_LINE);
    }
    expect(hasMergeIntent("merge these two profiles")).toBe(true);
    expect(hasMergeIntent("merge them: https://muso.ai/profile/a https://muso.ai/profile/b")).toBe(true);
  });

  it("a judgement wrapped across a line break, or 'not eligible to be merged', is still dropped (QA on #1530)", () => {
    for (const reply of [
      "These profiles shouldn't\nbe merged. I'm pulling in a teammate to take this from here.",
      "Your profiles are not eligible to be merged. I'm pulling in a teammate to take this from here.",
      "They are not able to\n be merged right now.\n\nI'm pulling in a teammate to take this from here.",
    ]) {
      const out = applyMergeReplyGuard({ customerText: "hi", reply, paragraphAlreadySent: true });
      expect(findJudgements(out.body)).toEqual([]);
      expect(out.body).not.toMatch(/be\s+merged/);
      expect(out.body).toContain("pulling in a teammate");
      expect(out.droppedJudgements.length).toBeGreaterThan(0);
    }
  });

  it("passive outcome claims and separation judgements are dropped (QA on #1530)", () => {
    for (const bad of [
      "Your profiles were merged.", "Both profiles are now merged.", "They've been successfully merged.",
      "The merge is complete.", "Your merge was approved.", "These profiles should stay separate.",
      "They need to remain apart.", "We'll keep them separate for now.", "The two profiles must be kept separate.",
    ]) {
      const out = applyMergeReplyGuard({ customerText: "Please merge my two profiles", reply: `${bad} I'm pulling in a teammate to take this from here.`, paragraphAlreadySent: true });
      expect(out.body, bad).toBe(HANDOFF_LINE);
      expect(out.droppedJudgements, bad).toHaveLength(1);
    }
  });

  it("combine / consolidate / unify judgements and action claims are dropped like merge ones (QA on #1530)", () => {
    for (const bad of [
      "I cannot combine your two profiles.", "These two profiles are not eligible to be combined.",
      "I can consolidate them for you.", "Your profiles have been consolidated.", "We won't unify these profiles.",
      "Your profiles were combined.",
    ]) {
      const out = applyMergeReplyGuard({ customerText: "Please merge my two profiles", reply: `${bad} I’m pulling in a teammate to take this from here.`, paragraphAlreadySent: true });
      expect(out.body, bad).toBe("I’m pulling in a teammate to take this from here.");
      expect(out.droppedJudgements, bad).toHaveLength(1);
      expect(findJudgements(out.body)).toEqual([]);
    }
    // a customer-facing ask that uses the synonym is not a judgement
    expect(findJudgements("Which profile should the others be combined into?")).toEqual([]);
  });

  it("plural / team promises to merge are dropped, merge or synonym (QA on #1530)", () => {
    for (const bad of [
      "We can merge your two profiles.", "We can combine your two profiles.", "We’ll merge your two profiles.",
      "We will consolidate them for you.", "Our team will merge them today.", "We're going to merge these.",
      "I'd be happy to merge them.", "Let me merge them for you.", "We are able to combine them.",
    ]) {
      const out = applyMergeReplyGuard({ customerText: "Please merge my two profiles", reply: `${bad} I’m pulling in a teammate to take this from here.`, paragraphAlreadySent: true });
      expect(out.body, bad).toBe("I’m pulling in a teammate to take this from here.");
      expect(findJudgements(out.body)).toEqual([]);
    }
  });

  it("active / progressive merge claims are dropped, merge or synonym (QA on #1530)", () => {
    for (const bad of [
      "We are merging your two profiles now.", "Our team is merging them now.", "I'm combining them as we speak.",
      "We're consolidating your profiles today.", "The team merged them this morning.", "They merged your profiles.",
    ]) {
      const out = applyMergeReplyGuard({ customerText: "Please merge my two profiles", reply: `${bad} I’m pulling in a teammate to take this from here.`, paragraphAlreadySent: true });
      expect(out.body, bad).toBe("I’m pulling in a teammate to take this from here.");
    }
    // noun uses and the approved copy are not claims
    for (const ok of ["We have your merge request.", "I've passed your merge request on.", MERGE_PARAGRAPH, HANDOFF_LINE]) {
      expect(findJudgements(ok), ok).toEqual([]);
    }
  });

  it("separate messages in one burst never combine into a merge ask (QA on #1530)", () => {
    expect(hasMergeIntent("Merge these duplicate tracks.\n\nMy profile page is slow to load.")).toBe(false);
    expect(hasMergeIntent("merge them\n\nalso my account email changed")).toBe(false);
    const out = prepareMergeReply({}, "Merge these duplicate tracks.\n\nMy profile page is slow to load.", HANDOFF_LINE, "t");
    expect(out.body).toBe(HANDOFF_LINE);
    expect(out.commit(true)).toBe(false); // nothing recorded, a later real ask still gets §2.4
    // a real ask inside a burst still counts
    expect(hasMergeIntent("hi\n\nplease merge my two profiles")).toBe(true);
  });

  it("modal passives and positive eligibility claims are dropped (QA on #1530)", () => {
    for (const bad of [
      "The profiles will be merged soon.", "Your profiles can be merged.", "They could easily be merged.",
      "These should be merged.", "Both are going to be merged.", "They'll be merged today.",
      "Your profiles are eligible to be merged.", "These will be combined.",
    ]) {
      const out = applyMergeReplyGuard({ customerText: "Please merge my two profiles", reply: `${bad} I’m pulling in a teammate to take this from here.`, paragraphAlreadySent: true });
      expect(out.body, bad).toBe("I’m pulling in a teammate to take this from here.");
    }
    expect(findJudgements("Which profile should the duplicates be merged into?")).toEqual([]);
  });

  it("a merge verb and a profile word in DIFFERENT sentences of one message are not a merge ask (QA on #1530)", () => {
    for (const t of ["Merge these duplicate tracks. My profile page is slow to load.",
      "Can you merge my duplicate credits? Also my account email changed.",
      "merge them. My profile picture is blurry."]) {
      expect(hasMergeIntent(t), t).toBe(false);
      const p = prepareMergeReply({}, t, HANDOFF_LINE, "t");
      expect(p.body).toBe(HANDOFF_LINE);
      expect(p.commit(true)).toBe(false);
    }
    // a bare follow-up verb right after the sentence naming the profiles still counts
    expect(hasMergeIntent("I have these two Muso profiles: https://muso.ai/profile/a https://muso.ai/profile/b. Can you merge them?")).toBe(true);
    expect(hasMergeIntent("Here is my other profile https://muso.ai/profile/b. Please merge it.")).toBe(true);
  });

  // --- r5 ruling on #1530: allow-list keyed on the word family -------------------------------
  it("(a) NEW judgement phrasings never seen in the fixtures are dropped with no regex change", () => {
    for (const bad of [
      "The merge went through.", "We've now combined both pages.", "I'd keep those as they are.",
      "Merging is not possible here.", "That merger is approved.", "The duplicate profiles are fine as is.",
      "Both pages are now unified.", "We linked your two profiles.", "Leave them separated for now, please, they stay apart.",
      "Your request to consolidate is under review.",
    ]) {
      for (const customer of ["Please merge my two profiles", "hi there"]) {
        const out = applyMergeReplyGuard({ customerText: customer, reply: `${bad} ${HANDOFF_LINE}`, paragraphAlreadySent: true, mergeIntentEarlier: false });
        expect(out.body, `${customer} | ${bad}`).toBe(HANDOFF_LINE);
      }
    }
  });

  it("(b) the approved §2.4 paragraph, each of its sentences, and the hand-off line pass untouched", () => {
    const full = `${MERGE_PARAGRAPH}\n\n${HANDOFF_LINE}`;
    expect(applyMergeReplyGuard({ customerText: "merge my profiles", reply: full, paragraphAlreadySent: false }).body).toBe(full);
    expect(applyMergeReplyGuard({ customerText: "hi", reply: HANDOFF_LINE.replace("'", "’"), paragraphAlreadySent: false }).body).toBe(HANDOFF_LINE.replace("'", "’"));
    // Sentences 2 and 3 pass alone. Sentence 1 ("Merges work like this: ...") opens the paragraph
    // and only passes as the WHOLE paragraph: alone it is an altered variant (QA round 1).
    for (const sentence of MERGE_PARAGRAPH.match(/[^.?!]+[.?!]+/g)!.map((x) => x.trim()).slice(1)) {
      expect(applyMergeReplyGuard({ customerText: "hi", reply: sentence, paragraphAlreadySent: true }).body, sentence).toBe(sentence);
    }
  });

  it("a profile-link-only turn with NO recognised merge intent never gets the §2.2 thank-you (QA on #1530)", () => {
    const docThanks = "Everything you send here is recorded against your account and your open requests. If anything else is needed, the message you get will say exactly what.";
    for (const customer of ["https://muso.ai/profile/abc", "https://muso.ai/profile/abc https://muso.ai/profile/def"]) {
      expect(hasMergeIntent(customer)).toBe(false);
      const out = applyMergeReplyGuard({ customerText: customer, reply: `Thank you. ${docThanks} ${HANDOFF_LINE}`, paragraphAlreadySent: false });
      expect(out.body).not.toContain("Everything you send here");
      expect(out.body).toBe(`Thank you. ${HANDOFF_LINE}`);
      expect(out.actions).toEqual(["replaced_doc_thanks"]);
      expect(out.body).not.toContain(KEY); // no merge intent, no §2.4
      // A reply that was ONLY the thank-you text is emptied, and the caller posts the AI-queue
      // line (channel.ts): this guard writes no customer sentence of its own any more.
      expect(applyMergeReplyGuard({ customerText: customer, reply: docThanks, paragraphAlreadySent: false }).body).toBe("");
    }
    // a real document link (not a profile) keeps it
    const doc = applyMergeReplyGuard({ customerText: "here is the split sheet https://drive.google.com/x", reply: `Thank you. ${docThanks}`, paragraphAlreadySent: false });
    expect(doc.body).toContain("Everything you send here");
  });

  it("dropping a sentence that carries a profile URL removes the whole sentence, never a URL fragment (QA on #1530)", () => {
    const out = applyMergeReplyGuard({
      customerText: "Please merge my two profiles",
      reply: "Could you send me the profile you want to merge: https://muso.ai/profile/abc? I'm pulling in a teammate to take this from here.",
      paragraphAlreadySent: true,
    });
    expect(out.body).toBe("I'm pulling in a teammate to take this from here.");
    expect(out.body).not.toMatch(/ai\/profile|muso\./);
    // a benign sentence with a URL (and an abbreviation) is kept whole
    const keep = "Is this your main profile: https://muso.ai/profile/abc? E.g. the one with more credits. I'm pulling in a teammate to take this from here.";
    expect(applyMergeReplyGuard({ customerText: "?", reply: keep, mergeIntentEarlier: true, paragraphAlreadySent: true }).body).toBe(keep);
    // a URL at the very end of a forbidden sentence
    expect(applyMergeReplyGuard({ customerText: "hi", reply: "We merged https://muso.ai/profile/a.", paragraphAlreadySent: true }).body).toBe("");
  });

  it("containsMergeParagraph: exact, the gate's /w form, HTML and curly apostrophes count; altered or partial do not (firstmate 028)", () => {
    expect(containsMergeParagraph(MERGE_PARAGRAPH)).toBe(true);
    expect(containsMergeParagraph(`Hi Sam, m${MERGE_PARAGRAPH.slice(1)} Thank you, Caroline, Muso Support`)).toBe(true);
    expect(containsMergeParagraph(`<p>Hi Sam, ${MERGE_PARAGRAPH.replace(/'/g, "’").replace(/ /g, "&nbsp;")}</p>`)).toBe(true);
    expect(containsMergeParagraph(MERGE_PARAGRAPH.replace("runs as a job", "is done by our support team"))).toBe(false);
    expect(containsMergeParagraph(MERGE_PARAGRAPH.slice(0, 120))).toBe(false);
    expect(containsMergeParagraph(`X${MERGE_PARAGRAPH.slice(1)}`)).toBe(false);
    expect(containsMergeParagraph("")).toBe(false);
  });

  it("containsMergeParagraph: the retired paragraph still counts, so a thread that already got it is never sent the new one (QA round 2 on #2040)", () => {
    // The paragraph is the only thing that stops a second insert. Changing its words without
    // keeping the old ones as an anchor re-sends it to every conversation that already has it.
    expect(containsMergeParagraph(MERGE_PARAGRAPH_RETIRED)).toBe(true);
    expect(containsMergeParagraph(`Hi Sam, m${MERGE_PARAGRAPH_RETIRED.slice(1)} Thank you, Caroline, Muso Support`)).toBe(true);
    expect(containsMergeParagraph(`<p>${MERGE_PARAGRAPH_RETIRED.replace(/'/g, "’")}</p>`)).toBe(true);
    // And the guard does not insert the current paragraph on top of it. (The retired copy's own
    // barred sentence, "I'll pass those on", is stripped by the hand-off rule, which is why the
    // assertion is that the CURRENT paragraph is absent, not that the old one survives.)
    const out = applyMergeReplyGuard({
      customerText: "can you merge my two profiles?",
      reply: `Thanks for the links.\n\n${MERGE_PARAGRAPH_RETIRED}`,
      paragraphAlreadySent: containsMergeParagraph(MERGE_PARAGRAPH_RETIRED),
    });
    expect(out.body).not.toContain(MERGE_PARAGRAPH);
    expect(out.body).not.toContain("I'll pass those on");
  });

  it("(c) benign sentences with no merge-family word pass on a merge thread", () => {
    const reply = "Thanks for the links. Which one is your main profile? I'm pulling in a teammate to take this from here.";
    const out = applyMergeReplyGuard({ customerText: "?", reply, mergeIntentEarlier: true, paragraphAlreadySent: true });
    expect(out.body).toBe(reply);
    expect(out.actions).toEqual([]);
  });

  it("(d) a reply made only of merge-family sentences carries the paragraph, never a person line", () => {
    // Nobody is assigned, so an emptied reply is the caller's AI-queue fallback, not a hand-off line.
    expect(applyMergeReplyGuard({ customerText: "hello", reply: "The merge went through. We combined them.", paragraphAlreadySent: true }).body).toBe("");
    expect(applyMergeReplyGuard({ customerText: "merge my two profiles", reply: "The merge went through.", paragraphAlreadySent: false }).body)
      .toBe(MERGE_PARAGRAPH);
  });

  it("credit/track merges with an incidental account or profile word are not profile merges (QA on #1530)", () => {
    for (const t of ["Merge duplicate credits in my account please.", "Can you merge the duplicate tracks on my profile?",
      "please merge these two songs on my page", "merge my credits into my account"]) {
      expect(hasMergeIntent(t), t).toBe(false);
      const p = prepareMergeReply({}, t, HANDOFF_LINE, "t");
      expect(p.body).toBe(HANDOFF_LINE);
      expect(p.commit(true)).toBe(false);
    }
    for (const t of ["Please merge my two Muso accounts, my tracks are split between them.",
      "merge my profiles, the credits are split", "my two profiles need merging, the songs are on both"]) {
      expect(hasMergeIntent(t), t).toBe(true);
    }
  });

  it("a profile-URL merge request with the verb mid-sentence is a merge (QA on #1530)", () => {
    for (const t of ["Could you merge https://muso.ai/profile/a with https://muso.ai/profile/b?",
      "Hi, can you please combine https://muso.ai/profile/a and https://muso.ai/profile/b"]) {
      expect(hasMergeIntent(t), t).toBe(true);
      expect(applyMergeReplyGuard({ customerText: t, reply: HANDOFF_LINE, paragraphAlreadySent: false }).body).toBe(`${MERGE_PARAGRAPH}\n\n${HANDOFF_LINE}`);
    }
    expect(hasMergeIntent("Could you merge https://muso.ai/track/a with https://muso.ai/track/b?")).toBe(false);
  });

  it("the approved paragraph and ordinary merge asks are not judgements", () => {
    expect(findJudgements(MERGE_PARAGRAPH)).toEqual([]);
    for (const ok of ["Which profile should the duplicates be merged into?", "Can you send the link to the profile you want to keep?",
      "Credits from the duplicates move onto the main profile."]) {
      expect(findJudgements(ok), ok).toEqual([]);
    }
  });

  it("line-wrapped prose without a judgement is left intact", () => {
    const reply = "Thanks for the links,\nI've got both of them.\n\nI'm pulling in a teammate to take this from here.";
    expect(applyMergeReplyGuard({ customerText: "refund please", reply, paragraphAlreadySent: false }).body).toBe(reply);
  });

  it("a merge request wrapped across a line break is still a merge (QA on #1530)", () => {
    for (const t of ["Could you merge\nmy profile with this one?", "please combine my\r\nprofiles", "I have two\nprofiles, can you merge them?"]) {
      expect(hasMergeIntent(t), JSON.stringify(t)).toBe(true);
      expect(applyMergeReplyGuard({ customerText: t, reply: HANDOFF_LINE, paragraphAlreadySent: false }).body).toBe(`${MERGE_PARAGRAPH}\n\n${HANDOFF_LINE}`);
    }
    // the track-only exclusion still holds across a wrap; a blank line still separates messages
    expect(hasMergeIntent("merge these two\ntracks please")).toBe(false);
    expect(hasMergeIntent("can you merge\n\nmy credits page is slow")).toBe(false);
  });

  it("an account merge that also mentions tracks is a profile merge (QA on #1530)", () => {
    expect(hasMergeIntent("Please merge my two Muso accounts. My tracks are split between them.")).toBe(true);
    expect(hasMergeIntent("merge my two artist pages, the songs are on both")).toBe(true);
    expect(hasMergeIntent("these two tracks are the same song, merge them")).toBe(false);
  });

  it("channel.ts commits the sent marker only after delivery, and persists it (wiring)", () => {
    const src = readFileSync(new URL("../src/channel.ts", import.meta.url), "utf8");
    // `let`, not `const`: when the output guard refuses the reply and the corrected retry passes,
    // the retry's own merge prep replaces this one, so the marker is committed for the reply that
    // was actually delivered (ai-support-quality-v1). Every assertion below is unchanged.
    const prep = src.indexOf("let mergePrep = prepareMergeReply(state, bodyForDispatch, guard.body,");
    const send = src.indexOf("const reply = await client.replyToConversation({", prep);
    const delivered = src.indexOf("commitMerge(outcome.delivered);", send);
    const failed = src.indexOf("commitMerge(false);", delivered);
    expect(prep).toBeGreaterThan(src.indexOf("const guard = sanitizeReasoningLeak(stripped);"));
    expect(send).toBeGreaterThan(prep);
    expect(delivered).toBeGreaterThan(send);
    expect(failed).toBeGreaterThan(delivered);
    expect(src.slice(prep, send)).toContain("commitMerge(false);");
    // caroline-guard-g1: a reply the output guard replaced never carried the paragraph.
    expect(src.slice(prep, send)).toMatch(/if \(mergePrep\.commit\(delivered && !outputBlocked\)\) saveSessions\(accountSessions\)/);
    expect(src.slice(prep, send)).toContain("guard.body = mergePrep.body;");
    // The swap happens only for a retry the output guard passed AND the hand-back guards did not
    // refuse. The retry is a second chance at the same reply, not an exemption from the rules that
    // refused the first one (QA 2026-11-15, channel.ts:1955).
    expect(src.slice(prep, send)).toMatch(/if \(!og2\.blocked && !outputBlocked\) \{\s*mergePrep = retryMerge;/);
    expect(src.slice(prep, send).match(/mergePrep = /g)).toHaveLength(2);
  });

});
