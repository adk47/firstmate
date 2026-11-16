"""What the customer TYPED alongside a filed document (`proof_intake.reply_text_json`).

The F9 ask tells the customer to put our code in the find box and screenshot it. Some type the code in the
message instead. The reader looked only at the document's extracted text, so that customer was invisible to it
(28 codes issued from 2026-11-01, 0 consumed). The intake writer records the customer's own words here; the
reader (`docverify/challenge.py`) looks for the code in them as well as in the document.

What is kept, and why it is this narrow:

  * only messages a CUSTOMER wrote (user / lead / contact): our own ask carries the code, so a staff or bot
    message is never reply text;
  * only the customer's own words: quoted history is removed (`plain`), because a reply to our email quotes
    the ask and the ask contains the code. What a mail client still leaves behind is refused by the reader
    (`challenge.shown`), which is the rule that matters; this is the first of two layers;
  * each message with ITS OWN time, so the reader judges a typed code against the code's window at the moment
    it was typed: the document's time never stands in for the message's;
  * only messages within `NEAR_DAYS` of the document, at most `MAX_PARTS` of them, `MAX_CHARS` each. A code is
    valid 7 days and both the document and the typed code must be inside that one window, so a message further
    away can never count; the rest of the conversation is not copied into the proof store.

Nothing here judges, and the text is never given to a model: the reader does a substring search on it.
"""
from __future__ import annotations

import html
import json
import re
from datetime import datetime, timedelta, timezone
from html.parser import HTMLParser
from typing import Any

CUSTOMER_AUTHORS = ("user", "lead", "contact")
NEAR_DAYS = 7          # = docverify.challenge.VALID_DAYS (pinned by a test): the widest gap that can still count
MAX_PARTS = 20
MAX_CHARS = 2000

_VOID = {"area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "source", "track", "wbr"}
_BLOCK = {"p", "div", "br", "li", "tr", "h1", "h2", "h3", "h4", "h5", "h6", "table", "ul", "ol", "pre"}
_DROP = {"blockquote", "style", "script", "head", "title"}
# the wrappers mail clients put around quoted history
_QUOTE_CLASS = re.compile(r"gmail_quote|gmail_attr|yahoo_quoted|moz-cite-prefix|OutlookMessageHeader|"
                          r"protonmail_quote", re.I)
_QUOTE_ID = re.compile(r"divRplyFwdMsg|appendonsend|mail-editor-reference-message-container", re.I)
# "On Mon, 3 Nov 2026 at 10:00, Muso <...> wrote:" (a client may wrap it onto two lines), and the plain
# headers of a forwarded / replied-to message: everything from there on is history. A quote header carries a
# date or an address; "On the dashboard at 10:00 it wrote:" is the customer's own sentence, not history.
_MONTH = r"(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)[a-z]*\.?"
_HEADER_FACT = (r"(?:[\w.+-]+@[\w.-]+\.\w+"
                r"|\b" + _MONTH + r"\s+\d{1,2},?\s+\d{4}\b"
                r"|\b\d{1,2}\s+" + _MONTH + r",?\s+\d{4}\b"
                r"|\b\d{4}-\d{2}-\d{2}\b"
                r"|\b\d{1,2}[/.]\d{1,2}[/.]\d{2,4}\b)")
_CUT = re.compile(r"(?im)^[ \t]*(?:On\b(?=[^\n]{0,300}(?:\n[^\n]{0,300})?\bwrote:[ \t]*$)"
                  r"(?=[^\n]{0,300}(?:\n[^\n]{0,300})?" + _HEADER_FACT + r")"
                  r"[^\n]{0,300}(?:\n[^\n]{0,300})?\bwrote:[ \t]*$"
                  r"|-{2,}[ \t]*(?:Original|Forwarded) Message[ \t]*-{2,}"
                  r"|From:[^\n]{0,300}\n[ \t]*(?:Sent|Date):"
                  r"|_{10,}[ \t]*$)")


class _Text(HTMLParser):
    """The visible text of an HTML body, minus quoted history."""

    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.out: list[str] = []
        self.skip = 0                 # depth inside a dropped element

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        if self.skip:
            if tag not in _VOID:
                self.skip += 1
            return
        a = {k: (v or "") for k, v in attrs}
        if tag in _DROP or _QUOTE_CLASS.search(a.get("class", "")) or _QUOTE_ID.search(a.get("id", "")):
            if tag not in _VOID:
                self.skip = 1
            return
        if tag in _BLOCK:
            self.out.append("\n")

    def handle_endtag(self, tag: str) -> None:
        if self.skip:
            if tag not in _VOID:
                self.skip -= 1
            return
        if tag in _BLOCK:
            self.out.append("\n")

    def handle_data(self, data: str) -> None:
        if not self.skip:
            self.out.append(data)


def plain(body: Any) -> str:
    """The customer's own words in a message body (Intercom HTML or a plain email body): tags dropped, quoted
    history dropped, whitespace collapsed, capped at MAX_CHARS. "" when nothing is left."""
    raw = str(body or "")
    if not raw.strip():
        return ""
    if "<" in raw and ">" in raw:
        p = _Text()
        try:
            p.feed(raw)
            p.close()
            text = "".join(p.out)
        except Exception:  # noqa: BLE001 - a body the parser cannot read is kept as text, tags stripped
            text = html.unescape(re.sub(r"<[^>]+>", " ", raw))
    else:
        text = html.unescape(raw)
    cut = _CUT.search(text)
    if cut:
        text = text[:cut.start()]
    lines = [ln.strip() for ln in text.splitlines() if not ln.lstrip().startswith(">")]
    text = "\n".join(ln for ln in (re.sub(r"[ \t\xa0]+", " ", ln) for ln in lines) if ln)
    return text[:MAX_CHARS].strip()


def _iso(epoch: Any) -> str:
    """An Intercom epoch as UTC ISO; "" for a missing or zero one (zero is "not set", never 1970)."""
    try:
        if float(epoch) <= 0:
            return ""
        return datetime.fromtimestamp(float(epoch), tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    except (TypeError, ValueError, OSError):
        return ""


def _ts(stamp: Any) -> datetime | None:
    try:
        return datetime.fromisoformat(str(stamp).replace("Z", "+00:00")) if stamp else None
    except ValueError:
        return None


def customer_parts(conv: dict[str, Any] | None) -> list[dict[str, str]]:
    """[{at, text}] for every message a customer wrote in the conversation, oldest first. A message with no
    time of its own is left out: the reader could not place it in a code's window."""
    conv = conv or {}
    source = conv.get("source") or {}
    parts = [source] + list(((conv.get("conversation_parts") or {}).get("conversation_parts")) or [])
    out: list[dict[str, str]] = []
    for i, p in enumerate(parts):
        if not isinstance(p, dict) or (p.get("author") or {}).get("type") not in CUSTOMER_AUTHORS:
            continue
        # the conversation's own time dates only its opening message; a later part without a time has none
        at = _iso(p.get("created_at") or (conv.get("created_at") if i == 0 else None))
        text = plain(p.get("body"))
        if at and text:
            out.append({"at": at, "text": text})
    return sorted(out, key=lambda r: r["at"])


def near(parts: list[dict[str, str]], doc_at: str | None) -> list[dict[str, str]]:
    """The messages that can matter for a document received at `doc_at`: within NEAR_DAYS of it, the ones
    closest to it first when there are more than MAX_PARTS, returned oldest first. A document with no time
    keeps none."""
    got = _ts(doc_at)
    if got is None:
        return []
    span = timedelta(days=NEAR_DAYS)
    keep = [(abs(t - got), p) for p in parts for t in [_ts(p.get("at"))] if t is not None and abs(t - got) <= span]
    keep.sort(key=lambda kp: (kp[0], kp[1]["at"], kp[1]["text"]))
    return sorted((p for _d, p in keep[:MAX_PARTS]), key=lambda r: (r["at"], r["text"]))


def dumps(parts: list[dict[str, str]] | None) -> str | None:
    """The stored form (canonical, so an unchanged conversation rewrites nothing); None for no text."""
    rows = [{"at": str(p.get("at") or ""), "text": str(p.get("text") or "")[:MAX_CHARS]}
            for p in (parts or []) if p.get("at") and str(p.get("text") or "").strip()]
    return json.dumps(rows[:MAX_PARTS], sort_keys=True, ensure_ascii=False) if rows else None


def loads(stored: Any) -> list[dict[str, str]]:
    """The reader's side: [] for NULL, an older row, or a value that does not parse (never raises: one bad
    row must not stop a run, and no text simply means the document alone is read)."""
    try:
        rows = json.loads(stored) if stored else []
    except (TypeError, ValueError):
        return []
    if not isinstance(rows, list):
        return []
    return [{"at": str(r.get("at") or ""), "text": str(r.get("text") or "")}
            for r in rows if isinstance(r, dict) and r.get("at") and r.get("text")]
