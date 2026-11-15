"""The size of the list core's decision notice carries, measured in bytes.

Hydra sends no notice body: `decision_told` posts {userId, copyRef, channel, subjectIds, apply} and core builds the
email's data. That data lists every credit of the group (core-backend
src/services/credit-requests/decisionNoticeData.js, `buildCreditNoticeData`: one `creditDetails` item per Spotify
track), and core posts it to send-gateway's send route, whose body reader stops at 64 KiB (muso-messaging
services/send-gateway/src/http.js, `readBody(req, limit = 64 * 1024)`) and answers 413. On 2026-11-10 and 11 three
approval notices of 281, 281 and 364 credits were refused that way.

This module sends nothing and calls nothing. The route's path is spelled out in
data/precedent-untold-tell-r1/report.md section 10 and not here: scripts/check-outbound-copy-gate.py reads that
literal as a customer send.

This module rebuilds `creditDetails` from the replica's columns so the size can be measured where the rows are
(data/precedent-untold-tell-r1/tools/notice_bytes.py) and so a test can hold a proposed limit to a real number. It
is a copy of core's shape, not core's code: when `buildCreditNoticeData` changes, this changes with it. It measures
the list only. The rest of the body (template key, address, profile, person, idempotency key) is not measured here.
"""
from __future__ import annotations

import json
from typing import Any, Iterable

GATEWAY_LIMIT_BYTES = 64 * 1024  # send-gateway's default body limit, the one its send route reads with today
PROPOSED_LIMIT_BYTES = 512 * 1024  # the bound proposed for that route (the gateway already reads another route at it)


def pg_text_array(text: str) -> list[str]:
    """A Postgres text[] as the replica renders it (`{a,"b c",d}`) -> its elements. Anything else is one element."""
    text = (text or "").strip()
    if not (text.startswith("{") and text.endswith("}")):
        return [text] if text else []
    out, cur, quoted, was_quoted, i, body = [], [], False, False, 0, text[1:-1]
    while i < len(body):
        ch = body[i]
        if quoted and ch == "\\" and i + 1 < len(body):
            cur.append(body[i + 1])
            i += 1
        elif ch == '"':
            quoted, was_quoted = not quoted, True
        elif ch == "," and not quoted:
            out.append("".join(cur))
            cur, was_quoted = [], False
        else:
            cur.append(ch)
        i += 1
    if cur or was_quoted or out:
        out.append("".join(cur))
    return out


def credit_details(rows: Iterable[dict[str, Any]]) -> list[dict[str, Any]]:
    """core's `creditDetails` for one group: `dedupeBySpotifyTrackId`, then one item per kept row.

    A row is {id, spotify_track_id, title, artists, roles, image_url}; a missing track id or image is None."""
    seen, items = set(), []
    for r in rows:
        track = r.get("spotify_track_id") or None
        key = track or f"no-spotify-id:{r['id']}"
        if key in seen:
            continue
        seen.add(key)
        artists = r.get("artists")
        items.append({"trackName": r.get("title") or track, "spotifyTrackId": track,
                      "requestId": str(r["id"]) if r.get("id") else None,
                      "artists": artists if isinstance(artists, list) else [],
                      "roles": r.get("roles") or [], "imageUrl": r.get("image_url")})
    return items


def json_bytes(obj: Any) -> int:
    """Bytes of `obj` as JSON.stringify sends it: no spaces, non-ASCII as UTF-8."""
    return len(json.dumps(obj, separators=(",", ":"), ensure_ascii=False).encode("utf-8"))


def measure(rows: Iterable[dict[str, Any]]) -> dict[str, int]:
    """Counts and bytes of one group's list. No title, name or id is returned."""
    rows = list(rows)
    items = credit_details(rows)
    return {"requests": len(rows), "items": len(items), "bytes": json_bytes(items),
            "largest_item_bytes": max((json_bytes(i) for i in items), default=0)}
