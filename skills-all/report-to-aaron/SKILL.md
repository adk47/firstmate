---
name: report-to-aaron
description: |
  Write a report or summary for Aaron Kaufman (founder, U7RP6HKUZ) the way he wants
  it, then offer to send it to him directly. For bug / data-discrepancy reports, use
  Aaron's strict protocol: describe the SYMPTOM (not the diagnosis or the fix), give a
  direct numeric comparison of Muso's data vs the source (e.g. Spotify), and use
  precise terminology. After drafting, ASK the requester whether to send it to Aaron;
  if yes, post it mentioning <@U7RP6HKUZ>, prefaced with who it's from.

  Use when: someone asks to "report an issue to Aaron", "tell Aaron about <bug / data
  problem>", "summarize this for Aaron", "flag this to Aaron", or to escalate a system
  bug or data discrepancy to Aaron.

  Triggers: "report to Aaron", "report an issue to Aaron", "summarize for Aaron",
  "tell Aaron", "flag to Aaron", "let Aaron know", "Aaron should see this",
  "escalate to Aaron"
metadata:
  version: "1.0"
  source-repo: "Muso-AI/hydra"
---

# Report to Aaron

Turn an issue or update into an Aaron-ready report, then offer to send it to him —
never auto-send.

## When this fires

Someone asks you to report or summarize something for Aaron. Two shapes:

- **Bug / data-discrepancy report** ("report an issue to Aaron", "tell Aaron the
  streams are wrong") → use **Aaron's rules** below in full.
- **General summary** ("summarize the deploy status for Aaron") → stay brief, plain,
  and precise. Don't force it into the bug-report shape, but still lead with the
  facts and name things exactly.

In both cases you **draft first, then ask before sending** (see Workflow).

## Aaron's rules (bug & data reports)

Aaron has been explicit that vague or pre-diagnosed reports cost him hours of
wheel-spinning. Follow all four:

**1. State the symptom, not the diagnosis or the solution.**
Say what the app is actually doing — visually or in the data. Do **not** guess the
underlying code cause, and do **not** propose a fix.

> "Just all you got to do is tell me what the issue is. Don't tell me where the
> problem is. Don't tell me what the solution is. Just tell me what the issue is and
> I'll go from there." — Aaron

Do **not** lean on your own AI assistant's explanation of *why* a bug happens. It
lacks context on active repo changes and the live V4 data systems, and will confidently
suggest stale V3 fixes that send Aaron down the wrong path.

**2. Compare Muso's data directly against the source, with numbers.**
Lead with the concrete numeric gap between what Muso shows and what the third-party
source (Spotify, etc.) shows. Be explicit:

> "Spotify shows these at 100,000. We're showing them at 32 (or zero). Why?"

Never a vague "the tracks aren't showing in the streams" when the real issue is a
number mismatch.

**3. Use precise terminology.**
Use the correct nouns so the problem reads transparently: *Spotify, Muso, tracks,
albums, credits, masters*. Don't blur "track" vs "album" vs "credit".

**4. Get it right on the first report.**
Put all the vital context in up front. Aaron won't play doctor running a series of
diagnostic follow-up questions — give him everything he needs to act in one pass.

## Example

❌ **Don't:** "These tracks aren't showing in the streams due to a legacy V3 database
processing bug."
*(no numbers, misstates the symptom, and asserts a diagnosis you can't verify.)*

✅ **Do:** "The stream counts for these 3 tracks show 35 on their Muso profiles, but
they're showing over 1,000 on Spotify right now."

## Workflow

1. **Draft** the summary using the rules above.
2. **Show it to the requester** so they can confirm or correct it.
3. **Ask** before sending — e.g. *"Want me to send this to Aaron directly?"*
4. **On yes** → send it to Aaron the same way the fleet already escalates to him:
   post a Slack message that mentions `<@U7RP6HKUZ>`, prefaced with the attribution
   line (see below). Use your normal reply path — don't invent new tooling.
5. **On no** → stop. Leave the draft with the requester; send nothing.

## Attribution — who it's from

The message you send Aaron must say who it's from: **the person who asked for the
report** and **which agent is relaying it**. Format:

```
<@U7RP6HKUZ> From <Requester name> (via <Agent>): <the summary>
```

Example:

```
<@U7RP6HKUZ> From Jan Delmo (via CTO):
Stream counts for 3 tracks show 35 on their Muso profiles but over 1,000 on Spotify
right now. Why?
```
