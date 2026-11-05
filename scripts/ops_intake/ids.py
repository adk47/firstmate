"""Identifier extraction from an ask body: what the ask NAMES, not what it means.

Everything the router later acts on (a profile, a track, an Intercom
conversation, a credit request) must come from an identifier the asker wrote
down. Nothing here guesses: an identifier whose type cannot be read from the
sentence it sits in lands in ``untagged`` and the reply says so, which is why
"hide profile 0d898512…" can be refused for an UNKNOWN register identity while
"hide the one we discussed" is never resolved by similarity.

Two shapes are real in this surface and both are supported on purpose:

* the full UUID (what Slack users paste), and
* the census's truncated ``7127c801…`` - an 8-hex prefix followed by an ellipsis.
  A truncated id is NOT a safe handle for a write (it can match several
  profiles), so it is returned in ``truncated_*`` and the router refuses to
  write on one. That distinction is the whole reason the census ids and the
  live ids are kept apart.
"""
from __future__ import annotations

import re
from dataclasses import dataclass, field

UUID = re.compile(
    r"\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b", re.IGNORECASE)
TRUNCATED = re.compile(r"\b([0-9a-f]{8})[…\.]{1,3}(?![0-9a-f])", re.IGNORECASE)
# Intercom conversation ids are 15-19 digit numbers. Anything shorter is a count,
# a price or a ClickUp id, so the bound is load-bearing.
INTERCOM = re.compile(r"\b(\d{15,19})\b")
SPOTIFY_ARTIST = re.compile(r"open\.spotify\.com/artist/([A-Za-z0-9]{22})")
SLACK_PERMALINK = re.compile(r"https?://[a-z0-9-]+\.slack\.com/archives/([A-Z0-9]+)/p(\d{10,})")
MUSO_PROFILE_URL = re.compile(
    r"muso\.ai/profile/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})",
    re.IGNORECASE)
TICKET_URL = re.compile(r"app\.clickup\.com/t/([0-9a-z]+)", re.IGNORECASE)

# Keyword -> identifier type. Order matters: the NEAREST keyword BEFORE the id
# wins, so "hide profile X track Y" types X as profile and Y as track.
KIND_WORDS: tuple[tuple[str, str], ...] = (
    ("profile", "profile"),
    ("artist", "profile"),
    ("track", "track"),
    ("song", "track"),
    ("request", "request"),
    ("claim", "request"),
    ("intercom", "intercom"),
    ("conversation", "intercom"),
    ("ticket", "clickup"),
    ("clickup", "clickup"),
)
_WINDOW = 48  # characters of context that may type an identifier


@dataclass(frozen=True)
class ExtractedIds:
    """Typed identifiers, by type, deduped, in the order they appear."""

    profile: tuple[str, ...] = ()
    track: tuple[str, ...] = ()
    request: tuple[str, ...] = ()
    intercom: tuple[str, ...] = ()
    clickup: tuple[str, ...] = ()
    spotify_artist: tuple[str, ...] = ()
    slack_permalink: tuple[str, ...] = ()
    truncated: tuple[str, ...] = ()
    untagged: tuple[str, ...] = ()

    def as_dict(self) -> dict[str, list[str]]:
        return {k: list(v) for k, v in self.__dict__.items()}

    def hide_targets(self) -> tuple[str, ...]:
        """The pages a hide ask names: typed profile ids, else the untagged ones.

        The router builds the fraud-lens frame from this set, so the lens measures
        every id a hide could act on. The hide answerer writes only on TYPED
        profile ids and asks otherwise, so an untagged id is measured but never
        written.
        """
        return self.profile or self.untagged

    def typed_ids(self) -> tuple[str, ...]:
        return tuple(dict.fromkeys(
            self.profile + self.track + self.request + self.intercom + self.clickup
            + self.spotify_artist))

    @property
    def empty(self) -> bool:
        return not any(self.__dict__.values())

    def evidence(self, limit: int = 6) -> str:
        """The reply's evidence field: only ids that were actually read."""
        ids = self.typed_ids()
        if not ids:
            return "ids=none"
        shown = list(ids[:limit])
        tail = f",+{len(ids) - limit}" if len(ids) > limit else ""
        return "ids=" + ",".join(shown) + tail


def _kind_for(text: str, start: int) -> str | None:
    window = text[max(0, start - _WINDOW):start].lower()
    best: tuple[int, str] | None = None
    for word, kind in KIND_WORDS:
        idx = window.rfind(word)
        if idx >= 0 and (best is None or idx > best[0]):
            best = (idx, kind)
    return best[1] if best else None


def extract(text: str) -> ExtractedIds:
    """Pull the typed identifiers out of one ask body."""
    body = text or ""
    found: dict[str, list[str]] = {k: [] for k in
                                   ("profile", "track", "request", "intercom",
                                    "clickup", "spotify_artist", "slack_permalink",
                                    "truncated", "untagged")}

    for m in UUID.finditer(body):
        kind = _kind_for(body, m.start())
        found[kind if kind in ("profile", "track", "request") else "untagged"].append(
            m.group(0).lower())

    for m in MUSO_PROFILE_URL.finditer(body):
        found["profile"].append(m.group(1).lower())

    for m in INTERCOM.finditer(body):
        found["intercom"].append(m.group(1))

    for m in SPOTIFY_ARTIST.finditer(body):
        found["spotify_artist"].append(m.group(1))

    for m in SLACK_PERMALINK.finditer(body):
        found["slack_permalink"].append(f"{m.group(1)}/{m.group(2)}")

    for m in TICKET_URL.finditer(body):
        found["clickup"].append(m.group(1).lower())

    for m in TRUNCATED.finditer(body):
        found["truncated"].append(m.group(1).lower())

    return ExtractedIds(**{k: tuple(dict.fromkeys(v)) for k, v in found.items()})

