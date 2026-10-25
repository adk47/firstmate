"""The signal every forensic check emits, and the per-file analysis context.

Severity:
  hard      on its own makes the proof FORGED_LIKELY (e.g. an AI-generator
            marker, a post-signature content edit, another account's document
            reused by a submitter it doesn't name - only when the name check
            could run);
  soft      SUSPECT on its own; some pairs of soft signals combine to hard
            (verdict.py);
  mismatch  content contradicts the claim (wrong recording, claimant absent,
            split shares that cannot be right) -> INCONSISTENT, with a reason
            the claimant can act on;
  positive  supports the claim (ISRC of the claimed recording, a camera
            provenance manifest, a split sheet shared by co-writers it names);
  issuer    an independent issuer signal (a valid other-party e-signature
            covering unchanged content) - with a clean, consistent document
            this is the A3 anchor;
  info      recorded for the audit and for tuning, never moves the verdict;
  error     the check could not run; never a pass.
Every signal cites where it came from: file, page, region (PDF points or
image pixels, [x0, y0, x1, y1]), byte range, and the tool that saw it.
"""

from __future__ import annotations

from dataclasses import dataclass, field, replace
from typing import Any

HARD, SOFT, MISMATCH, POSITIVE, ISSUER, INFO, ERROR = "hard", "soft", "mismatch", "positive", "issuer", "info", "error"
SEVERITIES = (HARD, SOFT, MISMATCH, POSITIVE, ISSUER, INFO, ERROR)


@dataclass
class Evidence:
    file: str
    tool: str
    tool_version: str = ""
    page: int | None = None                      # 1-based
    region: list[float] | None = None            # [x0, y0, x1, y1]
    byte_range: list[int] | None = None          # [start, end)
    excerpt: str | None = None                   # short, non-personal (a field label, a marker)

    def as_dict(self) -> dict[str, Any]:
        return {k: v for k, v in self.__dict__.items() if v not in (None, "")}


@dataclass
class Signal:
    check: str          # F1, F2, F2b, F3a, F3b, F3c, F4a, F4b, F4c, F4d, F5a, F5b, F5c, F5e
    name: str
    severity: str
    value: Any = None
    reason: str = ""    # plain words, safe to show the claimant for mismatch signals
    evidence: Evidence | None = None

    def as_dict(self) -> dict[str, Any]:
        d: dict[str, Any] = {"check": self.check, "name": self.name, "severity": self.severity}
        if self.value is not None:
            d["value"] = self.value
        if self.reason:
            d["reason"] = self.reason
        if self.evidence is not None:
            d["evidence"] = self.evidence.as_dict()
        return d

    @classmethod
    def from_dict(cls, d: dict[str, Any]) -> Signal:
        ev = d.get("evidence")
        return cls(check=d["check"], name=d["name"], severity=d["severity"], value=d.get("value"),
                   reason=d.get("reason", ""), evidence=Evidence(**ev) if isinstance(ev, dict) else None)


@dataclass
class ClaimContext:
    """What the proof is supposed to support. Empty when the proof is not
    linked to a credit request yet (Intercom cache replay before core C1b):
    then the content cross-checks only extract and record entities.
    `request_ids[i]` is the request for `claimed_roles[i]`; each claimed role
    gets its own verdict (claims()). Lists that don't pair up are an error
    (paired), never guessed."""
    request_ids: list[str] = field(default_factory=list)
    track_title: str | None = None
    track_artists: list[str] = field(default_factory=list)
    isrcs: list[str] = field(default_factory=list)
    claimed_roles: list[str] = field(default_factory=list)
    claimant_names: list[str] = field(default_factory=list)   # profile name, aka, legal name, account full name
    verified_names: list[str] = field(default_factory=list)   # trusted DSP identity link / verified legal name only
    lifetime_streams: int | None = None                       # the track's lifetime streams (catalog)
    artist_lifetime_streams: int | None = None                # the claimed track artist's lifetime streams
    release_date: str | None = None
    track_key: str | None = None                              # catalog track id, for cross-claim reuse

    @property
    def linked(self) -> bool:
        return bool(self.track_title or self.isrcs)

    @property
    def request_id(self) -> str:
        return ",".join(self.request_ids)

    @property
    def paired(self) -> bool:
        """Every claimed role has exactly one request to record its verdict
        under."""
        if self.request_ids and self.claimed_roles:
            return len(self.request_ids) == len(self.claimed_roles)
        return len(self.claimed_roles) <= 1

    def claims(self) -> list[ClaimContext]:
        """One context per claimed role and its request (for a paired
        context); this context itself when it carries at most one role."""
        if len(self.claimed_roles) <= 1:
            return [self]
        return [replace(self, claimed_roles=[role], request_ids=[rid])
                for rid, role in zip(self.request_ids, self.claimed_roles)]

    def as_dict(self) -> dict[str, Any]:
        return dict(self.__dict__)

    @classmethod
    def from_dict(cls, d: dict[str, Any] | None) -> ClaimContext:
        d = d or {}
        return cls(**{k: d[k] for k in cls.__dataclass_fields__ if k in d})


@dataclass
class Extracted:
    """What later checks need from a file: its text per page (PDF text layer
    or OCR), word boxes, and the document kind. Kept in memory only."""
    pages_text: list[str] = field(default_factory=list)
    ocr_words: list[dict[str, Any]] = field(default_factory=list)   # {text, page, box:[x0,y0,x1,y1], conf}
    layer_words: list[dict[str, Any]] = field(default_factory=list)  # PDF text-layer words {text, page, box}
    track_listed: bool | None = None                                 # claimed track's title/ISRC in the text (None = not checked)
    text_source: str = ""                                           # pdf_text | ocr | none
    kind: str = "unknown"

    @property
    def text(self) -> str:
        return "\n".join(self.pages_text)

    @property
    def words(self) -> list[dict[str, Any]]:
        """Word boxes of the text the content checks read."""
        return self.layer_words if self.text_source == "pdf_text" else self.ocr_words
