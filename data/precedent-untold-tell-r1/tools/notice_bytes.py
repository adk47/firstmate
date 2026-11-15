"""Bytes of the decision notice's credit list for the largest attempted groups, measured on node-8.

Reads the attempted subject ids from the ledger (read-only) and the rows core's builder reads from the replica,
then measures `creditDetails` with scripts/credit_review/notice_size.py (the copy of core's shape).
Prints counts and byte totals only: no title, name or request id leaves the host.

Run with the directory that holds notice_size.py as argv[1].
"""
import json
import sqlite3
import sys

sys.path.insert(0, sys.argv[1])
sys.path.insert(1, "/opt/hydra/scripts")
import notice_size as ns  # noqa: E402
from credit_review.core_notice import trino  # noqa: E402

# user -> what the ledger holds for the live attempt
USERS = {1333: "sent", 61448: "sent", 360296: "sent", 334868: "sent",
         275342: "timeout, core stamp", 50621: "413", 72407: "413", 17097: "413"}
db = sqlite3.connect("file:/var/lib/hydra/credit-review/ledger.sqlite3?mode=ro", uri=True, timeout=30)
subjects = {}
for uid in USERS:
    row = db.execute("SELECT subject_ids_json FROM decision_told WHERE mode='apply' AND outcome='attempt' AND "
                     "user_id=? ORDER BY id LIMIT 1", (uid,)).fetchone()
    subjects[uid] = set(json.loads(row[0]))
rows = trino(
    "SELECT lower(CAST(id AS varchar)), CAST(userid AS varchar), coalesce(spotifytrackid, ''), "
    "coalesce(spotifytracktitle, ''), coalesce(json_format(spotifytrackartists), 'null'), coalesce(credits, ''), "
    "coalesce(spotifytrackimageurl, ''), CAST(spotifytrackimageurl IS NULL AS varchar) "
    "FROM postgresql_core.public.credit_requests WHERE userid IN (" + ",".join(map(str, USERS)) + ") "
    "AND deletedat IS NULL AND json_extract_scalar(metadata, '$.approval.via') = 'precedent_v1' ORDER BY 1")

out = []
for uid, was in USERS.items():
    mine, bad_artists = [], 0
    for rid, user, track, title, artists, credits, image, no_image in rows:
        if int(user) != uid or rid not in subjects[uid]:
            continue
        try:
            art = json.loads(artists)
        except ValueError:
            art, bad_artists = None, bad_artists + 1
        mine.append({"id": rid, "spotify_track_id": track or None, "title": title, "artists": art,
                     "roles": ns.pg_text_array(credits), "image_url": None if no_image == "true" else image})
    m = ns.measure(mine)
    out.append({"user": uid, "ledger": was, "attempted_subjects": len(subjects[uid]), "rows_read": m["requests"],
                "items_after_dedupe": m["items"], "creditDetails_bytes": m["bytes"],
                "bytes_per_item": round(m["bytes"] / max(1, m["items"]), 1),
                "largest_item_bytes": m["largest_item_bytes"], "artists_unparsed": bad_artists,
                "over_gateway_limit": m["bytes"] > ns.GATEWAY_LIMIT_BYTES,
                "under_proposed_limit": m["bytes"] < ns.PROPOSED_LIMIT_BYTES})
print(json.dumps({"gateway_limit_bytes": ns.GATEWAY_LIMIT_BYTES, "proposed_limit_bytes": ns.PROPOSED_LIMIT_BYTES,
                  "groups": out}, indent=1))
