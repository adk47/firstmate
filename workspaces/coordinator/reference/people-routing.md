# Coordinator — people routing table

> Moved out of `MEMORY.md` on 2026-08-26, **content unchanged**. It was NOT stale — it
> already mapped `U038BM16T7W` to Jan Delmo correctly and already listed former staff — so
> it is relocated, not rewritten. It left `MEMORY.md` because that file is injected at agent
> bootstrap under a combined size cap past which the middle is silently dropped, and a
> lookup table is the right thing to move out: you consult it when a UID appears, not on
> every boot. `shared-reference/reference/slack-people.json` remains the authority; this is
> the routing layer on top of it.

### People Quick Reference (for Routing)

**`shared-reference/reference/slack-people.json` is authoritative for WHO these
people are.** The nine rows below are its `kind:"human"` + `current:true`
entries — the complete current staff. The `Route to Agent` column is this
agent's own policy, not roster data. If a UID is not below, resolve it against
the roster before naming anyone; never invent a person from a display name.

| Slack User ID | Name | Role | Route to Agent |
|---------------|------|------|----------------|
| U7RP6HKUZ | Aaron Kaufman | CEO | CEO agent |
| U0AL36NADEY | Nicholas Sollazzo | Chief Agent Officer | answer directly (operator) |
| U03TYGJF1N3 | Serhii Ostapchuk | CTO | CTO agent |
| U038BM16T7W | Jan Delmo | Head of Operations | Operations agent |
| U02N2NP3H7F | Artem | Mobile Developer | CTO agent |
| U03LP8YHLPK | Mariia Bubley | Head of Product / UI & UX | (no product agent — answer directly) |
| U0A8CCTTAAG | Liza Basco | Accountant | Finance agent |
| U0AV9C7CFRQ | Faith Undie | Community & Social Media | CMO agent |
| U02S7C96CGN | McLaren Amberti | Sales Operations | Operations agent |

**Former staff — never route to them, never describe them as a colleague in the
present tense.** They appear in historical threads only: Fede Pahlen
(U07NF5A77E2, ex-CMO — transition-restricted 2026-06-22; do not route to any
agent without Aaron's explicit per-request approval), Andrey Morskoy
(U0302FZQGCB, ex-Platform/Data Lead), Oleg (U02S7TJ7QHY, ex-Engineer), Artem
Dolobanko (U0ACHTYUULT, ex-DevOps Lead), Volodymyr Popov (U0ACLT0GF9T), Dmytro
Ovdii (U0AH52J8BKM), Bohdan (U0AD37S5QAV), Ihor Shchuruk (U042AG73FEK). Names
that used to sit in this table without a Slack ID — Jeff, Kazy, Dima, "Ihor
(Kopaniev)" — are not on the roster and are not current Muso staff; do not
route to them either.
