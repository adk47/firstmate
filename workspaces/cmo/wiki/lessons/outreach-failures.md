---
title: Outreach Failures and Hard Lessons
description: Real failures from past B2B Ads outreach batches and what we learned
type: lesson
status: active
source: muso-outreach-engine v2.1 history, MEMORY.md, email-analysis.md
last-verified: 2026-04-09
related: [[workflows/outreach-engine]], [[lessons/duplicate-sends]], [[lessons/attribution-errors]]
---

# Outreach Failures and Hard Lessons

Real failures from past B2B Ads outreach batches. Each one cost trust or burned a
prospect. The skill files encode the rules; this page captures the WHY so the
agent can reason about new edge cases.

## The MWTM Domain Variant Miss (March 4, 2026)

**What happened**: Crosscheck reported Mix With The Masters as untouched. We
sent a fresh outreach. Turned out we had an active conversation with their Head
of Digital, but on a different domain (`mwtm.com` instead of
`mixwiththemasters.com`). The crosscheck only matched on the sheet email domain
and missed the active thread.

**Root cause**: Domain variant blindness. Many companies use abbreviated domains
for email. The contact's "official" website might be one URL but their work email
is on another.

**Fix**: Always search Gmail by company NAME in addition to the exact contact email.
The `muso-outreach-sender` Step 0 crosscheck includes name searches, not just
email searches.

## The 29 of 50 QA Failure (March 16, 2026)

**What happened**: Built a 50 contact batch. Manual QA caught that 29 of the 50
were duplicates of contacts we had already emailed. The original Gmail search
missed them because outreach emails used the format "Private Invite, X. LastName"
with NO company name in the subject.

**Root cause**: Searching Gmail by company name alone missed contacts whose
subject lines had only their last name. The exclusion needed last names, not
just company names.

**Fix**: Build the exclusion DB FIRST, before any target selection. Pull every
last name from every sent outreach subject AND every company name from every GHL
opportunity. Match candidates against BOTH sets. See `muso-outreach-sender` Step 0.

## The Single Contact Per Company Lesson (March 19, 2026)

**What happened**: Sent outreach to 2 contacts at the same company simultaneously.
Looked desperate and unprofessional. Both replied and we had to apologize for the
double touch.

**Root cause**: No rule preventing parallel outreach within a company.

**Fix**: Single Contact Per Company rule. Only email a 2nd person at the same
company after the 1st has exhausted ALL 4 follow ups with no reply (or the
original email bounced). See `muso-outreach-followup`.

## The 14 "Untouched" Companies That Were Already Touched (March 19, 2026)

**What happened**: Crosscheck reported 14 untouched companies. Gmail company
name search revealed 12 of them had been contacted via a different person at the
same company. Only 2 were truly untouched.

**Root cause**: Last name matching missed company level overlap. Different
contacts at the same company have different last names.

**Fix**: Company level Gmail verification. For every candidate company, search
Gmail by company name. If ANY result, the company has been contacted. Skip ALL
new contacts from that company. Encoded in `muso-outreach-sender` Step 0.

## The EOD Spam Incident (February 27, 2026)

**What happened**: Sent 5+ duplicate EOD reports to Fede in `#clio_analyst`. The
agent kept "remembering" to send EOD and re sending it.

**Root cause**: No state tracking for "EOD already sent today".

**Fix**: EOD is once per day only. Track in state. Never re send. Hard rule in
`cmo-eod-briefing` skill.

## The Provocateur Template Death (date unclear)

**What happened**: Used a "Provocateur" template that was too aggressive for the
audience. Got terrible reply rates and a few negative responses.

**Root cause**: Tone mismatch. Cold music industry execs do not respond well to
aggressive provocation. They respond to peer level invitation.

**Fix**: Provocateur template is DEAD. Private Invite template only. Status
recognition framing, not pitch framing. See `muso-outreach-writer` for the
opening framework.

## The Em Dash Tell (ongoing)

**What happened**: Past outputs used em dashes liberally (—). Em dash overuse is
a known tell that copy was AI generated. Made our outreach look less human.

**Root cause**: AI default writing style includes em dashes.

**Fix**: Em dash prohibited in ALL output. See [[decisions/2026-04-em-dash-prohibited]].

## The Generic Template Trap (Feb to Mar 2026)

**What happened**: ~20 contacts received the identical template with only the
company name swapped. Zero replies. The successful ones had at least one
company specific line that could not work for any other company.

**Root cause**: Lazy personalization. Template plus company name is not personalization.

**Fix**: Every email must have a company specific hook in the first 1 to 2
sentences pulled from `Why Muso Ads Matters` in `company_intelligence`. The hook
line should NOT work for any other company. See `muso-outreach-writer`
personalization checklist.

## The Mocked Tests Failed in Prod Equivalent

For outreach: never trust a single source. Sheet alone, GHL alone, or Gmail
alone will lie to you (because the others are not in sync). Always crosscheck
all 4 sources before sending.

This is not a single incident, it is the pattern across most failures above.
Single source confidence is the root of every drift problem.

## What Worked (For Contrast)

### Mix With The Masters (Luke Buneo, after the miss was fixed)
Reply in hours, call booked next day, contract negotiation, campaign submitted.
The match was obvious: 41K mixing engineers on Muso, MWTM teaches mixing.

### SSL / Audiotonix (Martin Bennett)
Same day reply, added 2 colleagues, multi brand deal across SSL and Slate
Digital. One contact, multiple brands.

### Casio (Rakshak Kumar)
Replied to follow up after silence on initial. Persistence works when value
prop is clear.

### GlowBright/Pearl (Federico Cappuccilli)
Replied in 60 seconds, call next day. Most personalized email of the batch.
Mentioned specific brand (Pearl), mutual connection, "caught our attention."
Lesson: even minimal personalization dramatically increases reply speed.

## History

- 2026-04-09: page created, consolidating lessons from skill version history and MEMORY.md
