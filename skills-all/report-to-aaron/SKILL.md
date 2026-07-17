---
name: report-to-aaron
description: |
  Turn any issue, update, or escalation into an Aaron-Kaufman-ready (founder, U7RP6HKUZ)
  report, then offer to send it to him directly — never auto-send, unless your own SOUL
  mandates an immediate escalation (that duty takes precedence). Pick the report shape
  first: a data-discrepancy / bug report follows Aaron's strict protocol (state the
  SYMPTOM, give a direct numeric Muso-vs-source comparison, use precise terminology); any
  other report — a status summary or an action / approval escalation — stays brief, plain,
  and precise, and MUST preserve any explicit ask or decision Aaron needs to make. After
  drafting, ASK the requester whether to send it; if yes, post it mentioning <@U7RP6HKUZ>,
  prefaced with who it's from.

  Use when: someone asks to "report an issue to Aaron", "tell Aaron about <X>", "summarize
  this for Aaron", "flag this to Aaron", "escalate to Aaron", or to relay an update or a
  decision request to Aaron.

  Triggers: "report to Aaron", "report an issue to Aaron", "summarize for Aaron",
  "tell Aaron", "flag to Aaron", "let Aaron know", "Aaron should see this",
  "escalate to Aaron"
metadata:
  version: "1.1"
  source-repo: "Muso-AI/hydra"
---

# Report to Aaron

Turn any issue, update, or escalation into an Aaron-ready report, then offer to send it
to him — never auto-send. **Exception:** if your own SOUL/policy mandates an *immediate*
escalation to Aaron, that duty takes precedence — send it right away (see Workflow → Precedence).

## Step 1 — pick the shape

Before drafting, decide which kind of report this is. The rules differ by shape, and
using the wrong ones makes the report worse.

| Shape | Looks like | How to write it |
|---|---|---|
| **A. Data-discrepancy / bug** | "the streams are wrong", "credits missing", "Muso shows the wrong number" | **Aaron's strict rules** (§A) — symptom only, numeric Muso-vs-source gap, precise nouns |
| **B. Action / approval escalation** | "approve restarting X", "need sign-off to do Y", an incident that needs Aaron to decide | Lead with concrete impact, then **keep the explicit ask and the exact target to act on** (§B). Symptom-only does NOT apply. |
| **C. Status / summary** | "summarize the deploy for Aaron", "update Aaron on X" | Brief, plain, precise (§C). Lead with the facts, name things exactly. |

**The one rule that spans every shape:** if the report contains a request, decision, or
approval ask, **keep it verbatim**. Aaron's "don't tell me the solution" rule is for
shape A only — it stops a *guessed* root cause from misleading him on a data bug. Never
use it to strip a real, verified ask out of an escalation. (That was the failure on
2026-07-17: an infra "approve restarting the pod?" escalation got rewritten into
symptoms-only, leaving Aaron nothing to approve.)

For user-requested reports you **draft first, then ask before sending** (see Workflow).
A SOUL-mandated *immediate* escalation is the exception — it bypasses the confirmation
gate and goes to Aaron right away (see Workflow → Precedence).

## §A — Aaron's rules (data-discrepancy & bug reports)

Aaron has been explicit that vague or pre-diagnosed data reports cost him hours of
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

### Example

❌ **Don't:** "These tracks aren't showing in the streams due to a legacy V3 database
processing bug."
*(no numbers, misstates the symptom, and asserts a diagnosis you can't verify.)*

✅ **Do:** "The stream counts for these 3 tracks show 35 on their Muso profiles, but
they're showing over 1,000 on Spotify right now."

## §B — action / approval escalations

An escalation exists to get Aaron to *do* or *approve* something. Keep it actionable —
the symptom-only rule from §A is the wrong tool here:

- **Lead with concrete impact** — who/what is affected, in plain terms (which users,
  which environment, which service). This is the "symptom", and it's still useful.
- **State the ask explicitly and keep it** — the decision Aaron must make ("Approve
  restarting the `longhorn-csi-plugin` pod on node-43-aw?"). Never drop it.
- **Keep the specific target needed to act** — the node, pod, deployment, env. Unlike a
  data bug, here the concrete "where" *is* the actionable context, not a misleading guess.
- **Use your agent's native escalation format if it has one** (e.g. a SOUL escalation
  template) rather than inventing a competing shape. This skill only insists you keep
  the impact **and** the ask, and that you tag Aaron with a resolvable mention (below).
- **If your SOUL marks this escalation MANDATORY and immediate, send it now — don't
  draft-and-ask.** Several SOULs require an immediate DM to Aaron for approval requests,
  tool/API failures, and suspicious events, *before* replying to the requester. That duty
  overrides the confirmation workflow; holding such an escalation to draft-and-ask would
  delay or suppress it — the same failure this skill exists to prevent (see Workflow →
  Precedence).

## §C — status / summaries

Stay brief, plain, and precise. Lead with the facts, name things exactly, and don't force
it into the bug-report shape.

## Workflow

**Precedence — policy-mandated immediate escalations bypass this workflow.** If your
agent's own SOUL/policy requires you to DM Aaron *immediately* (a MANDATORY escalation:
an approval/write-sign-off request, a failed tool or API call, a suspicious/security
event, or the like), that duty wins. Send it right away using the shape rules and the
attribution + `<@U7RP6HKUZ>` mention below — do **not** hold it to the draft-and-ask
steps. The numbered steps below are for ordinary **user-requested** reports ("report
this to Aaron"); they never override a standing "escalate immediately" mandate.

1. **Draft** the report using the rules for its shape.
2. **Show it to the requester** so they can confirm or correct it.
3. **Ask** before sending — e.g. *"Want me to send this to Aaron directly?"*
4. **On yes** → send it to Aaron the same way the fleet already escalates to him:
   post a Slack message that mentions `<@U7RP6HKUZ>`, prefaced with the attribution
   line (see below). Use your normal reply path — don't invent new tooling.
5. **On no** → stop. Leave the draft with the requester; send nothing.

## Attribution — who it's from

The message you send Aaron must say who it's from: **the person who asked for the
report** and **which agent is relaying it**. Always tag Aaron with the resolvable
user-ID mention `<@U7RP6HKUZ>` — a literal `@Aaron` is plain text and pings nobody.
Format:

```
<@U7RP6HKUZ> From <Requester name> (via <Agent>): <the report>
```

Example (data report):

```
<@U7RP6HKUZ> From Jan Delmo (via CTO):
Stream counts for 3 tracks show 35 on their Muso profiles but over 1,000 on Spotify
right now. Why?
```

Example (approval escalation):

```
<@U7RP6HKUZ> From Serhii (via DevOps) escalation: node-43-aw has broken Longhorn CSI
registration, taking down all muso-chat-dev endpoints. Dev-only reschedule is blocked
by PV affinity/capacity. Approve restarting the longhorn-csi-plugin pod on node-43-aw?
```
