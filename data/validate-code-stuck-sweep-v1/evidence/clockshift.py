"""Run one unittest file with the process clock set to a given instant. Read-only: measures, changes nothing."""
import datetime as _dt, sys, unittest, importlib, io, os
at = _dt.datetime.fromisoformat(sys.argv[1]).replace(tzinfo=_dt.timezone.utc)
real = _dt.datetime
class Shifted(real):
    @classmethod
    def now(cls, tz=None):
        v = at.astimezone(tz) if tz else at.replace(tzinfo=None)
        return cls(v.year, v.month, v.day, v.hour, v.minute, v.second, v.microsecond, v.tzinfo)
    @classmethod
    def utcnow(cls):
        return cls.now().replace(tzinfo=None)
_dt.datetime = Shifted
for p in ('tests', 'scripts', '.'):
    sys.path.insert(0, p)
m = importlib.import_module(sys.argv[2])
buf = io.StringIO()
old = sys.stdout, sys.stderr
sys.stdout = sys.stderr = buf
try:
    r = unittest.TextTestRunner(stream=buf, verbosity=0).run(unittest.defaultTestLoader.loadTestsFromModule(m))
finally:
    sys.stdout, sys.stderr = old
bad = sorted({t.id().split('.')[-1] if not hasattr(t, 'test_case') else t.test_case.id().split('.')[-1] for t, _ in r.failures + r.errors})
print(f"{sys.argv[1]}  ran={r.testsRun} failing_tests={len(bad)}")
for b in bad:
    print("    " + b[:150])
