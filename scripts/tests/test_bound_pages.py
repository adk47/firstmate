"""claim_verify.bound_pages: the one Python statement of a claim's bound pages (core claimProofChallenge.surfacesFor)."""
from __future__ import annotations

import io
import json
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from claim_verify import bound_pages as bp  # noqa: E402
from credit_review import claim_status_list as csl  # noqa: E402


class BoundPagesTests(unittest.TestCase):
    def test_every_bound_kind_core_builds(self):
        prof = {"id": "p", "links": {"website": "https://www.Label.com/about", "instagram": "instagram.com/@Artist.",
                                     "youtube": "https://youtube.com/channel/UC1234567890ab"},
                "rawProfiles": [{"source": "spotify", "id": "0123456789abcdefABCDEF"}, {"source": "youtube_music", "id": "MPAD1"},
                                {"source": "spotify", "id": "too-short"}]}
        self.assertEqual(bp.bound_surfaces(prof), sorted([
            "well_known:label.com", "dns_txt:label.com", "meta_tag:label.com", "instagram_bio:artist",
            "youtube_description:UC1234567890ab", "spotify_bio:0123456789abcdefABCDEF", "youtube_description:MPAD1"]))
        self.assertTrue(bp.has_bound_page(prof))

    def test_x_and_tiktok_are_never_bound_and_junk_links_bind_nothing(self):
        prof = {"links": {"x": "https://x.com/artist", "tiktok": "https://tiktok.com/@artist",
                          "website": "ftp://files.label.com/", "instagram": "https://instagram.com/p/abc"}}
        self.assertEqual(bp.bound_surfaces(prof), [])
        self.assertFalse(bp.has_bound_page(prof))
        self.assertEqual(bp.x_handle("https://twitter.com/Artist"), "artist")      # parsers kept for claim-only links
        self.assertEqual(bp.tiktok_handle("https://www.tiktok.com/@a.b."), "a.b")

    def test_claim_status_list_reads_the_same_statement(self):
        self.assertIs(csl.bound_surfaces, bp.bound_surfaces)
        self.assertIs(csl.registrable_host, bp.registrable_host)

    def test_cli_prints_the_bound_surfaces_of_a_profile(self):
        out = io.StringIO()
        rc = bp.main(io.StringIO(json.dumps({"data": {"id": "p1", "links": {"website": "site.org"}}})), out)
        self.assertEqual(rc, 0)
        self.assertEqual(json.loads(out.getvalue()), {"id": "p1", "bound": ["dns_txt:site.org", "meta_tag:site.org", "well_known:site.org"]})
        self.assertEqual(bp.main(io.StringIO("[]"), io.StringIO()), 2)


if __name__ == "__main__":
    unittest.main()
