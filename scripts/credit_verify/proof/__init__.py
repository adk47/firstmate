"""First principle (captain, 2026-10-15): credit requests are decided QUICKLY,
proof can arrive by EMAIL or by INTERCOM, and EVERY document from either
channel passes fraud detection before it counts as evidence. So this package
is channel-agnostic: a proof carries `source` (intercom | email | app) and is
matched to a user by account, never by what its text claims.

Supporting-document forensics for credit proofs (design H3; Fable-approved
plan `data/credit-retro-hold-docfraud-f1/report.md` §7, PR-2). SHADOW ONLY.

Every check emits cited signals ``{check, name, severity, value, evidence}``;
the verdict is a deterministic combination (``verdict.py``). Documents never
leave our infrastructure: everything here is local tools (PyMuPDF, Pillow,
OpenCV, tesseract, qpdf, and exiftool when installed) run in a sandboxed
subprocess with no network (``sandbox.py``). No model reads a document here;
the cited-region AI reviewer is a separate, later step.

A check that cannot run (tool missing, timeout, unparseable file) emits an
``error`` signal; an error is never a pass, so such a proof can never come out
GENUINE.
"""

FORENSICS_VERSION = "pf-1"
