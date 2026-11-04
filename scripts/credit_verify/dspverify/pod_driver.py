"""Fresh Spotify + Tidal capture driver. Runs INSIDE an industry-proc-catalog-admin pod (cwd /code),
sent as source text over `kubectl exec` by capture.py; it is never imported by hydra itself.

Built on the IDP's helpers.fresh_capture (IDP #1780), the path the Fable deciders used on
2026-10-27 (data/declined-review-prep-p3/scripts/drp_pod.py), unchanged in behaviour:

submit {items:[{key, tracks:[{track_id, profile_id}]}]}
    one request tag per item; every Spotify track / Tidal album capture of every track is enqueued
    ONCE at instant priority (the helper's enqueue_capture), INCLUDING sources where the person is
    not linked, so the read can show who the fresh capture credits (the helper's verdict stays
    UNKNOWN there).
read {items:[{key, request_id, requested_at, tracks:[{track_id, profile_id, roles, names}]}]}
    per track x role x source: the helper's verdict (_evaluate_source on receipts of THIS request
    captured after it) + the names the capture credits in that role family, each with whether it is
    the person's linked raw id, the unresolved names, whether a claimant name equals one of them,
    capture ids / captured_at, and snapshot completeness.

Never writes a credit; the only side effect is the capture itself (a raw refresh, like any capture).
"""
import json
import sys
from datetime import datetime, timezone

OUT_PREFIX = "DSP_CAPTURE_JSON="
COLLISION_SCAN_CAP = 2000   # phrase-search hits read per name; more than this = collisions unknown
WAIT_WINDOW_S = 5400        # a capture not back after 90 min is NO_FRESH_CAPTURE (d3: full window ~90 min)
NEEDED = ("resolve_track_plan", "enqueue_capture", "poll_receipts", "default_family_codes", "_evaluate_source",
          "_fresh", "_fold", "_ceil_ms", "REQUEST_TAG", "REQUESTED_AT_TAG", "_follow_merges", "CaptureTarget",
          "STATUS_OK")


def _connect(config, init_connect):
    import os
    try:
        init_connect.init(config.DB_CONNECT_STRING, config.DB_NAME)
        return
    except Exception as exc:  # noqa: BLE001
        if type(exc).__name__ != "InvalidURI":
            raise
    from mongoengine import connect
    init_connect.MongoSingleConnection.connection = connect(host=os.environ["MONGODB_URI"])


def fold_name(x):
    import re
    import unicodedata
    x = unicodedata.normalize("NFKD", x or "")
    x = "".join(ch for ch in x if not unicodedata.combining(ch))
    return " ".join(re.sub(r"[^0-9a-zA-Z]+", " ", x).lower().split())


def live_holder(holders, follow):
    """The ONE live catalog profile holding a raw DSP id, or None (self-merge-core-b1, 2026-10-30: Sissi's Tidal
    holder b55a327a was MERGED AWAY and the packet still named it). `holders`: every catalog profile document holding
    the raw id; `follow(pk)`: the surviving document after merges (fc._follow_merges), or None. A merged-away holder
    resolves to its survivor, a deleted one drops; two different survivors are ambiguous -> None (unknown identity:
    never a contradiction, never a merge candidate)."""
    alive = set()
    for h in holders:
        s = follow(str(getattr(h, "pk", "") or ""))
        if s is None or getattr(getattr(s, "deleted", None), "is_deleted", False):
            continue
        alive.add(str(s.pk))
    return next(iter(alive)) if len(alive) == 1 else None


def count_collisions(search, profile_id, name, cap=None):
    """Other live catalog profiles whose folded name equals `name`: the "$name" text index phrase
    search (`search(phrase, limit)` -> profile docs), then an exact folded compare; deleted and
    merged profiles skipped. None (unknown = common) when the name is empty, the read fails, or the
    search returns more than `cap` hits: a truncated scan is never a known zero (QA @c690573)."""
    cap = COLLISION_SCAN_CAP if cap is None else cap
    target = fold_name(name)
    if not target:
        return None
    try:
        hits = list(search('"' + (name or "").replace('"', " ") + '"', cap + 1))
    except Exception:  # noqa: BLE001 - unknown, which blocks approval
        return None
    if len(hits) > cap:
        return None
    n = 0
    for h in hits:
        if str(getattr(h, "pk", "")) == profile_id or fold_name(getattr(h, "name", "")) != target:
            continue
        if getattr(getattr(h, "deleted", None), "is_deleted", False):
            continue
        if getattr(getattr(h, "merged", None), "merged_to_id", None):
            continue
        n += 1
    return n


def idp_hold_ids():
    """The IDP credit-hold submitter ids as this pod sees them (processors/raw/muso_processor.py:
    IDP_CREDIT_HOLD_SUBMITTER_IDS unioned with IDP_CREDIT_HOLD_SUBMITTER_IDS_FILE), or None when this
    pod carries neither or the file is unreadable: UNKNOWN, which blocks any approval."""
    import os
    import re
    if "IDP_CREDIT_HOLD_SUBMITTER_IDS" not in os.environ and "IDP_CREDIT_HOLD_SUBMITTER_IDS_FILE" not in os.environ:
        return None
    raw = os.environ.get("IDP_CREDIT_HOLD_SUBMITTER_IDS", "")
    path = os.environ.get("IDP_CREDIT_HOLD_SUBMITTER_IDS_FILE")
    if path:
        try:
            with open(path, encoding="utf-8") as fh:
                raw += " " + fh.read()
        except (OSError, UnicodeDecodeError):
            return None
    return sorted({x for x in re.split(r"[\s,]+", raw) if x.strip().isdigit()})


def main(payload):
    import config
    import db.init_connect
    from helpers import fresh_capture as fc
    missing = [n for n in NEEDED if not hasattr(fc, n)]
    if missing:
        print(f"DSP_CAPTURE_API_MISMATCH missing={','.join(missing)}", file=sys.stderr)
        sys.exit(3)
    from db.collections.catalog.profile import CatalogProfile
    from db.collections.catalog.track import CatalogTrack
    from db.collections.raw.profile import RawProfile
    from db.collections.raw.recording import RawRecording
    from db.collections.raw.release import RawRelease
    _connect(config, db.init_connect)

    def targets_for(track_id):
        """source -> {recording_id: [CaptureTarget]} regardless of the person link."""
        tr = fc._follow_merges(CatalogTrack, track_id)
        if tr is None:
            return None
        out = {}
        for src in ("spotify", "tidal"):
            recs = {}
            for rid in sorted({r for r in tr.raw_recording_ids or [] if r.startswith(src + ":")}):
                if src == "tidal":
                    raw = RawRecording.objects(_id=rid).only("release_ids").first()
                    albums = sorted({r for r in (raw.release_ids if raw else None) or [] if r.startswith("tidal:")})
                    recs[rid] = [fc.CaptureTarget(src, "album", a.split(":", 1)[1]) for a in albums]
                else:
                    recs[rid] = [fc.CaptureTarget(src, "track", rid.split(":", 1)[1])]
            out[src] = recs
        return out

    mode, items = payload["mode"], payload["items"]
    out = []
    if mode == "submit":
        import uuid
        for it in items:
            row = {"key": it["key"], "tracks": {}}
            try:
                request_id = uuid.uuid4().hex
                requested_at = fc._ceil_ms(datetime.now(timezone.utc))
                extra = {fc.REQUEST_TAG: request_id, fc.REQUESTED_AT_TAG: requested_at.isoformat()}
                seen, failed = set(), []
                for t in it["tracks"]:
                    tg = targets_for(t["track_id"])
                    tkey = f"{t['track_id']}|{t['profile_id']}"
                    if tg is None:
                        row["tracks"][tkey] = {"error": "catalog_track_not_found"}
                        continue
                    row["tracks"][tkey] = {s: sorted(r) for s, r in tg.items()}
                    for recs in tg.values():
                        for ts in recs.values():
                            for x in ts:
                                if x.raw_entity_id in seen:
                                    continue
                                seen.add(x.raw_entity_id)
                                try:
                                    fc.enqueue_capture(x, extra)
                                except Exception as exc:  # noqa: BLE001 - one failed enqueue reads UNKNOWN
                                    failed.append(f"{x.raw_entity_id}:{type(exc).__name__}")
                row.update(request_id=request_id, requested_at=requested_at.isoformat(), targets=len(seen),
                           enqueue_failed=failed)
            except Exception as exc:  # noqa: BLE001
                row["error"] = f"{type(exc).__name__}: {exc}"[:300]
            out.append(row)
    elif mode == "read":
        now = datetime.now(timezone.utc)
        idp_hold = idp_hold_ids()
        pname = {}

        pcat = {}

        def catalog_of(pid):
            """The LIVE catalog profile holding this raw profile id (identity across DSPs), followed through
            merges (live_holder), or None."""
            if pid not in pcat:
                try:
                    pcat[pid] = live_holder(list(CatalogProfile.objects(raw_profile_ids=pid).only("id")),
                                            lambda pk: fc._follow_merges(CatalogProfile, pk))
                except Exception:  # noqa: BLE001 - unknown identity, never a contradiction
                    pcat[pid] = None
            return pcat[pid]

        ncache = {}

        def name_collisions(profile_id, name):
            key = (profile_id, name)
            if key not in ncache:
                ncache[key] = count_collisions(
                    lambda phrase, limit: CatalogProfile.objects.search_text(phrase).only(
                        "name", "deleted", "merged")[:limit], profile_id, name)
            return ncache[key]

        def recording_facts(tg):
            """Server-read facts for the anchor record: per DSP recording its ISRC, and per release
            its ℗/© lines (+ a label string when the raw release carries one). Catalog reads at
            read time, NOT same-run captures: the record says so (label_lines_fresh false)."""
            out = {"isrcs": [], "label_lines": [], "read_at": datetime.now(timezone.utc).isoformat(),
                   "label_lines_fresh": False}
            try:
                for src, recs in tg.items():
                    for rid in recs:
                        raw = RawRecording.objects(_id=rid).only("isrc", "release_ids").first()
                        if raw is None:
                            continue
                        if raw.isrc:
                            out["isrcs"].append({"source": src, "recording_id": rid, "isrc": raw.isrc.upper()})
                        for rel_id in sorted(raw.release_ids or [])[:6]:
                            rel = RawRelease.objects(_id=rel_id).only("copyrights", "custom_data", "title").first()
                            if rel is None:
                                continue
                            for c in rel.copyrights or []:
                                if getattr(c, "name", None):
                                    out["label_lines"].append({"source": src, "release_id": rel_id,
                                                               "kind": f"copyright_{(c.type or '').lower() or 'x'}",
                                                               "string": c.name[:200]})
                            lab = (rel.custom_data or {}).get("label")
                            if isinstance(lab, str) and lab.strip():
                                out["label_lines"].append({"source": src, "release_id": rel_id, "kind": "label",
                                                           "string": lab.strip()[:200]})
            except Exception as exc:  # noqa: BLE001 - unknown, recorded; never an anchor
                out["error"] = f"{type(exc).__name__}: {exc}"[:200]
            return out

        def name_of(pid):
            if pid not in pname:
                p = RawProfile.objects(_id=pid).only("name").first()
                pname[pid] = getattr(p, "name", None)
            return pname[pid]

        for it in items:
            row = {"key": it["key"], "request_id": it["request_id"], "tracks": {}}
            try:
                requested_at = datetime.fromisoformat(it["requested_at"])
                for t in it["tracks"]:
                    tr = {"roles": {}}
                    tg = targets_for(t["track_id"]) or {}
                    tids = sorted({x.raw_entity_id for recs in tg.values() for ts in recs.values() for x in ts})
                    rec_all = fc._fresh(fc.poll_receipts(it["request_id"], tids), it["request_id"],
                                        requested_at) if tids else []
                    plan = fc.resolve_track_plan(t["track_id"], t["profile_id"], ("spotify", "tidal"))
                    names = {fc._fold(n) for n in t.get("names") or [] if n}
                    if plan.person_name:
                        names.add(fc._fold(plan.person_name))
                    names.discard("")
                    tr["person_name"] = plan.person_name
                    tr["name_collisions"] = name_collisions(t["profile_id"], plan.person_name)
                    tr["recording_facts"] = recording_facts(tg)
                    for role in t["roles"]:
                        fam = {fc._fold(c) for c in fc.default_family_codes(role)} | {fc._fold(role)}
                        fam.discard("")
                        per = {}
                        for src in ("spotify", "tidal"):
                            sp = plan.sources.get(src)
                            o = fc._evaluate_source(sp, rec_all, set(), fam, plan.person_name) if sp else None
                            recs = tg.get(src) or {}
                            mine = [r for r in rec_all if r.raw_entity_id.startswith(src + ":")]
                            credited, unresolved, complete, seen_rec, err = [], [], False, False, False
                            for r in mine:
                                if r.status != fc.STATUS_OK:
                                    err = True
                                    continue
                                for rec in r.recordings:
                                    if rec.get("recording_id") not in recs:
                                        continue
                                    seen_rec = True
                                    complete = complete or rec.get("complete") is True
                                    for p in rec.get("credits") or []:
                                        if len(p) >= 2 and fc._fold(p[1]) in fam:
                                            mine_id = p[0] in (sp.person_raw_ids if sp else ())
                                            # The claimant's own linked holder carries the REQUEST's profile id:
                                            # core's anchor route matches the claimant on (linked, profile_id ==
                                            # request.profileId) (core #11010 claimantMatch); a None there could
                                            # never match.
                                            credited.append([name_of(p[0]), p[1], mine_id, p[0],
                                                             t["profile_id"] if mine_id else catalog_of(p[0])])
                                    for u in rec.get("unresolved") or []:
                                        if fc._fold(u.get("normalized_credit")) in fam or fc._fold(u.get("credit")) in fam:
                                            unresolved.append([u.get("contributor_name"), u.get("credit")])
                            nm = any(fc._fold(c[0]) in names for c in credited) or \
                                any(fc._fold(c[0]) in names for c in unresolved)
                            if not recs:
                                state = "NO_RECORDING"
                            elif not mine:
                                state = "WAITING" if (now - requested_at).total_seconds() < WAIT_WINDOW_S \
                                    else "NO_FRESH_CAPTURE"
                            elif not seen_rec:
                                state = "CAPTURE_ERROR" if err else "RECORDING_ABSENT"
                            else:
                                state = "CAPTURED"
                            per[src] = {"state": state,
                                        "helper_verdict": (o.verdict or "WAITING") if o else None,
                                        "helper_reason": o.reason if o else None,
                                        # Complete, de-duplicated (one row per contributor id + credit): the
                                        # rules decide on the full set, never a display slice (QA @ba10b8e).
                                        "credited_in_family": [list(x) for x in dict.fromkeys(
                                            tuple(c) for c in credited)],
                                        "credited_total": len({c[3] for c in credited}),
                                        "unresolved_in_family": unresolved[:25],
                                        "claimant_name_match": nm, "complete_snapshot": complete,
                                        "capture_ids": sorted({r.capture_id for r in mine})[:6],
                                        "captured_at": max([r.captured_at for r in mine]).isoformat() if mine else None,
                                        "recordings": sorted(recs)[:4]}
                        tr["roles"][role] = {"sources": per}
                    # Keyed by track AND profile: one user can claim one track on two profiles, and each
                    # profile's linked ids decide its own reading (QA @dfe29fd).
                    row["tracks"][f"{t['track_id']}|{t['profile_id']}"] = tr
                row["idp_hold_ids"] = idp_hold
                row["age_s"] = (now - requested_at).total_seconds()
            except Exception as exc:  # noqa: BLE001
                row["error"] = f"{type(exc).__name__}: {exc}"[:300]
            out.append(row)
    return {"mode": mode, "at": datetime.now(timezone.utc).isoformat(), "items": out}


if __name__ == "__main__":       # local smoke only; capture.py exec()s the source and calls main()
    print(OUT_PREFIX + json.dumps(main(json.load(sys.stdin)), default=str))
