"""Mutation check for the one edited test. In-process monkeypatches only; no file in the tree is changed."""
import sys, importlib, unittest, io
for p in ('tests', 'scripts', '.'):
    sys.path.insert(0, p)
m = importlib.import_module('test_gdpr_dsar')
name = 'test_a_request_with_no_owed_letter_gets_the_older_ask_unchanged_while_the_gate_holds_other_letters'

def go(label):
    buf = io.StringIO(); old = sys.stdout, sys.stderr; sys.stdout = sys.stderr = buf
    try:
        r = unittest.TextTestRunner(stream=buf, verbosity=0).run(unittest.defaultTestLoader.loadTestsFromName(name, m.Wiring))
    finally:
        sys.stdout, sys.stderr = old
    bad = len(r.failures) + len(r.errors)
    print(f"{label:78} -> {'RED (' + str(bad) + ')' if bad else 'green'}")

runmod = importlib.import_module('gdpr_pipeline.run')
cls = runmod.Run
orig_held, orig_asks = cls.older_ask_held, cls.asks
go("no mutation")

def any_letter_anywhere(self):
    return any(self.store.messages(r["id"]) for r in self.store.all("open"))

# M1: the bug the test is named for - a letter held for ANOTHER request stands every older ask down
cls.older_ask_held = lambda self, r, kind, now: orig_held(self, r, kind, now) or ("another request's letter is held" if any_letter_anywhere(self) else "")
go("M1 a letter held for another request stands every older ask down")
cls.older_ask_held = orig_held

# M2: the ladder running changes the BYTES of an ask it has no letter for
def asks_m2(self, now=None):
    out = orig_asks(self, now)
    if any_letter_anywhere(self):
        for x in out:
            x["text"] = x["text"] + "\n\nWe have also written to you separately."
    return out
cls.asks = asks_m2
go("M2 the ladder running changes the bytes of an ask it holds no letter for")
cls.asks = orig_asks

# M3: visible only at the real clock - a stamped letter stands other rows down once `now` is past its stamp
def held_m3(self, r, kind, now):
    got = orig_held(self, r, kind, now)
    if got:
        return got
    stamps = [e["at"] for x in self.store.all("open") for e in self.store.events(x["id"]) if e["kind"] == "dsar_authored"]
    return "stamped letter elsewhere" if any(runmod.parse_iso(s) <= now for s in stamps) else ""
cls.older_ask_held = held_m3
go("M3 as M1, but only once the read is at or after the store's own (real-clock) stamp")
cls.older_ask_held = orig_held
go("no mutation, again (patches removed)")
