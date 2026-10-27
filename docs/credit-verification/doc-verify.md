# Doc-verify: never take a returned document at face value (SHADOW)

> Captain, 2026-10-26 ~23:10Z: "…the ability to process it when it is returned looking for document fraud and ability to even communicate with the details on the document … we need to not just take the document as face value".
> Captain order, 23:30Z: "no new customer/outside copy - do NOT build or send issuer verification emails; build only extraction, forensics and independent cross-checks (fresh capture, public sources). UNKNOWN never approves. Open the PR only; the Fable verifier decides how it plugs in."

Code: `scripts/credit_verify/docverify/` and `scripts/credit-doc-verify.py`. Tests: `python3 scripts/tests/test_doc_verify.py`.

H3 ([proof-forensics.md](./proof-forensics.md)) asks whether the **file** was tampered with. Doc-verify asks whether what the document **claims** is true, using sources the user does not control. Every document that H3 judged for a linked credit request (what stage 2 reads before it can approve) passes through it.

**Shadow reader; it cannot approve a document by itself** (captain, 2026-10-27, Fable rules #1380). `verified` is evidence for stage 2 or the decider. It is never an approval on its own, and nothing reads it to approve. Whatever later consumes it must still apply its own approve rule and the account-level band.

**Shadow.** It writes only its own store, `/var/lib/hydra-credit-verify/doc-verify.sqlite` (0600), and reads the H3 proof store read-only. It changes no credit and sends nothing to anybody: no issuer email and no customer copy. How its outcome plugs into stage 2 or the decider is the Fable verifier's call. Until then, stage 2 does not read it.

## Steps (each one is a `dv_steps` row)

| Step | What | Where it comes from |
|---|---|---|
| `locate` | The document's bytes. The sha256 must equal the proof id, so a changed attachment is never verified in place of the one H3 judged. | The Intercom attachment cache, or one read-only Intercom GET plus the customer's attachment, downloaded into a 0700 dir under `/dev/shm` that is deleted afterwards |
| `text` | Text (≤ 16k chars) and file facts: PDF Creator/Producer/CreationDate/ModDate, EXIF DateTime/DateTimeOriginal/Software | The **same sandbox as H3** (`analyze.py`, `want_text`): no network, no credentials, unprivileged transient user. The parent never parses the file |
| `extract` | Issuer (name, type: label/distributor/publisher/studio/PRO/…), signatory, sender email and domain, other emails, tracks and ISRCs, credits (person, role, track, share), dates, amounts, each with a confidence | OpenRouter `deepseek/deepseek-v4.1-flash-1017` (captain's standing rule). Direct HTTP: tool-less, temperature 0, JSON output, provider `data_collection: deny`. The document is DATA, and every field is re-typed and bounded (`extract.validate`). Each call is a `dv_llm_calls` row (model, prompt sha256, tokens, cost). A daily cap (`CREDIT_DOC_VERIFY_DAILY_USD`, default $5) applies; no call is made once it is reached. An unparseable answer is retried once in the same run; both attempts are ledger rows, count against the cap and record `finish_reason`. When the model fails, a regex fallback extracts emails and ISRCs and marks the extraction `degraded`: a degraded extraction never verifies. Transient failures are retried on later runs, up to 3 runs |
| `forensics` | The H3 verdict **as stage 2 reads it**: the claim's own signal set (the rows H3 wrote with that verdict) passed through `stage2.claim_verdict`. A document that does not list the track is therefore never forged for it on signals that only say it fits another claim. Reading the raw verdict called 3 of 89 backfill documents forged that stage 2 sends to review (2026-10-27). Plus: `file_predates_document` (file created > 7 days before the date it says it was signed/issued/sent, soft), `document_date_future` (soft), `email_screenshot` (a picture of an email: weak), `eml_unverified` (an original `.eml`: weak until DKIM can be checked; dkimpy is not on node-8), `template_reused` (H3 F2b template family on a document of record, soft). Cross-account reuse by sha256/pHash/text is H3 F2 | H3 store + sandbox facts + extraction |
| `xc_dsp` | The claimed role on the track in Muso's trusted raw credits (Spotify, Tidal, MLC, Jaxsta) via `credit_review.evidence.classify_roles`. CONFIRMED is positive. A one-person role (mix/master) credited to someone else contradicts. The capture time is recorded | One admin GET per track (`/admin/track/{id}/raw-credits`) |
| `xc_isrc` | MusicBrainz artist relationships (producer, mix, engineer, …) and Deezer contributors plus album label, looked up by the catalog ISRC (never the document's). The claimant in the role family is positive. "Others only" is soft, because community data never contradicts | musicbrainz.org (1 req/s, shared lock), api.deezer.com |
| `xc_label` | The claimed issuer vs the release's label line (ISRC registrant code recorded). Not compared for distributors, PROs or artists | Deezer album label |
| `xc_domain` | Sender domain: free-mail (weak); NXDOMAIN (contradicts: the sender is fabricated); the issuer's **official** domain, found independently. A match is positive. A look-alike carrying the issuer's name contradicts. Any other domain is soft. A domain with no MX is soft | The fixed distributor/PRO domain table in `crosscheck.OFFICIAL_DOMAINS`, else MusicBrainz label url-rels "official homepage". **Never** the address on the document. DNS via dnspython |
| `xc_signatory` | The signatory's name on the issuer's official site (`/`, `/about`, `/about-us`, `/team`, `/contact`, `/staff`). Not found is unknown, never a contradiction | SSRF-guarded fetch (`credit_trust.websearch.http_get`) |
| `gate` | The outcome below | `gate.decide`, deterministic |

## Outcome per document, request and role (`dv_outcomes`)

| Outcome | When | Meaning for the credit (once a consumer is wired; today nothing reads it) |
|---|---|---|
| `forged` | H3 FORGED_LIKELY or any hard forensic signal, or a fabricated sender (look-alike or nonexistent domain) | Decline with the reason + account hold (`account_hold=1`) |
| `contradicted` | Spotify/Tidal credit this one-person role on the track to someone else | Decline with the reason + account hold |
| `verified` | **All of the following:** the claims were extracted (not degraded); the document supports the claim (H3 GENUINE, VERIFIED or PLAUSIBLE, or H3 SUSPECT for coverage only with the extracted credits showing the claimant in that role family on exactly that track: its normalized title, only a featured-artist credit dropped, or the catalog ISRC; never a prefix or substring); no hard or soft forensic doubt; no soft cross-check; Spotify/Tidal or MusicBrainz independently confirm the credit; the account is not on hold | Evidence only: never an approval by itself. A consumer may count it next to its own approve rule, under the account-level band |
| `unverifiable` | Everything else. **UNKNOWN never approves** | `need` names the stronger proof: `distributor_dashboard_with_code`, `issuer_email_from_official_domain`, `counterparty_signed_or_registered`, `readable_document`, `account_on_hold`. These are machine codes; the copy is not written here |

**Low-confidence extraction is never evidence** (QA, Fable, 2026-10-27). Below confidence 0.6, an extracted field cannot make an outcome on its own. A confidence that is not a finite number (NaN, Infinity, a string, `true`) reads as 0.0, and every floor is written so NaN fails it. A sender read that low is `weak`: it is not looked up, and it can never forge a document or hold an account. An issuer or signatory read that low is not used. A track or ISRC read that low cannot bind a credit to the claimed track. A credit read that low does not count.

A weak finding (an email screenshot, a free-mail sender) never verifies on its own. It can stand next to an independent confirmation of the credit.

## Eval (node-8, 2026-10-27 00:22Z, `dv-1`)

Manifest from `eval-select`, which reads the H3 store and Trino read-only and makes 152 admin GETs:
- **Forged:** the 2 documents behind the 11 `reject_hold` claims of users 121667 and 184339 (`to-human-1026.md`).
- **Known-good:** 20 documents from 20 other users. Each is a document H3 did not call forged, for a claim that Spotify/Tidal already credit to the claimant in that role.

The run took 22 documents in 4.5 min and made 18 DeepSeek calls for $0.0103.

| set | documents / claims | forged | contradicted | verified | unverifiable |
|---|---|---|---|---|---|
| likely forged | 2 / 11 | **11** | 0 | **0** | 0 |
| known-good | 20 / 20 | **0** | **0** | 2 | 18 |

The forged pair are BeatStars beat-lease PDFs. One is a lease for one beat, reused to claim Producer on 8 other tracks; Spotify/Tidal credit other producers on them. Extraction names the issuer and the leased track, which is what turns "H3 reuse" into a reason a human can read.

"Known-good" means the **credit** is real, not that the **document** proves it. Of the 18 unverifiable good documents:
- 5 credit the claimant on **another** track (the reason names that track);
- 4 have no readable text;
- 9 are screenshots that do not tie the claimant to this track and role.

None of them is a false decline. The decider can approve those credits from the DSP evidence directly; the document alone does not prove them, and doc-verify says so.

## Not in this slice

- **Issuer confirmation emails** (spec step 4) were cut by the captain's 23:30Z order: no outside copy.
- **A live DSP re-capture.** `xc_dsp` reads Muso's last catalog capture (its time is recorded). The live Spotify+Tidal check is core-backend's removal gate (#10765), not on prod yet.
- **DKIM on a forwarded `.eml`** needs dkimpy on node-8. Until then an `.eml` is weak.
- **Discogs/AllMusic/Qobuz/Apple** credits need keys or scraping; MusicBrainz and Deezer are the free structured sources reachable from node-8.

## Running

```bash
python3 /opt/hydra/scripts/credit-doc-verify.py run --max-docs 30        # the cron (hourly :50)
python3 /opt/hydra/scripts/credit-doc-verify.py summary
python3 /opt/hydra/scripts/credit-doc-verify.py eval-select --out /tmp/m.json          # forged users + 20 known-good
python3 /opt/hydra/scripts/credit-doc-verify.py --store /tmp/eval.sqlite eval --manifest /tmp/m.json
sqlite3 /var/lib/hydra-credit-verify/doc-verify.sqlite \
  "select outcome, need, count(*) from dv_outcomes group by 1, 2"
```

Consumers read the **latest** row per (proof, request, role, version) (`DocVerifyStore.latest_outcomes`). An account hold appends an `unverifiable` / `account_on_hold` row over every standing `verified` outcome of the account, whichever document came first (`supersede_verified`).

The first `run` records the cutoff (`dv_state.since` = now). From then on, every document whose H3 verdict row is written after the cutoff is verified once per `VERSION` (`dv-1`). Use `--since` to widen a single run. The admin client needs the gateway env (`MUSO_API_URL` …, in `/etc/openclaw/main.env`), which the cron inherits.
