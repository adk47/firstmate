#!/usr/bin/env python3
"""The decision notice's credit list, in bytes, against send-gateway's body limit (credit_review/notice_size.py).

Three approval notices (281, 281 and 364 credits) were refused with 413 on 2026-11-10 and 11. The limit is in
muso-messaging (services/send-gateway/src/http.js `readBody`, 64 KiB by default) and the fix lands there; this
repository carries the measurement and holds the proposed bound to it.

What is real and what is not: MEASURED is the byte count of each real group's list, read on node-8 on
2026-11-14T21:42Z (data/precedent-untold-tell-r1/evidence/notice_bytes.out). No customer row is in this file, so
the 364-credit notice built here is synthetic: 364 distinct tracks, each item padded to the largest item measured
in any of those groups. It is larger than every real notice measured, on purpose.
"""
from __future__ import annotations

import json
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from credit_review import notice_size as ns  # noqa: E402

# (credits in the notice, items after core's dedupe, bytes of creditDetails, what the ledger holds for the send)
MEASURED = [
    (195, 191, 63_511, "sent"),
    (242, 238, 77_682, "timeout, core stamp"),
    (281, 281, 92_556, "413"),
    (281, 225, 127_876, "413"),
    (364, 364, 149_530, "413"),
]
LARGEST_ITEM_BYTES = 806  # the largest single creditDetails item in the groups above


def row(n: int, *, item_bytes: int = 0, track: str | None = "", roles=("Producer",)) -> dict:
    """One credit request row. `item_bytes` pads the title until the item is exactly that many bytes."""
    r = {"id": f"00000000-0000-4000-8000-{n:012d}", "spotify_track_id": f"{n:022d}" if track == "" else track,
         "title": "T", "artists": [{"id": f"{n:022d}", "name": "Artist"}], "roles": list(roles),
         "image_url": "https://i.scdn.co/image/" + "a" * 40}
    if item_bytes:
        r["title"] = "T" * (1 + item_bytes - ns.json_bytes(ns.credit_details([r])[0]))
    return r


class CoreShape(unittest.TestCase):
    def test_an_item_carries_cores_fields_in_cores_order(self):
        item = ns.credit_details([row(1)])[0]
        self.assertEqual(list(item), ["trackName", "spotifyTrackId", "requestId", "artists", "roles", "imageUrl"])

    def test_a_track_submitted_twice_is_listed_once(self):
        items = ns.credit_details([row(1, track="same"), row(2, track="same"), row(3)])
        self.assertEqual([i["requestId"][-1] for i in items], ["1", "3"])

    def test_rows_with_no_track_id_are_each_listed(self):
        items = ns.credit_details([row(1, track=None), row(2, track=None)])
        self.assertEqual([(i["spotifyTrackId"], i["requestId"][-1]) for i in items], [(None, "1"), (None, "2")])

    def test_artists_that_are_not_a_list_become_an_empty_list(self):
        r = row(1)
        r["artists"] = None
        self.assertEqual(ns.credit_details([r])[0]["artists"], [])

    def test_the_track_id_stands_in_for_a_missing_title(self):
        r = row(1, track="abc")
        r["title"] = ""
        self.assertEqual(ns.credit_details([r])[0]["trackName"], "abc")


class Bytes(unittest.TestCase):
    def test_bytes_are_compact_json(self):
        self.assertEqual(ns.json_bytes([{"a": 1, "b": [1, 2]}]), len('[{"a":1,"b":[1,2]}]'))

    def test_a_non_ascii_title_counts_its_utf8_bytes(self):
        self.assertEqual(ns.json_bytes("é") - ns.json_bytes("e"), 1)

    def test_measure_returns_counts_and_bytes_only(self):
        m = ns.measure([row(1), row(2, track=f"{1:022d}")])
        self.assertEqual((m["requests"], m["items"]), (2, 1))
        self.assertEqual(set(m), {"requests", "items", "bytes", "largest_item_bytes"})
        self.assertEqual(m["bytes"], len(json.dumps(ns.credit_details([row(1)]), separators=(",", ":"))))


class PgArray(unittest.TestCase):
    def test_the_replicas_text_array_is_split_into_roles(self):
        self.assertEqual(ns.pg_text_array('{Producer,"Recording Engineer",Writer}'),
                         ["Producer", "Recording Engineer", "Writer"])

    def test_an_empty_array_is_no_roles(self):
        self.assertEqual((ns.pg_text_array("{}"), ns.pg_text_array("")), ([], []))

    def test_a_quoted_comma_and_an_escaped_quote_stay_inside_one_role(self):
        self.assertEqual(ns.pg_text_array('{"a, b","c\\"d"}'), ["a, b", 'c"d'])


class GatewayLimit(unittest.TestCase):
    def test_a_364_credit_notice_at_the_largest_measured_item_fits_the_proposed_limit(self):
        m = ns.measure([row(n, item_bytes=LARGEST_ITEM_BYTES) for n in range(364)])
        self.assertEqual((m["items"], m["largest_item_bytes"]), (364, LARGEST_ITEM_BYTES))
        self.assertEqual(m["bytes"], 364 * LARGEST_ITEM_BYTES + 363 + 2)  # items, the commas between, the brackets
        self.assertLess(m["bytes"], ns.PROPOSED_LIMIT_BYTES)

    def test_the_same_notice_does_not_fit_todays_limit(self):
        m = ns.measure([row(n, item_bytes=LARGEST_ITEM_BYTES) for n in range(364)])
        self.assertGreater(m["bytes"], ns.GATEWAY_LIMIT_BYTES)

    def test_every_measured_notice_fits_the_proposed_limit_three_times_over(self):
        for credits, _items, size, _was in MEASURED:
            with self.subTest(credits=credits, bytes=size):
                self.assertLessEqual(3 * size, ns.PROPOSED_LIMIT_BYTES)

    def test_the_three_refused_notices_are_over_todays_limit_by_their_list_alone(self):
        refused = [size for _c, _i, size, was in MEASURED if was == "413"]
        self.assertEqual(len(refused), 3)
        self.assertTrue(all(size > ns.GATEWAY_LIMIT_BYTES for size in refused))

    def test_the_largest_confirmed_notice_is_under_todays_limit(self):
        self.assertEqual([size < ns.GATEWAY_LIMIT_BYTES for _c, _i, size, was in MEASURED if was == "sent"], [True])

    def test_the_proposed_limit_is_a_bound(self):
        self.assertEqual((ns.GATEWAY_LIMIT_BYTES, ns.PROPOSED_LIMIT_BYTES), (64 * 1024, 512 * 1024))


if __name__ == "__main__":
    unittest.main()
