# Intake cases

Part of the `customer-data-resolution` skill. The safety rules in its `SKILL.md` bind every case here and win over anything in this file.

Match the case after SKILL.md Procedure step 2 (live UTC state and pass condition recorded).

- Stream screenshot: extract scope, period, and numeric historical count; compare authoritative total, freshness, processing, credit direction, and audit. If mismatched, file one `data_verification` with expanded `B`/`M` numbers; keep open and change no source links before verdict.
- Plaque order: exact-match email, separate paid/processing/shipped orders from unpaid `NEW` drafts, and report paid order number, ID, creation time, and internal status. Call processing internal unless vendor state was read.
- Missing credit: resolve external track and query profile+track+role; tickets are not proof. If pending is empty and raw rows corroborate name+role, an allowlisted requester may audited-add with `{"credits":["producer"]}`. Canary one and finish only at N/N exact read-back; otherwise hand off with IDs, URL, pass condition, and SLA.
- Screenshot dispute: OCR attachments and corroborate IDs, titles, authors, profiles, and raw identities. Route same-name mismatches once; require bilateral read-back.
- Login reset loop (identity rule): treat a stated email as a lookup clue only. Resolve IDs, confirmation/claim state, and credit count through the supported read-only owner; zero credits is not proof of loss. After the auth cutover, never retry legacy/admin reset links: confirm inbox control, direct the customer to `login.muso.ai/forgot-password`, and have them use only the newest “Auth Password Reset Requested” email. With no live tool, update one handoff with the identity caveat, evidence, pass condition, and SLA. Ask once for inbox control and a redacted post-click screenshot; keep open until access read-back.
- Track analytics: verify credit, track ID, sources, customer-visible total, source-import watermark, calculation watermark, and reported ISRC. Fresh cube data or a rising total is not recovery when calculation is stale or the ISRC is absent. Finish only with a nonpending source, corrected total, and present ISRC.
- Missing source editor: resolve the exact track through the named profile’s filtered credits, not title search; confirm ID + title + artist and list sources. Add the supplied URL through the typed source workflow, then re-list after a short delay. Acceptance is not proof; `pending=true` proves attachment but not completed capture, so defer metrics until `pending=false`.
- Label-release dispute: compare `profile-labels` with paginated credits by normalized label and release ID; route once and never edit credits to force display.
- Stage/legal-name mismatch: require official URLs or ISRCs; never mutate title-only matches.
- TikTok “Original sound” without a URL: derive `musicId` and verify owner plus `videoCount`, or request its Share URL.
