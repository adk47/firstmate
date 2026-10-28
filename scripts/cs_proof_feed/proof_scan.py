#!/usr/bin/env python3
"""Proof-on-file scan (firstmate 714): find credit-proof material users sent us in Intercom.

Runs on node-8 from scripts/cs-proof-feed.sh (moved off the captain's Mac 2026-10-26,
ops-to-ovh-m1; originally cs-systemic-issues-lane-c1 scripts/cs-systemic/proof-scan.py,
logic unchanged except: a read that fails after every retry now fails the run
(ScanIncomplete, exit 3) instead of silently skipping the conversation, and the body is in main()).

READ-ONLY. Walks Intercom conversations month by month, newest first, and records every
user/lead part that carries an attachment or a link to a proof-type site, in a
credit-related conversation (over-includes when unsure).

Output (ids only, no message text, no file names): JSONL records
  {conv, part, created, contact, src, attach_types[], link_domains[], muso_tracks[],
   muso_profiles[], credit_ctx, human_reviewed}
written to OUT/intercom-proof.jsonl. A checkpoint (OUT/intercom-checkpoint.json) lists
completed months, so a rerun resumes. Mode --incremental HOURS rescans conversations
UPDATED in the last N hours (for the hourly pass), appending only parts not seen before.

Usage: MUSOAI_INTERCOM_TOKEN=... proof-scan.py OUT_DIR [--since-year 2021] [--incremental 2 [--resume-from STAMP]]
"""
import json, os, re, sys, time, calendar, urllib.request, urllib.error, concurrent.futures as cf

# Set by main(); module-level so the helpers below keep their original shape.
H, JSONL, CKPT, SEEN = {}, None, None, None


class ScanIncomplete(RuntimeError):
    """An Intercom read failed after every retry. Fatal for the run: the caller must not mark the
    Intercom part fresh, so consumers see it go stale instead of trusting a scan with a hole in it
    (QA #1391: a silently skipped conversation fell out of the 2 h incremental window for good)."""

PROOF_DOMAINS = re.compile(
    r"https?://(?:[\w-]+\.)*(tidal\.com|genius\.com|jaxsta\.com|discogs\.com|allmusic\.com|ascap\.com|bmi\.com|"
    r"sesac\.com|socan\.com|prsformusic\.com|gema\.de|sacem\.fr|themlc\.com|songview\.com|musicbrainz\.org|"
    r"credits\.muso\.ai|muso\.ai|open\.spotify\.com|music\.apple\.com|youtube\.com|youtu\.be|soundcloud\.com|"
    r"drive\.google\.com|docs\.google\.com|dropbox\.com|wetransfer\.com|we\.tl|box\.com|onedrive\.live\.com|"
    r"1drv\.ms|icloud\.com|instagram\.com|tiktok\.com|bandcamp\.com|deezer\.com|qobuz\.com|vevo\.com|"
    r"distrokid\.com|tunecore\.com|cdbaby\.com|songtrust\.com)", re.I)
CREDIT_CTX = re.compile(r"credit|proof|verif|songwriter|writer|producer|engineer|mix|master|composer|lyric|"
                        r"split|contract|session|claim|role|isrc|publish|feature|featured|cr[eé]dit|cr[eé]dito", re.I)
MUSO_TRACK = re.compile(r"muso\.ai/track/([0-9a-f-]{36})", re.I)
MUSO_PROF = re.compile(r"muso\.ai/profile/([0-9a-f-]{36})", re.I)
CAROLINE = "5763097"


def req(url, data=None):
    for i in range(8):
        try:
            return json.load(urllib.request.urlopen(urllib.request.Request(url, data=data, headers=H), timeout=60))
        except urllib.error.HTTPError as e:
            if e.code == 404:
                return None
            time.sleep(min(60, 3 * (i + 1)) if e.code == 429 else 2 * (i + 1))
        except Exception:
            time.sleep(2 * (i + 1))
    # Only a genuine 404 (conversation deleted) is a skip; exhaustion is a failed scan.
    raise ScanIncomplete(f"intercom read failed after retries: {url.split('?')[0]}")


def search_ids(field, lo, hi):
    ids, q = [], {"query": {"operator": "AND", "value": [{"field": field, "operator": ">", "value": lo},
                                                          {"field": field, "operator": "<", "value": hi}]},
                  "pagination": {"per_page": 150}}
    while True:
        r = req("https://api.intercom.io/conversations/search", json.dumps(q).encode())
        if not r:
            raise RuntimeError(f"search failed {field} {lo}-{hi}")
        ids += [c["id"] for c in r.get("conversations", [])]
        nx = (r.get("pages") or {}).get("next")
        if not nx or not nx.get("starting_after"):
            return ids
        q["pagination"]["starting_after"] = nx["starting_after"]


def strip(html):
    return re.sub(r"\s+", " ", re.sub(r"<[^>]+>", " ", html or ""))


def scan_conv(cid):
    d = req(f"https://api.intercom.io/conversations/{cid}")
    if not d:
        return None, []
    parts = [d.get("source") or {}] + (d.get("conversation_parts") or {}).get("conversation_parts", [])
    alltext = " ".join(strip(p.get("body")) for p in parts)
    credit_ctx = bool(CREDIT_CTX.search(alltext))
    human = any((p.get("author") or {}).get("type") == "admin" and str((p.get("author") or {}).get("id")) != CAROLINE
                and p.get("part_type") != "note" and p.get("body") for p in parts)
    contact = ((d.get("contacts") or {}).get("contacts") or [{}])[0].get("id")
    recs = []
    for i, p in enumerate(parts):
        a = p.get("author") or {}
        if a.get("type") not in ("user", "lead", "contact"):
            continue
        body = p.get("body") or ""
        atts = p.get("attachments") or []
        links = sorted({m.group(1).lower() for m in PROOF_DOMAINS.finditer(body)})
        if not atts and not links:
            continue
        if not credit_ctx and not atts and not (set(links) & {"credits.muso.ai", "muso.ai"}):
            # a bare streaming/social link in a non-credit conversation: still over-include if credit-ish domain
            if not (set(links) & {"tidal.com", "genius.com", "jaxsta.com", "discogs.com", "allmusic.com", "ascap.com",
                                  "bmi.com", "sesac.com", "socan.com", "prsformusic.com", "themlc.com", "songview.com"}):
                continue
        recs.append({
            "conv": str(d.get("id")), "part": str(p.get("id") or f"source-{d.get('id')}"),
            "created": p.get("created_at") or d.get("created_at"), "contact": contact,
            "src": (d.get("source") or {}).get("type"),
            "attach_types": sorted({(x.get("content_type") or "?") for x in atts}),
            "link_domains": links, "muso_tracks": sorted(set(MUSO_TRACK.findall(body))),
            "muso_profiles": sorted(set(MUSO_PROF.findall(body))), "credit_ctx": credit_ctx, "human_reviewed": human,
        })
    return d, recs


def load_seen():
    return set(open(SEEN).read().split()) if os.path.exists(SEEN) else set()


def run(ids, seen, label):
    n_new = 0
    with cf.ThreadPoolExecutor(8) as ex, open(JSONL, "a") as out, open(SEEN, "a") as sf:
        for _, recs in ex.map(scan_conv, ids):
            for r in recs:
                if r["part"] in seen:
                    continue
                seen.add(r["part"]); out.write(json.dumps(r) + "\n"); sf.write(r["part"] + "\n"); n_new += 1
            out.flush(); sf.flush()
    print(f"{time.strftime('%H:%M:%SZ', time.gmtime())} {label}: convs {len(ids)} new proof parts {n_new}", flush=True)


MAX_RESUME_H = 24 * 30  # beyond 30 days of outage, re-run the full pass (`proof_scan.py OUT` without --incremental)


def resume_hours(min_h, stamp_path, now_epoch, overlap_h=1.0):
    """The incremental window: at least min_h, and always back to the last SUCCESSFUL scan plus an
    overlap (QA #1391: a fixed 2 h window lost every conversation updated during a longer outage, and
    the next successful run marked the part fresh without them). A missing or unreadable stamp means we
    cannot prove where we left off, so the window is the 30-day cap, never the 2 h default."""
    try:
        last = calendar.timegm(time.strptime(open(stamp_path).read().strip(), "%Y-%m-%dT%H:%M:%SZ"))
        age_h = max(0.0, (now_epoch - last) / 3600)
    except (OSError, ValueError):
        return float(MAX_RESUME_H)
    return min(float(MAX_RESUME_H), max(float(min_h), age_h + overlap_h))


def main(argv):
    global H, JSONL, CKPT, SEEN
    out = argv[1]
    os.makedirs(out, exist_ok=True)
    H = {"Authorization": "Bearer " + os.environ["MUSOAI_INTERCOM_TOKEN"], "Intercom-Version": "2.11",
         "Accept": "application/json", "Content-Type": "application/json"}
    since_year = int(argv[argv.index("--since-year") + 1]) if "--since-year" in argv else 2021
    incr = float(argv[argv.index("--incremental") + 1]) if "--incremental" in argv else None
    capped = False
    if incr and "--resume-from" in argv:
        incr = resume_hours(incr, argv[argv.index("--resume-from") + 1], time.time())
        capped = incr >= MAX_RESUME_H
    JSONL = os.path.join(out, "intercom-proof.jsonl")
    CKPT = os.path.join(out, "intercom-checkpoint.json")
    SEEN = os.path.join(out, "intercom-seen-parts.txt")

    seen = load_seen()
    if incr:
        now = int(time.time())
        run(search_ids("updated_at", now - int(incr * 3600), now + 60), seen, f"incremental {incr}h")
        if capped:
            # QA #1391: the window hit the cap (or no stamp says where we left off), so it may not
            # cover the whole gap. What was found is kept, but the run is NOT complete: exit 5, the
            # wrapper does not advance freshness, and the part goes stale until a full pass
            # (`proof_scan.py OUT` without --incremental) closes the gap.
            print(f"WINDOW CAPPED at {MAX_RESUME_H} h: gap not provably covered; run a full pass", file=sys.stderr, flush=True)
            return 5
        return 0

    done = set(json.load(open(CKPT))) if os.path.exists(CKPT) else set()
    now = time.gmtime()
    months = [(y, m) for y in range(now.tm_year, since_year - 1, -1) for m in range(12, 0, -1)
              if (y, m) <= (now.tm_year, now.tm_mon)]
    for y, m in months:
        key = f"{y}-{m:02d}"
        if key in done:
            continue
        lo = calendar.timegm((y, m, 1, 0, 0, 0)) - 1
        hi = calendar.timegm((y + (m == 12), 1 if m == 12 else m + 1, 1, 0, 0, 0))
        run(search_ids("created_at", lo, hi), seen, key)
        done.add(key)
        json.dump(sorted(done), open(CKPT, "w"))
    print("FULL PASS COMPLETE", flush=True)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv))
    except ScanIncomplete as e:
        print(f"SCAN INCOMPLETE: {e}; intercom part not marked fresh", file=sys.stderr, flush=True)
        sys.exit(3)
