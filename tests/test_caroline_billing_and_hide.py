"""policies/caroline-billing-and-hide.json, pinned against the code it describes.

The file says what Caroline does with a billing ask and with a hide / remove ask: ANSWER from a named read, ACT with
a named write that has an undo, or FENCE. A list like that is only worth having while it is true, so every claim in it
that code can check is checked here:

  - every tool it names exists in the support-tools plugin, is in Caroline's capability list, and is NOT on the edge
    agent's deny list (a shape "answered" by a tool she cannot call is a hand-off nobody wrote down);
  - an ACTION names one of the two writes she holds, neither moves money, and each states its undo;
  - a FENCE has no write, a real hand-off queue, and a reason;
  - the refund rule has a cap, a ceiling per customer and an owner above the cap - and Caroline is not the decider;
  - Caroline's plugin carries no refund, delete or hide write at all;
  - the measured ticket counts add up to the totals they were read from;
  - the doc names every shape, so the prose and the policy cannot drift apart.

Stdlib unittest. Run: python3 -m unittest -v tests.test_caroline_billing_and_hide
"""
import json
import os
import re
import unittest

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
POLICY = os.path.join(ROOT, "policies", "caroline-billing-and-hide.json")
DOC = os.path.join(ROOT, "docs", "support", "caroline-billing-and-hide.md")
TOOLS_DIR = os.path.join(ROOT, "plugins", "support-tools", "src", "tools")
CAPS = os.path.join(ROOT, "plugins", "intercom", "src", "caroline-tool-capabilities.json")
EDGE = os.path.join(ROOT, "openclaw-edge.json")

HANDOFFS = ("billing-issue", "subscription-refund")
MODES = ("answer", "action", "fence")


def _read(path):
    with open(path, encoding="utf-8") as fh:
        return fh.read()


def _tool_sources():
    return {n: _read(os.path.join(TOOLS_DIR, n)) for n in sorted(os.listdir(TOOLS_DIR)) if n.endswith(".ts")}


def registered_tools():
    names = set()
    for text in _tool_sources().values():
        names.update(re.findall(r'^\s*name:\s*"([a-z_]+)",\s*$', text, re.M))
    return names


def edge_deny():
    cfg = json.loads(_read(EDGE))
    agents = cfg["agents"]["list"]
    assert len(agents) == 1, "the edge profile is expected to run exactly one agent (Caroline)"
    return set(agents[0]["tools"]["deny"])


class Policy(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.p = json.loads(_read(POLICY))
        cls.shapes = cls.p["billing_shapes"]
        cls.registered = registered_tools()
        cls.caps = {t["name"] for t in json.loads(_read(CAPS))["tools"]}
        cls.deny = edge_deny()

    def callable_by_caroline(self, tool):
        self.assertIn(tool, self.registered, f"{tool} is not a support-tools tool")
        self.assertIn(tool, self.caps, f"{tool} is not in Caroline's capability list")
        self.assertNotIn(tool, self.deny, f"{tool} is on the edge deny list: Caroline cannot call it")

    def test_every_shape_is_one_of_answer_action_fence_and_keys_are_unique(self):
        keys = [s["key"] for s in self.shapes]
        self.assertEqual(len(keys), len(set(keys)))
        for s in self.shapes:
            self.assertIn(s["mode"], MODES, s["key"])
            self.assertTrue(s["ask"].strip(), s["key"])

    def test_every_named_tool_is_one_caroline_can_actually_call(self):
        for s in self.shapes:
            for tool in s["read"] + ([s["write"]] if s["write"] else []):
                with self.subTest(shape=s["key"], tool=tool):
                    self.callable_by_caroline(tool)
        for tool in list(self.p["caroline_writes"]) + self.p["hide"]["intake"]:
            if tool != "_doc":
                self.callable_by_caroline(tool)

    def test_an_answer_names_its_read_and_writes_nothing(self):
        for s in (x for x in self.shapes if x["mode"] == "answer"):
            self.assertTrue(s["read"], f"{s['key']}: an answer with no read is a guess")
            self.assertIsNone(s["write"], s["key"])

    def test_an_action_is_a_held_write_that_moves_no_money_and_states_its_undo(self):
        writes = {k: v for k, v in self.p["caroline_writes"].items() if k != "_doc"}
        self.assertEqual(set(writes), {"retention_offer_apply", "cancel_subscription"},
                         "a new write for Caroline is a captain decision: change this set in the PR that carries it")
        for name, w in writes.items():
            self.assertIs(w["moves_money"], False, name)
            self.assertGreater(len(w["undo"].strip()), 40, f"{name}: the undo must say who runs it and what it restores")
            self.assertTrue(w["bound"].strip(), name)
        actions = [s for s in self.shapes if s["mode"] == "action"]
        self.assertTrue(actions)
        for s in actions:
            self.assertIn(s["write"], writes, s["key"])
            self.assertTrue(s["read"], f"{s['key']}: a write with no read before it")
        self.assertEqual({s["write"] for s in actions}, set(writes), "a held write no shape uses")

    def test_a_fence_writes_nothing_names_its_queue_and_says_why(self):
        fences = [s for s in self.shapes if s["mode"] == "fence"]
        self.assertTrue(fences)
        for s in fences:
            self.assertIsNone(s["write"], s["key"])
            self.assertIn(s["handoff"], HANDOFFS, s["key"])
            self.assertGreater(len(s["why_fenced"].strip()), 40, s["key"])
        src = _tool_sources()["billing-status.ts"]
        for q in HANDOFFS:
            self.assertIn(f'"{q}"', src, f"billing_status no longer routes to {q}")

    def test_every_money_shape_is_a_fence(self):
        """The shapes whose fix is a refund. None of them may ever be an action on Caroline's side."""
        by = {s["key"]: s for s in self.shapes}
        for key in ("refund_request", "charge_dispute", "chargeback_or_fraud", "credit_balance_dispute",
                    "failed_payment_or_card_update"):
            self.assertEqual(by[key]["mode"], "fence", key)
        self.assertEqual(by["refund_request"]["handoff"], "subscription-refund")

    def test_the_refund_rule_has_a_cap_a_ceiling_an_owner_above_it_and_is_not_carolines(self):
        r = self.p["refund_rule"]
        self.assertIs(r["caroline_may_refund"], False)
        self.assertIs(r["caroline_may_promise_a_refund"], False)
        cap, year = r["cap_usd_per_refund"], r["cap_usd_per_customer_per_year"]
        for n in (cap, year, r["veto_window_hours"]):
            self.assertTrue(isinstance(n, (int, float)) and not isinstance(n, bool) and n > 0)
        self.assertEqual((cap, year, r["veto_window_hours"]), (150, 300, 4),
                         "the captain's numbers (10-30; fable ruling 186 Q4/Q5). Changing one is his decision")
        self.assertGreaterEqual(year, cap)
        self.assertIn("captain", r["above_cap"])
        self.assertIn("nothing is refunded", r["above_cap"])
        self.assertTrue(r["covers"].strip())
        self.assertGreaterEqual(len(r["never_by_rule"]), 3)
        self.assertTrue(r["undo"].startswith("none"), "a refund has no undo, and the file must say so")

    def test_caroline_holds_no_refund_delete_or_hide_write(self):
        self.assertIs(self.p["hide"]["caroline_may_hide"], False)
        self.assertIs(self.p["hide"]["caroline_may_delete"], False)
        self.assertEqual(self.p["hide"]["entities"], ["profile", "track", "album"])
        self.assertGreater(len(self.p["hide"]["undo"]), 80)
        for name, text in _tool_sources().items():
            with self.subTest(name):
                self.assertNotIn("muso-stripe-write", text)
                self.assertIsNone(re.search(r'"refunds?",\s*"create"', text), "a refund write in Caroline's plugin")
                self.assertIsNone(re.search(r"HIDDEN_ENTITY_IDS", text), "a hide write in Caroline's plugin")
                self.assertIsNone(re.search(r'method:\s*"DELETE"|"-X",\s*"DELETE"|admin/profile/\$\{[^}]+\}`,\s*\{\s*method',
                                            text), "a DELETE in Caroline's plugin")
        # the one removal tool that exists is a read-only preview, and it is denied on edge all the same
        self.assertIn("remove_credits", self.deny)
        for held_back in ("credits_verify", "profiles_consolidate", "profiles_claim_self", "exec"):
            self.assertIn(held_back, self.deny)

    def test_the_measured_counts_add_up(self):
        total = self.p["unresolved_total"]
        for q in HANDOFFS:
            self.assertEqual(sum(s["unresolved_tickets"][q] for s in self.shapes), total[q], q)
        self.assertRegex(self.p["measured_at"], r"^\d{4}-\d\d-\d\dT\d\d:\d\dZ$")

    def test_the_doc_names_every_shape_and_the_caps(self):
        doc = _read(DOC)
        for s in self.shapes:
            self.assertIn(f"`{s['key']}`", doc, f"docs/support/caroline-billing-and-hide.md does not name {s['key']}")
        r = self.p["refund_rule"]
        self.assertIn(f"${r['cap_usd_per_refund']}", doc)
        self.assertIn(f"${r['cap_usd_per_customer_per_year']}", doc)
        self.assertIn("ERASURE_ITEMS", doc, "the one-time platform-data-processing change the item hides wait on")


if __name__ == "__main__":
    unittest.main()
