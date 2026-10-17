import { describe, it, expect } from "vitest";
import { continuesCustomerBurst } from "../src/handler.js";

// The hard turn-count cap counts EXCHANGES, not messages (2026-10-16: all 9 conversations
// that hit the cap of 14 were legitimate multi-step requests in which the customer split one
// ask across several messages; none had reached 14 exchanges when the cap fired).
const user = (id: string, body: string) => ({ id, part_type: "comment", body, author: { type: "user", id: "u1" } }) as any;
const bot = (id: string, body: string) => ({ id, part_type: "comment", body, author: { type: "admin", id: "5763097" } }) as any;
const human = (id: string, body: string) => ({ id, part_type: "comment", body, author: { type: "admin", id: "999" } }) as any;
const note = (id: string, body: string) => ({ id, part_type: "note", body, author: { type: "admin", id: "999" } }) as any;
const src = (body: string) => ({ body, author: { type: "user" } }) as any;

describe("continuesCustomerBurst", () => {
  it("a second customer message with no reply in between continues the same turn", () => {
    expect(continuesCustomerBurst(src("Hi"), [user("1", "I want to add credits")], "I want to add credits")).toBe(true);
  });

  it("a text message after an attachment-only opening message continues the same turn", () => {
    const screenshot = { body: "", author: { type: "user" }, attachments: [{ type: "upload", name: "s.png", url: "https://x/s.png", content_type: "image/png" }] } as any;
    expect(continuesCustomerBurst(screenshot, [user("1", "this credit is wrong")], "this credit is wrong")).toBe(true);
  });

  it("a customer message after Caroline replied is a new turn", () => {
    expect(continuesCustomerBurst(src("Hi"), [bot("1", "Hey! How can I help?"), user("2", "add credits")], "add credits")).toBe(false);
  });

  it("a human teammate's reply also ends the burst", () => {
    expect(continuesCustomerBurst(src("Hi"), [human("1", "Hello"), user("2", "thanks")], "thanks")).toBe(false);
  });

  it("an internal note does not end the burst", () => {
    expect(continuesCustomerBurst(src("Hi"), [note("1", "Note to team"), user("2", "link")], "link")).toBe(true);
  });

  it("fails toward counting: no live parts, first message, or current message not found", () => {
    expect(continuesCustomerBurst(src("Hi"), undefined, "Hi")).toBe(false);
    expect(continuesCustomerBurst(src("Hi"), [], "Hi")).toBe(false);
    expect(continuesCustomerBurst(src("Hi"), [user("1", "something else")], "not in the thread")).toBe(false);
  });

  it("fails toward counting when the live data lacks the current message but an older customer message has the same text", () => {
    expect(continuesCustomerBurst(src("Hi"), [user("1", "ok"), bot("2", "Sure, what's your email?")], "ok")).toBe(false);
    expect(continuesCustomerBurst(src("Hi"), [user("1", "ok"), user("2", "later msg")], "ok")).toBe(false);
  });

  it("a burst of 4 messages then a reply then 1 message = 2 exchanges", () => {
    const parts = [user("1", "b"), user("2", "c"), user("3", "d")];
    let turns = 1; // source "a" counted as the first turn
    const thread: any[] = [];
    for (const p of parts) { thread.push(p); if (!continuesCustomerBurst(src("a"), thread, p.body)) turns++; }
    thread.push(bot("4", "ok")); thread.push(user("5", "e"));
    if (!continuesCustomerBurst(src("a"), thread, "e")) turns++;
    expect(turns).toBe(2);
  });

  it("a runaway alternating loop still counts every exchange, so the cap remains a safety net", () => {
    const thread: any[] = []; let turns = 1;
    for (let i = 0; i < 20; i++) { thread.push(bot(`b${i}`, `reply ${i}`)); thread.push(user(`u${i}`, `msg ${i}`)); if (!continuesCustomerBurst(src("start"), thread, `msg ${i}`)) turns++; }
    expect(turns).toBe(21);
  });
});
