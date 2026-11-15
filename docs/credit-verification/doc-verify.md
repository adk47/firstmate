# Doc-verify: never take a returned document at face value (SHADOW)

> Captain, 2026-10-26 ~23:10Z: "…the ability to process it when it is returned looking for document fraud and ability to even communicate with the details on the document … we need to not just take the document as face value".
> Captain order, 23:30Z: "no new customer/outside copy - do NOT build or send issuer verification emails; build only extraction, forensics and independent cross-checks (fresh capture, public sources). UNKNOWN never approves. Open the PR only; the Fable verifier decides how it plugs in."

Code: `scripts/credit_verify/docverify/` and `scripts/credit-doc-verify.py`. Tests: `python3 scripts/tests/test_doc_verify.py`.

H3 ([proof-forensics.md](./proof-forensics.md)) asks whether the **file** was tampered with. Doc-verify asks whether what the document **claims** is true, using sources the user does not control. Every document that H3 judged for a linked credit request (what stage 2 reads before it can approve) passes through it.

**Shadow reader; it cannot approve a document by itself** (captain, 2026-10-27, Fable rules #1380). `verified` is evidence for stage 2 or the decider. It is never an approval on its own: a consumer reads it as evidence and must still apply its own approve rule and the account-level band.

**Shadow.** It writes only its own store, `/var/lib/hydra-credit-verify/doc-verify.sqlite` (0600), and reads the H3 proof store read-only. It changes no credit and sends nothing to anybody: no issuer email and no customer copy. How its outcome plugs into stage 2 or the decider is the Fable verifier's call. Until then, stage 2 does not read it.

## Steps (each one is a `dv_steps` row)

| Step | What | Where it comes from |
|---|---|---|
| `locate` | The document's bytes. The sha256 must equal the proof id, so a changed attachment is never verified in place of the one H3 judged. | The Intercom attachment cache, or one read-only Intercom GET plus the customer's attachment, downloaded into a 0700 dir under `/dev/shm` that is deleted afterwards |
| `text` | Text (≤ 16k chars) and file facts: PDF Creator/Producer/CreationDate/ModDate, EXIF DateTime/DateTimeOriginal/Software | The **same sandbox as H3** (`analyze.py`, `want_text`): no network, no credentials, unprivileged transient user. The parent never parses the file |
| `extract` | Issuer (name, type: label/distributor/publisher/studio/PRO/…), signatory, sender email and domain, other emails, tracks and ISRCs, credits (person, role, track, share), dates, amounts, each with a confidence | OpenRouter `deepseek/deepseek-v4.1-flash-1017` (captain's standing rule). Direct HTTP: tool-less, temperature 0, JSON output, and the ONE ZDR routing block (`model_chain.ZDR_ROUTING`: `zdr: true`, `data_collection: deny`, price sort, fp8/bf16/fp16 only, `max_price` capped — a document a creator sent us never lands on an unverified or int4/int8 host; captain 2026-11-04). The document is DATA, and every field is re-typed and bounded (`extract.validate`). Each call is a `dv_llm_calls` row (model, prompt sha256, tokens, cost). A daily cap (`CREDIT_DOC_VERIFY_DAILY_USD`, default $5) applies; no call is made once it is reached. An unparseable answer is retried once in the same run; both attempts are ledger rows, count against the cap and record `finish_reason`. When the model fails, a regex fallback extracts emails and ISRCs and marks the extraction `degraded`: a degraded extraction never verifies. Transient failures are retried on later runs, up to 3 runs |
| `forensics` | The H3 verdict **as stage 2 reads it**: the claim's own signal set (the rows H3 wrote with that verdict) passed through `stage2.claim_verdict`. A document that does not list the track is therefore never forged for it on signals that only say it fits another claim. Reading the raw verdict called 3 of 89 backfill documents forged that stage 2 sends to review (2026-10-27). Plus: `file_predates_document` (file created > 7 days before the date it says it was signed/issued/sent, soft), `document_date_future` (soft), `email_screenshot` (a picture of an email: weak), `eml_unverified` (an original `.eml`: weak until DKIM can be checked; dkimpy is not on node-8), `template_reused` (H3 F2b template family on a document of record, soft). Cross-account reuse by sha256/pHash/text is H3 F2 | H3 store + sandbox facts + extraction |
| `xc_dsp` | The claimed role on the track in Muso's trusted raw credits (Spotify, Tidal, MLC, Jaxsta) via `credit_review.evidence.classify_roles`. CONFIRMED is positive. A one-person role (mix/master) credited to someone else contradicts. The capture time is recorded | One admin GET per track (`/admin/track/{id}/raw-credits`) |
| `xc_isrc` | MusicBrainz artist relationships (producer, mix, engineer, …) and Deezer contributors plus album label, looked up by the catalog ISRC (never the document's). The claimant in the role family is positive. "Others only" is soft, because community data never contradicts | musicbrainz.org (1 req/s, shared lock), api.deezer.com |
| `xc_label` | The claimed issuer vs the release's label line (ISRC registrant code recorded). Not compared for distributors, PROs or artists | Deezer album label |
| `xc_domain` | Sender domain: free-mail (weak); NXDOMAIN (contradicts: the sender is fabricated); the issuer's **official** domain, found independently. A match is positive. A look-alike carrying the issuer's name contradicts. Any other domain is soft. A domain with no MX is soft | The fixed distributor/PRO domain table in `crosscheck.OFFICIAL_DOMAINS`, else MusicBrainz label url-rels "official homepage". **Never** the address on the document. DNS via dnspython |
| `xc_signatory` | The signatory's name on the issuer's official site (`/`, `/about`, `/about-us`, `/team`, `/contact`, `/staff`). Not found is unknown, never a contradiction | SSRF-guarded fetch (`credit_trust.websearch.http_get`) |
| `gate` | The outcome below | `gate.decide`, deterministic |

## Outcome per document, request and role (`dv_outcomes`)

| Outcome | When | Meaning for the credit (the decider reads these as evidence; never an approval by itself) |
|---|---|---|
| `forged` | H3 FORGED_LIKELY or any hard forensic signal, or a fabricated sender (look-alike or nonexistent domain) | Decline with the reason + account hold (`account_hold=1`) |
| `contradicted` | On a **fresh Spotify AND Tidal capture requested by this run** (rows captured after `Deps.fresh_since`, within 30 days), each DSP credits exactly one other person, the same one, in this one-person role, and not the claimant (Fable, 2026-10-27, D5). A stored capture, one DSP, Jaxsta/MLC/MusicBrainz alone, or two people in the role is a possible conflict: `unverifiable`, recorded with `dsp_conflict`. No capture is requested yet, so nothing is `contradicted` until that wiring lands | Hold (not a verdict); a named human confirms the first 20 declines |
| `verified` | **All of the following:** the claims were extracted (not degraded); the document supports the claim (H3 GENUINE, VERIFIED or PLAUSIBLE, or H3 SUSPECT for coverage only with the extracted credits showing the claimant in that role family on exactly that track: its normalized title, only a featured-artist credit dropped, or the catalog ISRC; never a prefix or substring); no hard or soft forensic doubt; no soft cross-check; Spotify/Tidal or MusicBrainz independently confirm the credit; the account is not on hold | Evidence only: never an approval by itself. A consumer may count it next to its own approve rule, under the account-level band |
| `unknown` | Our tooling could not decide: extraction did not run (model down, cap, document not located, sandbox failed), H3 missing or UNDETERMINED, Spotify/Tidal credits unreadable (D3) | No approval and no hold, and never a contradiction: the role PENDS, so the per-role split may still ask for it. Retried for up to 3 runs; then the last one stands |
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

The first `run` records the cutoff (`dv_state.since` = now). From then on, every document whose H3 verdict row is written after the cutoff is verified once per `VERSION` (`dv-2` since 2026-10-28).

**A rule change is a `VERSION` bump** (proof-loop lead 075). Nobody writes outcome rows by hand. `CARRY` in `docverify/__init__.py` names the previous version and the outcomes that send a document back to the reader. On the first open after the deploy, `store.carry_forward` copies, once, the rows of every document whose standing outcomes include none of those (marked `detail.carried_from`); the deployed reader re-reads the rest. `dv-1 → dv-2` (the #1452/#1457 sender rules) re-reads the documents standing `forged` or `verified`, because those rules can only remove a `forged` or block a `verified`. A rule that can change any outcome sets the set to `None`, and nothing carries. Until a document is re-read its old rows stand in no tray; the tray footer counts them (`store.awaiting_reread`). Use `--since` to widen a single run. The admin client needs the gateway env (`MUSO_API_URL` …, in `/etc/openclaw/main.env`), which the cron inherits.

## A run leaves a record, or it fails

`dv_outcomes` (with `dv_steps`) in this store is the store of record for what doc-verify decides. It is not
`proof_verifications`: that table belongs to the credit-removal executor (`credit_review/proof_verifications.py`),
asks a different question in different words, and doc-verify never writes it
(`data/proof-verifications-persist-r1/premise-check.md`).

After `runner.run` returns, `run` reads back the rows on file under its own run id through a new read-only
connection (`store.run_rows`), never from the counters the run kept, and `runner.untraced` compares the two:

| What the run says | What is on file | Result |
|---|---|---|
| it judged N claims (`pairs` + `superseded`) | fewer than N `dv_outcomes` rows | exit 70, `run FAILED: NO TRACE: judged N claim(s) and M dv_outcomes row(s) are on file ...` |
| it processed documents | no `dv_steps` row | exit 70, `run FAILED: NO TRACE: processed N document(s) and wrote zero rows ...` |
| anything | the rows cannot be read back | exit 70; unmeasured is a failure, never "it wrote them" |
| its record adds up | | exit 0 |

The run line carries what was found (`"written": {"steps": n, "outcomes": n}`). A provider refusal keeps exit 75 and
the missing trace is still logged. With `--workers`, the parent exits 1 and names the shards that left no trace.
Rows on file with no outcome are not a failure: a claim-only filing is read for its extraction, and a retried or
closed document has no verdict yet. A filing whose bytes went missing between selection and the read (`blob_owed`)
is recorded by nothing on purpose and is owed no row.

**The outcome words are pinned on both sides** (`scripts/tests/test_doc_verify_trace.py`). The gate emits six: the
five in the table above and `forged_positive` (`gate.FORGED_POSITIVE`, whose rule is in `gate.py`; it has no row in
that table yet). Other jobs read them as string literals in their own files. The test holds the gate to `EMITTED`,
every file that reads `dv_outcomes` to the words it names (`READERS`), and each reader that translates an outcome to
a position on every word (`MAPS`). Adding, renaming or dropping a word on either side fails it until the other side
is looked at; a new file that reads `dv_outcomes` fails it until it has a row.

## A claimant's filing with no credit request

A filed document is selected by its candidate credit requests. One with none (`candidate_request_ids_json = '[]'`)
is read when its account has an open claim (`runner.claim_only_docs`), because the claim document ladder
([claim-doc-ladder.md](./claim-doc-ladder.md)) decides on the extraction stored here and does not extract.

- It is read for the extraction only: `locate`, `text`, `extract`, `artifact`. No claim key, no H3, no outcome row, no hold.
- It is read once per `VERSION`. A transient failure is retried up to `MAX_EXTRACT_ATTEMPTS`; a provider outage is no answer.
- Order: behind the credit filings, ahead of the re-reads; paid accounts first. They take the room the credit
  filings leave in `--max-docs`, and never fewer than `runner.CLAIM_ONLY_FLOOR` (5) per worker, on top of it
  (`runner.claim_only_room`). The room alone selected none: on 2026-11-13 each worker had 110-135 credit filings
  owing a read for its 10 slots and 0 of 116 of these were read
  (`data/verif-claim-doc-extract-r1/report.md`). The credit filings lose no slot; a worker reads at most
  `--max-docs` + 5 documents.
- The open-claim accounts are one replica read an hour (`runner.claim_accounts`, kept in `dv_state` for every worker).
  A read that fails or answers nothing selects none of these filings and is a run error (`claim-only filings not selected`);
  so is a `proof_intake` this selection cannot read, which is never "no such filing".
- The run line counts them as `claim_only`, and the ones owing a read that it had no slot for as
  `claim_only_waiting`. `claim_only: 0` with a waiting count above 0 is a starved queue, not an empty one.
- The same blob rules as below apply: a filing whose bytes are owed by `blob-backfill` is not selected.

## Filed bytes: stored once, never re-downloaded (Fable 10-31)

On 10-30 the carried re-read loop pulled 4 support@ email filings from Gmail **2,019 times in 8 h**, then kept
retrying through the quota refusals, holding support@ at 429 for ~9 h. Rules since then (`docverify/blobs.py`):

1. **The reader never calls Gmail.**
   - `gmail_intake` stores each filed attachment's bytes by sha256 at filing time (`/var/lib/hydra-credit-verify/blobs/<sha[:2]>/<sha>`, 0600/0700).
   - A re-read reads that blob, re-hashed on every read.
   - A Gmail filing without a blob is not selected: no step, no retry, no network.
2. **`credit-doc-verify.py blob-backfill` is the only Gmail path.**
   - One fetch per message, paced (`--per-min`, default 6) and budgeted (`--max-messages`).
   - It goes through `gmail_intake.gog_raw`, which holds the shared support@ lock (#1558); the command refuses to run on code without that lock.
   - The first quota refusal stops the run and records `gmail_backoff_until` from Retry-After (15 min without one). Every run refuses until then (exit 75).
   - Its cron, `credit-doc-verify-blob-backfill`, ships `enabled: false`; arming it is its own change. Any one of three kill files stops a run before it opens a store or fetches anything: `/etc/hydra/credit-doc-verify-blob-backfill.disabled` (this command only), `/etc/hydra/credit-verify.disabled` and the support@ readers kill file. See `claim-doc-ladder.md` §"The byte-restore job ships switched off".
3. **A cache delete never implies a re-fetch.**
   - Once a blob is registered (`dv_blobs`) and later goes missing, the reader treats it as owed by blob-backfill and never downloads it again, from Gmail or Intercom.
   - An Intercom filing is fetched at most once, then stored. A registered Intercom blob that goes missing is restored by `blob-backfill` (`--intercom-max`, filer cache copy first, else one Intercom fetch paced 1/s host-wide).
   - A blob that no longer hashes is moved aside (`<sha>.corrupt`) and is owed the same way. It is never read, and never a reason to fetch.
