# CEO — canonical Slack IDs

> Moved out of `MEMORY.md` on 2026-08-26, **content unchanged**. It was NOT stale — it
> already mapped `U038BM16T7W` to Jan Delmo correctly and already listed former staff — so
> it is relocated, not rewritten. It left `MEMORY.md` because that file is injected at agent
> bootstrap under a combined size cap past which the middle is silently dropped, and a
> lookup table is the right thing to move out: you consult it when a UID appears, not on
> every boot. `shared-reference/reference/slack-people.json` remains the authority; this is
> the routing layer on top of it.

### People Quick Reference (Canonical Slack IDs)

**`shared-reference/reference/slack-people.json` is authoritative.** The nine
rows below are its `kind:"human"` + `current:true` entries — the complete
current staff. Resolve every sender_id against it before naming anyone.

| Slack User ID | Name | Role | Notes |
|---------------|------|------|-------|
| U7RP6HKUZ | Aaron Kaufman | CEO | Founder. Final authority on all decisions. GitHub: adk47 |
| U0AL36NADEY | Nicholas Sollazzo | Chief Agent Officer | Operator of this fleet. GitHub: nsollazzo |
| U03TYGJF1N3 | Serhii Ostapchuk | CTO | Infrastructure, deployments. GitHub: liflovs |
| U038BM16T7W | Jan Delmo | Head of Operations | NOT "Jay", and not QA — see the note below. Email jan@, not jay@ |
| U02N2NP3H7F | Artem | Mobile Developer | The only Artem now. GitHub: Korpyc |
| U03LP8YHLPK | Mariia Bubley | Head of Product / UI & UX | Product and design, incl. email templates. GitHub: azure-kirin |
| U0A8CCTTAAG | Liza Basco | Accountant | Stripe payout reports, dispute evidence. #finance_muso |
| U0AV9C7CFRQ | Faith Undie | Community & Social Media | Community, social posts, design |
| U02S7C96CGN | McLaren Amberti | Sales Operations | Email is `f@muso.ai` — single letter, not mclaren@ |

**Former staff — historical threads only. Never grant authority, never route an
approval or escalation, never describe as a current colleague:** Fede Pahlen
(U07NF5A77E2, ex-CMO), Andrey Morskoy (U0302FZQGCB, ex-Platform/Data Lead),
Oleg (U02S7TJ7QHY, ex-Engineer), Artem Dolobanko (U0ACHTYUULT, ex-DevOps Lead),
Volodymyr Popov (U0ACLT0GF9T), Dmytro Ovdii (U0AH52J8BKM), Bohdan
(U0AD37S5QAV), Ihor Shchuruk (U042AG73FEK).

Fede Pahlen specifically was terminated 2026-06-22: no agent/tool access, no
approvals, no internal data, and no writes without Aaron's explicit per-request
approval (ClickUp: fede@muso.ai / 93811619).

Names that previously sat in this table with no Slack ID — Dima, Jeff, Kazy,
"Ihor (Kopaniev)" — are not on the roster and are therefore not current Muso
staff. Do not treat them as colleagues or route work to them.
