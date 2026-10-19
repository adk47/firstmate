# Supporting-document forensics (H3, shadow)

> First principle (captain, 2026-10-15): "key architecture princple is that we process credit requests quickly and with email channel and intercom channels active for credit veification documents and proof with fraud detection".
>
> So proof can arrive by **email or Intercom**. It is matched to the user **by account**, never by what the text claims. **Every** document passes fraud detection before it counts as evidence.
>
> Design: firstmate task record `data/credit-retro-hold-docfraud-f1/report.md` §7 (PR-2). This page is the operator's view.

Code: `scripts/credit_verify/proof/` plus `scripts/credit-proof.py`. **Shadow only**: it writes its own store and nothing else.

## What runs

| Cron (`cron-jobs.json`) | Command | Input |
|---|---|---|
| `credit-verify-proof-intercom` (:05, :35) | `credit-proof.py intercom --days 2 --max-files 300` | Intercom attachments that Caroline's edge plugin caches under `/root/.openclaw-edge/media/intercom/<conversation>/notif_*/<n>.<ext>`. Only **proof conversations** count: a teammate or the bot asked for documentation, and the customer attached a file after that ask. Only the files the customer sent **after the first ask** are analysed; files cached before it (an avatar, an app-error screenshot) are skipped. Each conversation costs one read-only Intercom GET. PDF page renders (`<n>-p-<k>.png`) are skipped; the original PDF is analysed. |
| `credit-verify-proof-email` (*/10, **disabled** until the verify@ address exists) | `credit-proof.py email` | Raw messages delivered to the inbound verification address (E-IN), in the Maildir `/var/lib/hydra-credit-verify/inbound-email/new/`. A no-op until H-DevOps routes the address there. |

Store: `/var/lib/hydra-credit-verify/proof.sqlite`, mode 0600, append-only. It mirrors core C1b's planned tables:
- `forensics`: one row per signal;
- `fingerprints`;
- `verdicts`;
- `proofs`.

It holds **no document text**: only signals with cited regions, hashes and entity hashes (including a hash of the credited name on the page that the claimant matched: the run of name words, within one list item, that holds the whole name, without role words or numbers, folded and word-sorted; never the account's own spelling of the name. When several runs hold the name, the bare one contained in all the others counts. A surname-first name split by one comma ("Alpha, Ann") is hashed as the sorted name when it forms one of the fixed pairs of its comma list, read two items at a time from the start ("Alpha, Ann, Beta, Bob" holds "Alpha, Ann" and "Beta, Bob", never "Ann, Beta"; items with no name word, such as "Writers" or "2024", are dropped before pairing; a list with an odd number of items holds no pairs). Any other name whose words land in different list items, or that has no such bare run, identifies nobody and is stored as unknown). An older store gets new columns added in place on open; its old rows read as unknown.

An UNDETERMINED verdict (a check could not run, e.g. a sandbox timeout) is not final. The file is analysed again on later runs, up to 3 attempts per proof, submitter, track and request. An email whose attachment is still UNDETERMINED stays in `new/` until then.

## Email channel (E-IN)

- **Sender authentication:** a message counts only when the receiving MTA we trust has authenticated the sender. That is `Authentication-Results` whose authserv-id (the first token before `;`) is exactly `CREDIT_PROOF_EMAIL_AUTHSERV` (default `mx.cloudflare.net`), with `dmarc=pass`, or `dkim=pass` for a domain aligned with From. The first such header, the topmost one, decides. Headers from earlier hops are ignored, and so are look-alike ids such as `mx.cloudflare.net.attacker`. The receiving MTA must stamp every message and strip incoming headers that carry its id; that is part of the transport change below.
- **Account match:** the From address must be the email of **exactly one** Muso user, and that email must be confirmed (`emailConfirmed` is `true`). The lookup is `GET /admin/user?keyword=`, read page by page until exhausted, exact match. The subject and body never choose the account or the credit.
- **Lookup failure:** an admin API error, an unexpected response, or a search that runs past 5 pages leaves the message in `new/` for the next run. It is never rejected for that.
- **Rejected mail:** a spoofed sender, an unknown sender, or an address shared by several accounts goes to `rejected/` with a `.reason` file. Nothing from it is attached.
- **Accepted mail:** the message moves to `cur/`. Nothing is deleted, and nothing is sent from here.
- **Same pipeline as Intercom:** attachments go through the same sandbox as Intercom files, with `source=email` and submitter key `user:<id>`, so reuse matching sees both channels.
- **Transport is a separate H-DevOps change:** the MX/route for the address and delivery into the Maildir, via terraform/actions.

## The checks (each signal cites file + page/region/byte range + tool)

A signal about something found in the document (an ISRC, a title, a name, a dashboard number, a bad check digit) cites its page and region when the PDF text layer or the OCR has word boxes. A signal about something missing cites the whole document (`whole document, no match found`); a split-share sum cites its block.

A check that cannot run (a missing library, a file that doesn't decode, an unreadable annotation or font table, a failed exiftool) emits an **error** signal. An error is never a pass. A PDF longer than the pages that are read (20 with a text layer, 6 OCR'd for a scan) gets the error `pages_not_inspected`: the unread pages are never cleared.

| Id | Check | Severity |
|---|---|---|
| F1 | magic bytes vs declared type; polyglots; launch actions / embedded files in PDFs; pixel bounds | reject file (soft). Form JavaScript is **recorded only**: common in fillable split sheets, never executed. |
| F3a | AI-generator software, Stable Diffusion/ComfyUI chunks, IPTC/C2PA `trainedAlgorithmicMedia` | **hard** |
| F3a | editor software / XMP edit history **on a screenshot** | soft. Missing EXIF is normal and never a flag. |
| F3a | C2PA camera capture | positive |
| F3b | error-level analysis on key-field word boxes (JPEG); copy-move (photos only) | soft |
| F4a | online-editor producer | soft |
| F4a | key-field change in a later revision | soft |
| F4a | form fill-in after creation | info |
| F4b | key field in a font family used nowhere else on the page | soft |
| F4c | FreeText / filled box / unapplied redaction over a key field | **hard** |
| F4c | text layer vs OCR differences | info (pf-1, see calibration) |
| F4c | a PDF whose text layer matches the claim (claimed ISRC, title, or claimant name) where the rendered page (OCR of the first 4 pages) doesn't show that match: e.g. text under an opaque drawn box, which is not an annotation | info (`claim_text_not_rendered`): caps the verdict at PLAUSIBLE, so routine OCR noise never makes a forgery |
| F4d | page text changed after the last signature | **hard**. A stamp of ≤ 3 added words is soft. |
| F4d | signature validation that raised (pyHanko or trust-root failure) | error (`signature_validation_failed`, retried) |
| F4d | valid other-party signature | issuer. Only when pyHanko validates it **and** its chain is trusted against our explicit trust roots (`scripts/credit_verify/proof/trust_roots/`, none today), and the signer is not the claimant. A valid but untrusted or self-signed signature is info. pyHanko is not installed on node-8 today, so signatures are recorded as unvalidated and never become A3. |
| F2 | same file / near-identical image (pHash ≤ 2) / same text **and** entities from **another** account, when the name check ran and the document doesn't name the submitter (a stolen document, same track or another). One rule for the same track and for other tracks; one signal per other account, however many tracks it used the document for. | **hard** |
| F2 | the very same file (byte-identical), naming the submitter, listing their track and their role: co-writers sharing one split sheet, or one document covering several tracks (a multi-song split sheet, an EP producer agreement, an LOD) | positive (`shared_split_sheet` for the same track, `shared_multi_track_document` for another) |
| F2 | the identical file for a linked claim, naming the submitter but not listing their track (title or ISRC) or with coverage unknown: title matching is too unreliable to accuse a named party; review asks which track | soft (SUSPECT, for review) |
| F2 | separate copies (near-identical image, or the same text and entities) of the same public page, for a linked claim, naming the submitter under a **different** name than the other account and listing their track: co-writers each screenshotting one PRO or credits page | info (`shared_public_page`) |
| F2 | another account presented the same document or public page as the **same** credited name on the page, however each account spells its own name (or as a name the store doesn't know: an older store's row that was named): two accounts claiming one credited person. Earlier rows that named nobody (the Intercom/email shadow, or an uploader the document doesn't name) present no name. | soft (`reused_by_another_account`) |
| F2 | the same, where the other account's name was a verified identity and this one's is only self-declared | soft (`impersonation_suspected`) |
| F2 | the identical file for a linked claim where the name check could not run (no claimant names, or a kind it doesn't cover such as a distributor portal, DSP dashboard or DAW session), or whose role the document doesn't show: the content checks decide, the same for every uploader | info (`shared_document_claimant_undetermined` / `shared_document_role_undetermined`) |
| F2 | any other cross-account match: no claim linked yet (Intercom/email shadow), or an edited near-copy of a private document (never positive). A named claimant verdict never depends on upload order, with one documented exception: when two accounts present the same credited name (or an unknown name), the later one is held for review. An unnamed uploader verdict can: INCONSISTENT when uploaded before the owner, FORGED_LIKELY after. A document that cannot express the claimed role never proves it. A row with no track (Intercom/email shadow) is an unknown track, never another track. | soft (SUSPECT, for review) |
| F2 | same account re-upload | info |
| F2b | same template text with different entities across accounts (template family). Form headings ("Song Title", "Writer Name") are not counted as shared names. | info |
| F5a | ISRC of another recording, and none of the claimed track (even when the title matches: titles are not unique) | mismatch |
| F5a | ISRC / title of the claimed track | positive |
| F5a | bad ISWC / labelled UPC check digit | soft |
| F5b | claimant named / not named in a split sheet, contract, invoice or LOD; words that match the name but form no credited name on the page ("Ann Beta" across "Alpha, Ann, Beta, Bob") identify nobody | positive / mismatch / info (`claimant_named_unverified`, PLAUSIBLE ceiling) |
| F5b | claimant on a public page (PRO registration, catalog credits page such as Genius, Discogs, AllMusic, TIDAL, MusicBrainz), matched on whole words in any order (a PRO page's "ALPHA ANN" matches "Ann Alpha"; "Dean" never matches "Deanna"): named under a **verified identity** (`verified_names`: a trusted DSP identity link or a verified legal name) / named only under a self-declared name (profile name, aka, account full name) / not found. A public page proves who is credited, not who owns the account, and not naming the claimant is not a contradiction. | positive / info (`claimant_named_unverified`, PLAUSIBLE ceiling) / info (`claimant_not_found`) |
| F5b | per claimed role: claimant named on a split sheet, contract, invoice or LOD, but the document's role words ("Producer", "Produced by", "Mixed by", "Written by", "Mastering", ...) don't include the role family they claim; immersive mix/master and remastering compare as mix/master (checked on every upload; nothing when the document lists no role words, or when the claimed role is one the role words can't express, such as a performer, featured artist, assistant or A&R) | soft (`claimed_role_not_listed`) |
| F5b | per claimed role: the document's role words can't show it (no role words, a role they can't express, or an unlisted role on a PRO/catalog page); recorded on every upload | info (`claimed_role_not_expressible`): caps that role's verdict at PLAUSIBLE |
| F5c | single-song split shares that cannot add up | mismatch. Multi-song sheets are parsed per song. |
| F3c / F5e | portal identification | info |
| F3c / F5e | dashboard artist not on the track | soft |
| F3c / F5e | dashboard numbers above our lifetime streams: an artist-level view (Spotify for Artists Home/Audience, Apple Music for Artists Overview) against the artist's total, a song/track page against the track's | mismatch |
| F3c / F5e | dashboard view scope unknown, or our total missing | info (`dsp_number_scope_unknown`); not compared |
| F8 | reverse image search (T2/T3) | **deferred**: needs network. Ticket: credit-trust V2 (T06). |
| F9 | challenge-response identity code | **deferred**: needs a messaging channel. Ticket: credit-trust V2 (T06). |

**Verdict** (`verdict.py`, deterministic), one per claimed role (request): a role the document can't show gets PLAUSIBLE, a listed role its own verdict, an unlisted one SUSPECT; none demotes another. `request_ids[i]` belongs to `claimed_roles[i]`; lists that don't pair up give the error `claim_context_mismatch` (UNDETERMINED) and no verdict row, while the file's forensics are still stored.

| Verdict | When |
|---|---|
| FORGED_LIKELY | any hard signal, or a combination: an edit plus a content mismatch; a unique font plus a key-field edit; pasted pixels plus a mismatch; an edited screenshot plus a dashboard that doesn't fit |
| INCONSISTENT | a mismatch |
| SUSPECT | a soft signal |
| UNDETERMINED | a check could not run. An error is never a pass. |
| VERIFIED | clean, consistent, **names the claimant**, shows the claimed track and role, and an issuer signal (the A3 anchor) |
| GENUINE | clean, consistent, **names the claimant**, shows the claimed track and role, no issuer signal. Proofs are matched to the account, never to what the text claims: on a public page only a verified identity counts as named. |
| PLAUSIBLE | would be GENUINE or VERIFIED, but the claimant isn't shown to be named (the name check could not run: distributor or DSP screenshots, DAW sessions, no usable text, no claimant names; or a PRO/catalog page that doesn't name them under a verified identity), or the document's role words can't show the claimed role (e.g. vocals on a writers-only split sheet), or a PDF's claim match is only in its text layer and not on the rendered page (`claim_text_not_rendered`). Ranked between GENUINE and SUSPECT; **never an approval and never the A3 anchor**. |
| CLEAN_UNLINKED | no claim linked yet |

Until core C1b links a proof to a credit request, every channel runs with an empty claim context: content checks only extract entities, and clean files are CLEAN_UNLINKED.

## Sandbox

Each file is analysed by `python3 -m credit_verify.proof.analyze` in its own process. The parent reads the file and passes its bytes on stdin, so that process opens no host file and needs no network, credentials or database.

| Where | How |
|---|---|
| node-8 (root + systemd) | a transient unit (`systemd-run --wait --pipe`) running as an unprivileged transient user (`DynamicUser=yes`) with `ProtectHome=yes` (`/root`, `/home`, `/run/user` hidden), `PrivateNetwork=yes`, an empty capability set, `NoNewPrivileges`, `ProtectSystem=strict`, `PrivateTmp`, `PrivateDevices`, `MemoryMax`, `CPUQuota`, `RuntimeMaxSec` and `TasksMax`; `/etc/openclaw`, `/etc/hydra` and `/opt/hydra/secrets` are inaccessible. Only the code dir is bind-mounted, read-only at `/tmp/code` (`/opt/hydra` is root-only). A parser exploit can read only world-readable host files. Checked on node-8: a socket connect fails (`Address family not supported`), and writes to `/etc` and `/var/lib` fail (`Read-only file system`). Run the test file as root on node-8 to exercise the unit live (`test_live_systemd_unit_cannot_read_root_only_or_home_files`; skipped elsewhere). |
| elsewhere (CI, laptops) | rlimits plus a scrubbed environment |

Override with `CREDIT_PROOF_SANDBOX=systemd|rlimit`.

Host tools in use on node-8: PyMuPDF, Pillow, OpenCV, numpy, tesseract (eng), poppler, heif-convert. exiftool is used when installed; it reads the file's bytes on stdin (the sandboxed parser never opens the host path), and a nonzero exit or empty answer is an `exiftool_failed` error. pyHanko is absent, so signatures are never validated.

**Follow-up:** re-judging earlier unnamed rows when a named owner uploads the same document is a verifier V2 follow-up.

## Calibration (90-day Intercom replay, 2026-10-15)

`credit-proof.py --store /tmp/… intercom --days 90 --max-files 5000` on node-8. Results and the calibration changes are in the PR body. In summary:
- the known `gpt-image 2.0` + C2PA "DistroKid" screenshots are caught as FORGED_LIKELY;
- form-script PDFs, HEIC metadata and text-layer-vs-OCR diffs were the noise sources, and were fixed.

## Running by hand

```bash
python3 /opt/hydra/scripts/credit-proof.py analyze /path/to/file.pdf --context ctx.json   # one file
sqlite3 /var/lib/hydra-credit-verify/proof.sqlite "select verdict, count(*) from verdicts group by 1"
```

Tests: `python3 scripts/tests/test_credit_proof.py` (CI py-tests). It builds synthetic forgeries in the test itself: an AI "dashboard" PNG, a split sheet edited after creation, an overlay, a post-signature edit, cross-account reuse, and spoofed email.
