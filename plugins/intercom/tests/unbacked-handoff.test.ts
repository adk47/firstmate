import { describe, expect, it } from "vitest";
import { isPersonPromise, stripUnbackedHandoff, UNBACKED_HANDOFF_RULE } from "../src/unbacked-handoff.js";
import { ANSWER_BANK, bankEntry, BLOCKED_REPLY_FALLBACK, HANDOFF_LINE } from "../src/answer-bank.js";

const THANKS = bankEntry("document_thanks")!.text;

describe("stripUnbackedHandoff", () => {
  it("removes the closing hand-off line and leaves the answer exactly as written", () => {
    const r = stripUnbackedHandoff(`${THANKS}\n\n${HANDOFF_LINE}`);
    expect(r.body).toBe(THANKS);
    expect(r.removed).toEqual([HANDOFF_LINE]);
    expect(r.onlyPromise).toBe(false);
  });

  it("straight or curly apostrophe, same paragraph or its own", () => {
    for (const reply of [
      `${THANKS} I’m pulling in a teammate to take this from here.`,
      `${THANKS}\nI'm pulling in a teammate to take this from here.`,
      `I'm pulling in a teammate to take this from here.\n\n${THANKS}`,
    ]) {
      expect(stripUnbackedHandoff(reply).body).toBe(THANKS);
    }
  });

  it("keeps the paragraphs around a removed sentence", () => {
    const r = stripUnbackedHandoff(`First paragraph.\n\n${HANDOFF_LINE}\n\nLast paragraph.`);
    expect(r.body).toBe("First paragraph.\n\nLast paragraph.");
  });

  it("a reply that was only the promise leaves nothing, and says so", () => {
    for (const reply of [HANDOFF_LINE, `  ${HANDOFF_LINE}\n`, "I’m pulling in a teammate to take this from here."]) {
      const r = stripUnbackedHandoff(reply);
      expect(r.body).toBe("");
      expect(r.onlyPromise).toBe(true);
    }
  });

  it("the variants seen in the live inbox on 2026-11-11", () => {
    for (const s of [
      "I'm pulling in a teammate to take this from here; they can advise you in this conversation before you add anything else.",
      "I've included the company name with your request, and I'm pulling in a teammate to take this from here.",
      "I'm pulling in a teammate to help with those three credits.",
      "For the artists you represent, include their profile links too, so a teammate can guide the on-behalf claims.",
      "A teammate will review this and get back to you.",
      "Someone from our team will follow up.",
      "I'll pass you over to a specialist.",
      "Un compañero se encargará del seguimiento, y recibirás el aviso en la app y por correo.",
      "Un compañero se encargará de revisarlo.",
      "Voy a pedirle a un compañero que se encargue de esto.",
    ]) {
      expect(isPersonPromise(s), s).toBe(true);
    }
  });

  it("an honest statement ABOUT a person is not a promise and stays", () => {
    for (const s of [
      "I couldn't confirm that a teammate had personally taken this on, and I shouldn't have implied it.",
      "I'm sorry I made it sound like someone would join the chat right away.",
      "If you are writing for someone else, send their written authorisation.",
      "No teammate has been assigned to this conversation.",
      "I can't hand this conversation to a person.",
      "I won't be passing this conversation to a colleague.",
      "A teammate will not be joining this conversation.",
      "No puedo pedirle a un compañero que lo revise.",
    ]) {
      expect(isPersonPromise(s), s).toBe(false);
      expect(stripUnbackedHandoff(s).body).toBe(s);
    }
  });

  it("a negation in ANOTHER clause does not excuse the promise", () => {
    for (const s of [
      "I can't answer this myself, so I'm pulling in a teammate to take this from here.",
      "That's not something I can see. A teammate will review it.",
      "I couldn't find it, but someone from our team will follow up.",
    ]) {
      expect(stripUnbackedHandoff(s).removed.length, s).toBeGreaterThan(0);
    }
  });

  it("no approved answer-bank line loses a sentence, except the hand-off line itself", () => {
    for (const e of ANSWER_BANK) {
      const r = stripUnbackedHandoff(e.text);
      if (e.id === "handoff_line") {
        expect(r.onlyPromise).toBe(true);
        continue;
      }
      expect(r.removed, e.id).toEqual([]);
      expect(r.body, e.id).toBe(e.text);
    }
  });

  it("the line sent when a reply is refused promises nobody, so it is never stripped to nothing", () => {
    const r = stripUnbackedHandoff(BLOCKED_REPLY_FALLBACK);
    expect(r.removed).toEqual([]);
    expect(r.body).toBe(BLOCKED_REPLY_FALLBACK);
  });

  it("a reply with no promise is returned byte for byte", () => {
    const reply = "Line one.  \n\n\n\nLine two with   spaces.\n";
    expect(stripUnbackedHandoff(reply)).toEqual({ body: reply, removed: [], onlyPromise: false });
  });

  it("only removes: every character left was in the reply, in order", () => {
    const reply = `Thanks for the link. ${HANDOFF_LINE} You can add more tracks any time.`;
    const r = stripUnbackedHandoff(reply);
    let i = 0;
    for (const ch of r.body) {
      i = reply.indexOf(ch, i);
      expect(i).toBeGreaterThanOrEqual(0);
      i += 1;
    }
    expect(r.body).toBe("Thanks for the link. You can add more tracks any time.");
  });

  it("the rule name the feedback uses is stable", () => {
    expect(UNBACKED_HANDOFF_RULE).toBe("person_promise_unbacked");
  });
});
