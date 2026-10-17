# Take-back notice (sent when the removal executes)

**NEW DRAFT, not reviewed.** Captain requirement (via firstmate 012, 2026-10-16): every
take-back sends the user a short, polite message. It says which credit and role, why (who
the public credits name, with the link), and how to dispute it by replying with a document.
It is sent when the removal executes, never before.

- **Sender:** Caroline's gate, `scripts/intercom-verify-request.sh send --campaign
  takeback-notice`. That campaign does not exist yet. The gate (credit-trust-caroline-t06)
  has to add it with exactly this copy, behind its own send lock, and its `--validate` has
  to report the per-day cap with exit 3.
- **Approval:** the human who approved this copy and the run passes
  `--notice-approved-by <SlackUID>` to `apply` / `notify`. It is never defaulted.
- **Source of truth:** this file. `scripts/credit_retro/notice.py` renders the same text
  for the `notice-preview` review.

## One credit

Subject: About your {role} credit on "{track_title}"

```
Hi {first_name},

I'm Caroline from Muso support. The public credits for "{track_title}" by {artist_name} name {other_names} for {role} ({evidence_source}: {evidence_url}), so we have removed the {role} credit from your profile.

If you did this work, reply to this message with one document that shows it, for example an invoice, a work order, or an email from the artist, label or studio that names the track and your role. If the document checks out, we will put the credit back. Your other credits are not affected.

Thank you,

Caroline
Muso Support
```

## Several credits (one message per user, up to 25 listed)

Subject: About {n} of your credits on Muso

```
Hi {first_name},

I'm Caroline from Muso support. The public credits name someone else for these roles, so we have removed them from your profile:
- {role} on "{track_title}" by {artist_name}: {other_names} ({evidence_source}: {evidence_url})
- ...

If you did this work, reply ... (as above)
```

## Rules

- The copy is fixed. Only the structured fields vary: first name, role, track, artist,
  the other names, the evidence URL and the source label.
- `{evidence_source}` is "public credits page", or "Spotify credits" / "Tidal credits" /
  "Spotify and Tidal credits" when a current Spotify or Tidal credit stands alone. Jaxsta
  and MLC never stand alone.
- `{other_names}` are only the names quoted in the row's recorded evidence note.
- One line per track title + artist + role: two credit requests for the same credit (e.g.
  two request ids for "Autentica" by Manuel Medrano) are one line. When that leaves one
  line, the one-credit copy is used. One message per user.
- The reason comes before the action; "If the document checks out, we will put the credit
  back" is backed by `credit-retro.py restore`. No date and no deadline (past credits).
- This notice is the user's ONLY message: no documentation wave reaches them for 30 days
  after it, and none ever restates the removal (firstmate 016).
- It never says "fraud" and never promises an outcome. It has no em dashes.
- A reply with a document goes to the existing `credit-proof` tag. If the document checks
  out, `credit-retro.py restore` re-adds the role.
