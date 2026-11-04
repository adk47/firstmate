"""ONE model chain for every SCRIPTED user-request path.

Captain 2026-11-03: "primary = the OpenClaw subscription token model; when it
runs out, OpenRouter deepseek 1017". Before this module each scripted path
picked its own model and handled failure its own way, and none of them knew
about the DeepSeek tier:

  * ``credit_review/judge.py``      one metered OpenRouter model and no
                                    subscription rung in front of it. Its
                                    DEFAULT becomes this chain's tier 2 (deepseek
                                    1017); a caller that pins a model - e.g.
                                    ``batch_judge``'s evaluated ``x-ai/grok-4.3``
                                    for outbound copy, or ``CREDIT_REVIEW_MODEL``
                                    - keeps that model AS tier 2, with tier 1 in
                                    front of it;
  * ``credit_verify/docverify/extract.py``  OpenRouter deepseek, no
                                    subscription rung in front of it;
  * ``credit_trust/llm.py``         codex -> Jev, no metered rung at all, so a
                                    dead subscription meant DEFER forever;
  * the OpenClaw agent turns        gpt-6-sol -> OpenRouter gpt-6-luna (paid
                                    frontier) -> haiku (paid frontier): a
                                    subscription outage silently upgraded every
                                    agent turn onto paid frontier inference. They
                                    now share the same ONE metered fallback
                                    (openclaw-*.json, cron-jobs.json, enforced by
                                    validate-config-matrix.sh check 6b).

The chain is fixed, and the SAME order everywhere:

    tier 1  subscription  the ChatGPT/Codex subscription already in use, via
                          ``scripts/lib/codex-judge-exec.sh`` (tool-less,
                          read-only sandbox, $0). SKIPPED (not attempted) when
                          the request needs headless web search: on
                          codex-cli 0.156.1 search only exists through Code
                          Mode's ``exec`` host, which that helper disables on
                          purpose (T01 spike; docs/credit-verification/
                          credit-trust-llm.md). A tier that cannot serve must
                          say so, never answer blind.
    tier 2  deepseek      OpenRouter ``deepseek/deepseek-v4.1-flash-1017``
                          (captain's standing rule, metered, cheap), with
                          OpenRouter's ``web`` plugin when the request asked
                          for web evidence and ``data_collection: deny`` for
                          user data.

Failure classes and what each does (``classify``):

    retry same tier   rate_limited · server_error · timeout       (backoff)
    next tier         quota · auth_expired · unavailable · bad_answer
    ABORT the chain   unsafe  (codex tool/safety violation: the answer must be
                      dropped and the caller must not re-ask a metered model
                      the same question)

Every attempt is ONE append-only JSONL row in the usage ledger, and every
attempt emits ONE ``[model-chain]`` line on stderr naming the tier — so
``scripts/model-chain-watchdog.py`` can page on the fallback SHARE and on a
chain that ran out of tiers, and an operator can grep a run for "which tier
served this call".

This module is a CLIENT, not a policy: it never approves, writes or decides
anything. Callers keep their own caps, ledgers and gates.
"""

from __future__ import annotations

import fcntl
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable, Iterable, Sequence

SCRIPTS = Path(__file__).resolve().parents[1]

CODEX_HELPER = Path(os.environ.get("MODEL_CHAIN_CODEX_HELPER", SCRIPTS / "lib" / "codex-judge-exec.sh"))
OPENROUTER_URL = os.environ.get("MODEL_CHAIN_OPENROUTER_URL", "https://openrouter.ai/api/v1/chat/completions")
KEY_FILE = os.environ.get("MODEL_CHAIN_KEY_FILE", "/opt/hydra/secrets/llm-provider-keys.json")
LEDGER_PATH = os.environ.get("MODEL_CHAIN_LEDGER", "/var/lib/hydra/model-chain/calls.jsonl")

# Tier 1 = the subscription the fleet already runs on (openclaw agents are on
# gpt-6-sol / gpt-6-luna). Tier 2 = the captain's standing fallback model.
SUBSCRIPTION_MODEL = os.environ.get("MODEL_CHAIN_SUBSCRIPTION_MODEL", "gpt-6-sol")
FALLBACK_MODEL = os.environ.get("MODEL_CHAIN_FALLBACK_MODEL", "deepseek/deepseek-v4.1-flash-1017")

TIER_SUBSCRIPTION = "subscription"
TIER_FALLBACK = "deepseek"
TIERS = (TIER_SUBSCRIPTION, TIER_FALLBACK)

# A new METERED rung needs its own ceiling: before this module the credit paths
# were either $0 (codex/Jev) or capped by their own caller. DeepSeek is cheap but
# not free, and a wedged loop must not be able to spend without bound.
# Reserved (and written) BEFORE each metered call: deepseek's most expensive
# possible answer is ~$0.033 (131k output tokens at $0.25/M), so $0.05 is a real
# ceiling, and the exact charge is settled against it right after the call.
RESERVATION_USD = float(os.environ.get("MODEL_CHAIN_RESERVATION_USD", "0.05"))
# Per-token CEILING per metered model, in USD, taken from OpenRouter's own model
# list on 2026-11-04 and rounded UP to the model's most expensive tier. These are
# bounds, not forecasts: `admit()` is only a real ceiling if the reservation
# covers the worst case (QA 2026-11-03). Both the peak and the off-peak / long
# context tiers are accounted for, e.g. deepseek-1017 is 1.5e-7/6e-7 off-peak and
# 3e-7/1.2e-6 at peak, grok-4.3 is 1.25e-6/2.5e-6 and doubles past 200k prompt
# tokens.
PRICE_USD_PER_TOKEN = {
    FALLBACK_MODEL: (3.0e-7, 1.2e-6),
    "x-ai/grok-4.3": (2.5e-6, 5.0e-6),          # batch_judge's evaluated pin
    "openai/gpt-6-luna": (2.0e-7, 7.5e-7),      # agent primary; reachable via a pin
}
# OpenRouter bills web search PER RESULT, and the fee differs per model.
WEB_FEE_USD_PER_RESULT = {FALLBACK_MODEL: 0.01, "x-ai/grok-4.3": 0.005, "openai/gpt-6-luna": 0.01}
# A model with no price above cannot be held under a cap, so the metered tier
# REFUSES it and says how to fix it, rather than pricing a frontier model at
# deepseek rates and overshooting (QA 2026-11-03). An operator who knows the price
# can set its ceiling for the run instead.
UNPRICED_MAX_USD = float(os.environ.get("MODEL_CHAIN_UNPRICED_MAX_USD", "0") or 0)
DAILY_USD_CAP = float(os.environ.get("MODEL_CHAIN_DAILY_USD", "10"))
DEFAULT_RETRIES = int(os.environ.get("MODEL_CHAIN_RETRIES", "2"))
BACKOFF_S = tuple(float(x) for x in os.environ.get("MODEL_CHAIN_BACKOFF_S", "0.5,1.5").split(",") if x.strip())
SUBSCRIPTION_TIMEOUT_S = int(os.environ.get("MODEL_CHAIN_SUBSCRIPTION_TIMEOUT_S", "90"))
FALLBACK_TIMEOUT_S = int(os.environ.get("MODEL_CHAIN_FALLBACK_TIMEOUT_S", "120"))

# ── failure classes ──────────────────────────────────────────────────────────
QUOTA = "quota"
AUTH_EXPIRED = "auth_expired"
RATE_LIMITED = "rate_limited"
SERVER_ERROR = "server_error"
TIMEOUT = "timeout"
UNAVAILABLE = "unavailable"
UNSAFE = "unsafe"
BAD_ANSWER = "bad_answer"
# Skips that mean "the subscription CANNOT do this request", not "the
# subscription failed": a fallback behind one of these is expected paid usage, not
# an outage, so it must never be counted as fallback pressure (QA 2026-11-03).
CAPABILITY_SKIPS = frozenset({
    "web_search_unavailable",     # credit_review: codex-cli 0.156.1 has no headless search
    "no_web_search",              # jev rung
    "web_search_not_used_here",   # credit-trust's evidence rule (hydra#1142)
    "no_images",                  # the metered text model is asked for pictures
})

# An attempt the provider could have charged for: a served answer, or a served but
# unusable one (truncated / unparseable). A `skipped` attempt never left the box and
# a transport error (429/5xx/timeout) consumed nothing.
BILLABLE_KINDS = frozenset({BAD_ANSWER})


def _billable_row(row: dict) -> bool:
    """True when this attempt could have been billed even if it charged nothing
    we can see. Used by the cap so an unpriced charge errs expensive."""
    return row.get("outcome") == "ok" or row.get("kind") in BILLABLE_KINDS
CHAIN_EXHAUSTED = "chain_exhausted"

RETRY_SAME_TIER = frozenset({RATE_LIMITED, SERVER_ERROR, TIMEOUT})
# Never fall back after these: the answer was refused for a safety reason, and
# re-asking a different model the same question would launder the refusal.
ABORT_CHAIN = frozenset({UNSAFE})

_QUOTA_RE = re.compile(r"quota|usage limit|usage_limit|insufficient_quota|subscription usage", re.I)
_AUTH_RE = re.compile(r"auth|401|403|invalid_api_key|token_invalidated|could not be refreshed|session has ended|log out and sign in|token_expired", re.I)
_RATE_RE = re.compile(r"rate.?limit|429|too many requests|overloaded", re.I)
_SERVER_RE = re.compile(r"\b5\d\d\b|server error|bad gateway|unavailable|timed out|timeout", re.I)


def utcnow() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def sha256_text(s: str) -> str:
    return hashlib.sha256(s.encode("utf-8")).hexdigest()


def classify_text(text: str | None) -> str | None:
    """Map a provider's error text onto the failure classes above. Order
    matters: a quota 429 must read as quota (fatal for the subscription, since
    retrying cannot help) before it reads as rate_limited."""
    s = text or ""
    if _QUOTA_RE.search(s):
        return QUOTA
    if _AUTH_RE.search(s):
        return AUTH_EXPIRED
    if _RATE_RE.search(s):
        return RATE_LIMITED
    if _SERVER_RE.search(s):
        return SERVER_ERROR
    return None


def classify_http(status: int, body: str = "") -> str:
    kind = classify_text(body)
    if kind:
        return kind
    if status == 429:
        return RATE_LIMITED
    if status in (401, 403):
        return AUTH_EXPIRED
    if status in (402,):
        return QUOTA
    if 500 <= status < 600:
        return SERVER_ERROR
    return UNAVAILABLE


# ── usage ledger (append-only JSONL) ─────────────────────────────────────────
@dataclass
class UsageLedger:
    """One row per ATTEMPT. Append-only by convention and by construction: the
    only operation this class offers is ``record``. Lives under /var/lib/hydra
    so a deploy (which rsyncs over /opt/hydra) cannot erase the history."""
    path: Path = Path(LEDGER_PATH)
    # Why accounting is unavailable: a write that failed, or a read that could not
    # be performed. Set once and never cleared, so a process that has lost the
    # ledger cannot go back to spending on the strength of a later happy read.
    broken: str | None = None

    def reserve(self, amount: float, *, surface: str, step: str) -> bool:
        """Durably write the spend we are ABOUT to incur, before incurring it.

        QA 2026-11-03 (carried forward): a readable-but-unwritable ledger let every
        new process read yesterday's total, spend, fail to write, and repeat - the
        cap never bound across processes. So a metered call must be preceded by a
        row that survives, and the actual cost is settled against it afterwards
        (``settle``), keeping the ledger append-only and its sum exact."""
        self.record({"surface": surface, "step": step, "tier": TIER_FALLBACK,
                     "outcome": "reserve", "cost_usd": float(amount)})
        return self.broken is None

    def admit(self, cap: float, amount: float, *, surface: str, step: str) -> str | None:
        """Atomically check the cap AND reserve, across processes.

        QA 2026-11-03: ``spent >= cap`` followed by a separate reservation let a
        day at $9.99 admit one more call (and the charge could push the total past
        the cap), and two workers could both read the same below-cap total before
        either reserved. Both halves now happen under an exclusive lock, and the
        reservation itself must FIT: ``spent + amount > cap`` is refused, so the
        cap is a ceiling and not a hint.

        Returns ``None`` when admitted, else the reason to log."""
        if cap <= 0:
            self.record({"surface": surface, "step": step, "tier": TIER_FALLBACK,
                         "outcome": "reserve", "cost_usd": float(amount)})
            return None if self.broken is None else f"accounting unavailable ({self.broken})"
        lock_path = self.path.with_suffix(self.path.suffix + ".lock")
        try:
            lock_path.parent.mkdir(parents=True, exist_ok=True)
            with open(lock_path, "a", encoding="utf-8") as lock:
                fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
                try:
                    spent = self.spent_today_usd()
                    if spent + amount > cap:
                        return (f"daily cap ${cap:.2f} reached (spent ${spent:.2f}, "
                                f"next call reserves ${amount:.2f})")
                    self.record({"surface": surface, "step": step, "tier": TIER_FALLBACK,
                                 "outcome": "reserve", "cost_usd": float(amount)})
                    if self.broken is not None:
                        return f"accounting unavailable ({self.broken})"
                    return None
                finally:
                    fcntl.flock(lock.fileno(), fcntl.LOCK_UN)
        except AccountingUnavailable as exc:
            return f"accounting unavailable ({exc}) — metered tier refused"
        except OSError as exc:
            return f"accounting unavailable ({type(exc).__name__}: {exc}) — metered tier refused"

    def settle(self, reserved: float, actual: float | None, *, surface: str, step: str) -> None:
        """Release the reservation. The call's own row already carries what the
        provider charged, so the release is exactly ``-reserved`` (plus the actual
        figure for the audit trail) and the day's SUM equals the real spend."""
        if abs(float(reserved)) > 1e-9:
            self.record({"surface": surface, "step": step, "tier": TIER_FALLBACK,
                         "outcome": "settle", "cost_usd": -float(reserved),
                         "actual_usd": None if actual is None else float(actual)})

    def __post_init__(self) -> None:
        # Overridable so a test, a staging copy or a canary can point the DEFAULT
        # ledger somewhere writable instead of inheriting the host's
        # /var/lib/hydra. An explicit path always wins over the environment.
        override = os.environ.get("MODEL_CHAIN_LEDGER_PATH")
        if override and str(self.path) == LEDGER_PATH:
            self.path = Path(override)

    def _append(self, line: str) -> None:
        """The only write. Separate so a test can make WRITES fail while READS
        still work - the read-only-mount case, which chmod cannot reproduce on a
        root runner (QA 2026-11-03)."""
        self.path.parent.mkdir(parents=True, exist_ok=True)
        with open(self.path, "a", encoding="utf-8") as fh:
            fh.write(line)

    def record(self, row: dict[str, Any]) -> dict[str, Any]:
        row = {"ts": utcnow(), "epoch": int(time.time()), **row}
        try:
            self._append(json.dumps(row, default=str) + "\n")
        except OSError as exc:
            # A ledger failure must not break a user-request path, but it must
            # also not silently disable the daily cap: the cost of this call is
            # no longer countable, so the METERED tier stops until it is.
            self.broken = f"{type(exc).__name__}: {exc}"
            print(f"[model-chain] ledger write failed — metered tier disabled: {self.broken}",
                  file=sys.stderr, flush=True)
        return row

    def calls(self, since_epoch: float = 0.0) -> list[dict[str, Any]]:
        return read_calls(self.path, since_epoch, strict=True)

    def spent_today_usd(self) -> float:
        if self.broken:
            raise AccountingUnavailable(self.broken)
        day = datetime.now(timezone.utc).strftime("%Y-%m-%dT00:00:00Z")
        total = 0.0
        for row in self.calls():
            if str(row.get("ts") or "") < day:
                continue
            cost = row.get("cost_usd")
            if isinstance(cost, (int, float)):
                total += float(cost)
            elif cost is None and _billable_row(row) and row.get("tier") != TIER_SUBSCRIPTION:
                # An ANSWER with no price (a legacy row, or a provider that reported
                # none before this path booked the ceiling). Never zero: an unknown
                # charge must not make the day look cheaper. A `skipped`/`error` row
                # and the `chain_exhausted` marker charge nothing, so they are NOT
                # counted - billing them would lock the tier out for the day with
                # phantom spend (QA 2026-11-03).
                total += RESERVATION_USD
        return total


class AccountingUnavailable(RuntimeError):
    """The usage ledger cannot be read or written, so the amount already spent
    today is UNKNOWN. Metered calls refuse to run rather than guess zero."""


def read_calls(path: Path | str = LEDGER_PATH, since_epoch: float = 0.0,
               *, strict: bool = False) -> list[dict[str, Any]]:
    """Ledger rows. ``strict`` is for the SPEND CAP: a missing file is a real
    zero, but an unreadable one is not, and answering 0.0 there would let paid
    calls run past the cap while the history is invisible."""
    rows: list[dict[str, Any]] = []
    try:
        with open(path, encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    row = json.loads(line)
                except json.JSONDecodeError:
                    if strict:
                        # Half a ledger is not a smaller spend: if a row cannot be
                        # read, the day's total is UNKNOWN (QA 2026-11-03).
                        raise AccountingUnavailable(f"malformed ledger line: {line[:120]!r}") from None
                    continue
                if not isinstance(row, dict):
                    if strict:
                        raise AccountingUnavailable(f"malformed ledger row: {line[:120]!r}")
                    continue
                ep = row.get("epoch")
                if isinstance(ep, (int, float)) and ep < since_epoch:
                    continue
                rows.append(row)
    except FileNotFoundError:
        return []
    except OSError as exc:
        if strict:
            raise AccountingUnavailable(f"{type(exc).__name__}: {exc}") from exc
        return []
    return rows


# ── results ──────────────────────────────────────────────────────────────────
@dataclass
class TierAttempt:
    """One tier's outcome for one request."""
    tier: str
    outcome: str                  # ok | error | skipped
    model: str | None = None
    kind: str | None = None       # failure class (never set when ok)
    reason: str | None = None     # human-readable detail, bounded
    text: str = ""
    json: Any = None
    citations: list[str] = field(default_factory=list)
    cost_usd: float | None = None
    input_tokens: int | None = None
    output_tokens: int | None = None
    latency_ms: int | None = None
    meta: dict[str, Any] = field(default_factory=dict)


@dataclass
class ChainResult:
    ok: bool
    tier: str | None = None
    model: str | None = None
    text: str = ""
    json: Any = None
    citations: list[str] = field(default_factory=list)
    cost_usd: float | None = None
    input_tokens: int | None = None
    output_tokens: int | None = None
    error: str | None = None
    error_kind: str | None = None
    prompt_sha256: str = ""
    latency_ms: int = 0
    attempts: list[dict[str, Any]] = field(default_factory=list)
    model_reported: str | None = None   # provider-reported model id, None if it reported none
    finish_reason: str | None = None    # metered attempt's finish_reason ("length" = hit the cap)

    @property
    def served_by_fallback(self) -> bool:
        return self.ok and self.tier == TIER_FALLBACK

    def as_dict(self) -> dict[str, Any]:
        return {"ok": self.ok, "tier": self.tier, "model": self.model, "json": self.json,
                "citations": self.citations, "cost_usd": self.cost_usd, "error": self.error,
                "error_kind": self.error_kind, "prompt_sha256": self.prompt_sha256,
                "latency_ms": self.latency_ms, "attempts": self.attempts,
                "model_reported": self.model_reported, "finish_reason": self.finish_reason}


# ── answer parsing ───────────────────────────────────────────────────────────
def parse_json_answer(text: str) -> Any:
    try:
        return json.loads(text)
    except (json.JSONDecodeError, TypeError):
        m = re.search(r"\{.*\}", text or "", re.S)
        if not m:
            raise ValueError("no JSON object in the answer")
        return json.loads(m.group(0))


def check_schema(obj: Any, schema: dict[str, Any] | None) -> str | None:
    """Light structural check (top-level type + required keys). Providers
    enforce the full schema; this catches a rung that ignored it."""
    if not schema:
        return None
    if schema.get("type") == "object":
        if not isinstance(obj, dict):
            return "answer is not an object"
        missing = [k for k in schema.get("required") or [] if k not in obj]
        if missing:
            return f"answer is missing {missing}"
    return None


def messages_text(messages: Sequence[dict[str, Any]]) -> str:
    parts: list[str] = []
    for m in messages:
        c = m.get("content")
        if isinstance(c, str):
            parts.append(c)
        elif isinstance(c, list):
            parts.extend(str(p.get("text") or "") for p in c if isinstance(p, dict))
    return "\n".join(parts)


# ── key loading (same file the rest of hydra reads) ──────────────────────────
def load_key(path: Path | str | None = None) -> str | None:
    """The OpenRouter key. ``path`` defaults to KEY_FILE at CALL time (not at import
    time) so a test or a caller can redirect the source without reimporting."""
    env = os.environ.get("OPENROUTER_API_KEY")
    if env:
        return env
    try:
        with open(KEY_FILE if path is None else path, encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, json.JSONDecodeError):
        return None
    key = data.get("OPENROUTER_API_KEY") if isinstance(data, dict) else None
    return key if isinstance(key, str) and key else None


# ── codex event stream (minimal; credit_trust/llm.py has the audited copy) ───
def parse_codex_events(stdout: str) -> dict[str, Any]:
    """Final agent message + usage + turn errors out of `codex exec --json`
    JSONL. Deliberately small and dependency-free: credit_trust/llm.py owns
    the full parser (citations, warnings, unsupported-model memory) and cannot
    be imported here without a circular import."""
    text = ""
    usage: dict[str, Any] = {}
    errors: list[str] = []
    for line in (stdout or "").splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            ev = json.loads(line)
        except json.JSONDecodeError:
            continue
        if not isinstance(ev, dict):
            continue
        if ev.get("type") == "item.completed" and isinstance(ev.get("item"), dict):
            item = ev["item"]
            if item.get("type") == "agent_message":
                text = str(item.get("text") or "")
        elif ev.get("type") == "turn.completed":
            usage = ev.get("usage") or {}
        elif ev.get("type") in ("turn.failed", "error"):
            err = ev.get("error")
            msg = err.get("message") if isinstance(err, dict) else ev.get("message")
            errors.append(str(msg or "")[:400])
    return {"text": text, "usage": usage, "errors": errors}


# ── tier 1: the subscription ─────────────────────────────────────────────────
Runner = Callable[..., subprocess.CompletedProcess]


# codex's structured output is ALWAYS a JSON object matching --output-schema, so a
# caller that wants free text (the credit judge, doc-verify claim extraction: both
# call with schema=None) must be given a wrapper it can be unwrapped out of. Without
# this the helper receives an empty object schema and strict mode can only produce
# {}, which every one of those callers would have to treat as an unusable answer -
# i.e. every no-schema call would silently fall through to paid inference.
TEXT_WRAPPER = {"type": "object", "additionalProperties": False,
                "required": ["text"], "properties": {"text": {"type": "string"}}}


def unwrap_text(value: Any, raw: str) -> str:
    """The raw text for a no-schema call: the wrapper's field, or the raw output."""
    if isinstance(value, dict) and set(value) == {"text"} and isinstance(value["text"], str):
        return value["text"]
    return raw


def strict_schema(node: Any) -> Any:
    """Rewrite a JSON schema for OpenAI STRICT structured output, which codex's
    ``--output-schema`` uses (``text.format.schema`` with ``strict: true``).

    Measured on node-8, 2026-11-03, the FIRST live tier-1 call:
    ``400 invalid_json_schema: 'schema.additionalProperties' is required to be
    supplied and to be false when strict is true``. Strict mode also requires
    every declared property to appear in ``required``. A fake runner cannot see
    this, and a schema the backend rejects turns tier 1 into a permanent 400 —
    i.e. it silently pushes the whole user path onto the metered tier. So the
    schema is normalized here, once, for every caller.

    Only object nodes are touched; ``$ref``/``anyOf``/arrays are walked but not
    rewritten, and the caller's own answer validation is unchanged.
    """
    if isinstance(node, list):
        return [strict_schema(x) for x in node]
    if not isinstance(node, dict):
        return node
    out = {k: strict_schema(v) for k, v in node.items()}
    props = out.get("properties")
    if out.get("type") == "object" or isinstance(props, dict):
        # FORCED, not defaulted: strict mode rejects true as well as a missing key.
        out["additionalProperties"] = False
        if isinstance(props, dict) and props:
            out["required"] = list(props.keys())
        if "type" not in out:
            out["type"] = "object"
    return out


def call_subscription(prompt: str, *, schema: dict[str, Any] | None = None, web: bool = False,
                      images: Sequence[str] = (), model: str | None = None,
                      timeout_s: int = SUBSCRIPTION_TIMEOUT_S, runner: Runner | None = None,
                      helper: Path | None = None) -> TierAttempt:
    """ONE tool-less call on the ChatGPT subscription, through the audited
    ``codex-judge-exec.sh`` (credential safety, sandbox, tool census all live
    there — this function only speaks its CLI)."""
    model = model or SUBSCRIPTION_MODEL
    if web:
        return TierAttempt(TIER_SUBSCRIPTION, "skipped", model=model, kind=UNAVAILABLE,
                           reason="web_search_unavailable",
                           meta={"why": "codex-cli 0.156.1 searches only through Code Mode's exec host (T01 spike)"})
    run = runner or subprocess.run
    helper = Path(helper or CODEX_HELPER)
    if not helper.exists():
        return TierAttempt(TIER_SUBSCRIPTION, "skipped", model=model, kind=UNAVAILABLE,
                           reason=f"helper missing: {helper}")
    t0 = time.monotonic()
    with tempfile.TemporaryDirectory(prefix="model-chain-codex.") as td:
        schema_f = Path(td) / "schema.json"
        meta_f = Path(td) / "meta.json"
        schema_f.write_text(json.dumps(strict_schema(schema or TEXT_WRAPPER)), encoding="utf-8")
        argv = ["bash", str(helper), "--schema", str(schema_f), "--model", model, "--no-web",
                "--timeout", str(timeout_s), "--meta-out", str(meta_f)]
        for img in images:
            argv += ["--image", img]
        try:
            proc = run(argv, input=prompt, capture_output=True, text=True,
                       timeout=timeout_s + 90, check=False)
        except subprocess.TimeoutExpired:
            return TierAttempt(TIER_SUBSCRIPTION, "error", model=model, kind=TIMEOUT, reason="timeout",
                               latency_ms=int((time.monotonic() - t0) * 1000))
        latency = int((time.monotonic() - t0) * 1000)
        try:
            meta = json.loads(meta_f.read_text(encoding="utf-8")) if meta_f.exists() else {}
        except (OSError, json.JSONDecodeError):
            meta = {}
    meta = meta if isinstance(meta, dict) else {}
    meta.setdefault("helper_rc", proc.returncode)
    latency = int(meta.get("latency_ms") or latency)
    stderr = (proc.stderr or "")[-600:]
    rc = proc.returncode
    if rc == 3:  # the helper refused to call: quota / token expiry / kill switch
        meta_reason = "quota" if "reason=quota" in stderr else (
            "kill_switch" if "kill switch" in stderr else "unavailable")
        return TierAttempt(TIER_SUBSCRIPTION, "skipped", model=model,
                           kind=QUOTA if meta_reason == "quota" else UNAVAILABLE,
                           reason=meta_reason, latency_ms=latency, meta={**meta, "log": stderr[-300:]})
    if rc in (4, 9):  # tool / safety violation: the answer must never be used
        return TierAttempt(TIER_SUBSCRIPTION, "error", model=model, kind=UNSAFE,
                           reason="tool_violation" if rc == 4 else "safety_violation",
                           latency_ms=latency, meta=meta)
    ev = parse_codex_events(proc.stdout)
    if rc != 0:
        detail = (ev["errors"][-1] if ev["errors"] else stderr.strip().splitlines()[-1:][0] if stderr.strip()
                  else f"codex rc={rc}")
        kind = classify_text(detail) or (UNAVAILABLE if rc == 2 else SERVER_ERROR)
        return TierAttempt(TIER_SUBSCRIPTION, "error", model=model, kind=kind, reason=str(detail)[:300],
                           latency_ms=latency, meta=meta)
    att = TierAttempt(TIER_SUBSCRIPTION, "error", model=model, latency_ms=latency, meta=meta, cost_usd=0.0,
                      text=ev["text"], input_tokens=ev["usage"].get("input_tokens"),
                      output_tokens=ev["usage"].get("output_tokens"))
    if schema:
        try:
            att.json = parse_json_answer(ev["text"])
        except (ValueError, json.JSONDecodeError) as exc:
            att.kind, att.reason = BAD_ANSWER, f"unparseable answer: {exc}"[:200]
            return att
        problem = check_schema(att.json, schema)
        if problem:
            att.kind, att.reason = BAD_ANSWER, f"schema: {problem}"[:200]
            return att
    else:
        # No schema asked for: unwrap the transport wrapper so `text` is the
        # caller's answer, not the envelope it travelled in. An answer that is not
        # the wrapper at all is passed through unchanged (nothing to lose).
        try:
            att.json = parse_json_answer(ev["text"])
        except (ValueError, json.JSONDecodeError):
            att.json = None
        att.text = unwrap_text(att.json, ev["text"])
    if not (att.text or "").strip():
        # Nothing to serve: an empty completion (including a strict wrapper that
        # unwrapped to "") is a BAD ANSWER, not an answer, so the chain must go on
        # to the next tier (QA 2026-11-03). A structured reply is judged by its
        # schema above; only the text path can be empty here.
        att.kind, att.reason = BAD_ANSWER, "empty completion"
        return att
    att.outcome = "ok"
    return att


# ── tier 2: OpenRouter DeepSeek ──────────────────────────────────────────────
Opener = Callable[..., Any]


def call_deepseek(messages: Sequence[dict[str, Any]], *, schema: dict[str, Any] | None = None, web: bool = False,
                  web_max_results: int = 5, exclude_domains: Iterable[str] = (),
                  max_tokens: int = 4000, temperature: float = 0.0, timeout_s: int = FALLBACK_TIMEOUT_S,
                  sensitive: bool = True, model: str | None = None, key: str | None = None,
                  opener: Opener | None = None, frequency_penalty: float | None = None) -> TierAttempt:
    """ONE tool-less OpenRouter call on the fallback tier. ``sensitive`` adds
    ``data_collection: deny``: every caller of this helper feeds it user
    material (claims, documents, support text)."""
    model = model or FALLBACK_MODEL
    body: dict[str, Any] = {"model": model, "messages": list(messages), "temperature": temperature,
                            "max_tokens": max_tokens, "usage": {"include": True}}
    if schema:
        body["response_format"] = {"type": "json_object"}
    if frequency_penalty:
        # A retry must actually CHANGE the request: re-sending the identical prompt
        # to a model that looped to the cap just loops again (QA 2026-11-03).
        body["frequency_penalty"] = float(frequency_penalty)
    if web:
        plugin: dict[str, Any] = {"id": "web", "max_results": web_max_results}
        excluded = [d for d in dict.fromkeys(exclude_domains) if d]
        if excluded:  # xAI native search accepts at most 5 excluded domains
            plugin["exclude_domains"] = excluded[:5]
        body["plugins"] = [plugin]
    if sensitive:
        body["provider"] = {"data_collection": "deny"}
    api_key = key or load_key()
    if not api_key:
        return TierAttempt(TIER_FALLBACK, "skipped", model=model, kind=UNAVAILABLE, reason="no OpenRouter key")
    req = urllib.request.Request(
        OPENROUTER_URL, data=json.dumps(body).encode(),
        headers={"Authorization": f"Bearer {api_key}", "Content-Type": "application/json",
                 "HTTP-Referer": "https://muso.ai", "X-Title": "hydra model-chain"},
    )
    open_fn = opener or urllib.request.urlopen
    t0 = time.monotonic()
    try:
        with open_fn(req, timeout=timeout_s) as resp:
            data = json.load(resp)
    except urllib.error.HTTPError as exc:
        try:
            detail = exc.read()[:300].decode("utf-8", "replace")
        except Exception:  # noqa: BLE001 - a body we cannot read is still a status
            detail = ""
        return TierAttempt(TIER_FALLBACK, "error", model=model, kind=classify_http(exc.code, detail),
                           reason=f"http {exc.code}: {detail}"[:300],
                           latency_ms=int((time.monotonic() - t0) * 1000))
    except (urllib.error.URLError, TimeoutError, OSError, ValueError) as exc:
        kind = TIMEOUT if isinstance(exc, TimeoutError) else (classify_text(str(exc)) or UNAVAILABLE)
        return TierAttempt(TIER_FALLBACK, "error", model=model, kind=kind, reason=f"transport: {exc}"[:300],
                           latency_ms=int((time.monotonic() - t0) * 1000))
    latency = int((time.monotonic() - t0) * 1000)
    usage = data.get("usage") or {}
    choices = data.get("choices") if isinstance(data.get("choices"), list) else []
    choice = choices[0] if choices and isinstance(choices[0], dict) else {}
    msg = choice.get("message") if isinstance(choice.get("message"), dict) else {}
    text = str(msg.get("content") or "")
    citations = [((a.get("url_citation") or {}).get("url") or "")
                 for a in (msg.get("annotations") or []) if isinstance(a, dict)]
    reported = data.get("model") if isinstance(data.get("model"), str) else None
    att = TierAttempt(TIER_FALLBACK, "error", model=reported or model, latency_ms=latency, text=text,
                      citations=[u for u in citations if u],
                      cost_usd=usage.get("cost") if isinstance(usage.get("cost"), (int, float)) else None,
                      input_tokens=usage.get("prompt_tokens"), output_tokens=usage.get("completion_tokens"),
                      meta={"finish_reason": choice.get("finish_reason"), "web": bool(web),
                            # What the PROVIDER said it ran, or None when it said
                            # nothing. `att.model` falls back to the requested id for
                            # the audit label, so a caller that needs provenance (the
                            # doc-verify cache) must never read that fallback as a
                            # report (QA 2026-11-03).
                            "model_reported": reported})
    if not text.strip():
        att.kind, att.reason = BAD_ANSWER, "empty completion"
        return att
    if choice.get("finish_reason") == "length":
        # A capped answer is never accepted: it may have lost fields.
        att.kind, att.reason = BAD_ANSWER, "answer truncated (finish_reason: length)"
        return att
    if schema:
        try:
            att.json = parse_json_answer(text)
        except (ValueError, json.JSONDecodeError) as exc:
            att.kind, att.reason = BAD_ANSWER, f"unparseable answer: {exc}"[:200]
            return att
        problem = check_schema(att.json, schema)
        if problem:
            att.kind, att.reason = BAD_ANSWER, f"schema: {problem}"[:200]
            return att
    att.outcome = "ok"
    return att


# ── the chain ────────────────────────────────────────────────────────────────
def _messages(prompt: str | None, messages: Sequence[dict[str, Any]] | None
              ) -> list[dict[str, Any]]:
    """Accept either a prompt string or a message list, positionally or by
    keyword. A list passed as the FIRST positional argument is a message list,
    not a prompt — callers write both, and hashing a list is a crash."""
    if messages is None and prompt is not None and not isinstance(prompt, str):
        return list(prompt)
    return list(messages) if messages is not None else [{"role": "user", "content": prompt or ""}]


class ModelChain:
    """Walk the tiers in order and serve the first usable answer.

    ``surface`` names the user-request path in every log line and ledger row
    (``credit-decide``, ``doc-verify``, ``credit-trust``, ...), so the hourly
    watchdog can attribute a fallback share to the path that caused it.
    """

    def __init__(self, surface: str, *, tiers: Sequence[str] = TIERS, ledger: UsageLedger | None = None,
                 retries: int = DEFAULT_RETRIES, backoff_s: Sequence[float] = BACKOFF_S,
                 daily_usd_cap: float = DAILY_USD_CAP, subscription_runner: Runner | None = None,
                 opener: Opener | None = None, sleep: Callable[[float], None] = time.sleep,
                 log: Callable[[str], None] | None = None, subscription_model: str | None = None,
                 fallback_model: str | None = None, codex_helper: Path | None = None,
                 key: str | None = None):
        unknown = [t for t in tiers if t not in TIERS]
        if unknown or not tiers:
            raise ValueError(f"unknown tier(s) {unknown}; choose from {TIERS}")
        self.surface = surface
        self.tiers = tuple(tiers)
        self.ledger = ledger if ledger is not None else UsageLedger()
        self.retries = max(1, int(retries))
        self.backoff_s = tuple(backoff_s) or (0.0,)
        self.daily_usd_cap = float(daily_usd_cap)
        self.subscription_model = subscription_model or SUBSCRIPTION_MODEL
        self.fallback_model = fallback_model or FALLBACK_MODEL
        self._subscription_runner = subscription_runner
        self._opener = opener
        self._sleep = sleep
        self._log = log or (lambda line: print(line, file=sys.stderr, flush=True))
        self._codex_helper = codex_helper
        self._key = key

    # ── public ──────────────────────────────────────────────────────────────
    def call(self, prompt: str | None = None, *, messages: Sequence[dict[str, Any]] | None = None,
             schema: dict[str, Any] | None = None, images: Sequence[str] = (), web: bool = False,
             max_tokens: int = 4000, temperature: float = 0.0, timeout_s: int | None = None,
             sensitive: bool = True, step: str = "call", exclude_domains: Iterable[str] = (),
             web_max_results: int = 5, record_exhausted: bool = True,
             defer_served_row: bool = False, frequency_penalty: float | None = None) -> ChainResult:
        """Walk the configured tiers in order and return the first answer.

        ``defer_served_row=True`` leaves writing the success row to the caller
        (``record_served()``), for a caller whose answer is only SERVED once it has
        validated it. Without it, an unusable free answer was counted as a
        subscription success and masked the fallback share (QA 2026-11-03).

        ``record_exhausted=False`` is for a caller that runs its OWN ladder around
        this call (doc-verify asks the subscription here, then the metered tier
        later): exhaustion is only terminal at the END of that ladder, so recording
        it mid-ladder would page the watchdog for a request that was served."""
        msgs = _messages(prompt, messages)
        prompt_text = prompt if isinstance(prompt, str) else messages_text(msgs)
        res = ChainResult(ok=False, prompt_sha256=sha256_text(prompt_text))
        # A subscription tier that cannot do the REQUEST (no headless web search)
        # is a capability decision, not an outage: everything it hands down is
        # marked so no alarm reads an expected fallback as a dead subscription.
        capability = False
        for tier in self.tiers:
            attempt_no = 0
            while True:
                attempt_no += 1
                att = self._attempt(tier, prompt_text, msgs, schema=schema, images=images, web=web,
                                    max_tokens=max_tokens, temperature=temperature, timeout_s=timeout_s,
                                    sensitive=sensitive, exclude_domains=exclude_domains,
                                    web_max_results=web_max_results, step=step, capability=capability,
                                    frequency_penalty=frequency_penalty)
                if att.outcome == "skipped" and att.reason in CAPABILITY_SKIPS:
                    capability = True
                self._record(att, res.prompt_sha256, step, attempt_no, capability=capability,
                             defer_ok=defer_served_row)
                res.finish_reason = (att.meta or {}).get("finish_reason")
                res.model_reported = (att.meta or {}).get("model_reported")
                res.attempts.append({"tier": att.tier, "model": att.model, "outcome": att.outcome,
                                     "kind": att.kind, "reason": att.reason, "attempt": attempt_no})
                if att.outcome == "ok":
                    res.ok, res.tier, res.model = True, att.tier, att.model
                    res.text, res.json, res.citations = att.text, att.json, att.citations
                    res.cost_usd, res.latency_ms = att.cost_usd, att.latency_ms or 0
                    res.input_tokens, res.output_tokens = att.input_tokens, att.output_tokens
                    return res
                if att.kind in ABORT_CHAIN:
                    res.error = f"{att.tier}: {att.reason}"
                    res.error_kind = att.kind
                    self._log(f"[model-chain] surface={self.surface} step={step} tier={att.tier} "
                              f"outcome=aborted kind={att.kind} reason={att.reason}")
                    return res
                if att.outcome == "error" and att.kind in RETRY_SAME_TIER and attempt_no < self.retries:
                    self._sleep(self._backoff(attempt_no))
                    continue
                break
        # Name the reason, not just the class: "no OpenRouter key" and "daily cap
        # reached" are the same kind (unavailable) and need different fixes.
        res.error = "chain exhausted: " + ", ".join(
            f"{a['tier']}={a['kind'] or a['outcome']}"
            + (f" ({a['reason']})" if a.get("reason") and a["reason"] != a.get("kind") else "")
            for a in res.attempts)
        res.error_kind = CHAIN_EXHAUSTED
        detail = ",".join("%s=%s" % (a["tier"], a["kind"] or a["outcome"]) for a in res.attempts)
        if record_exhausted:
            # Terminal ONLY when this chain WAS the caller's whole path. A caller
            # that runs its own ladder (doc-verify: free tier, then paid) records
            # `chain_exhausted` at the end of that ladder, not in the middle of it
            # - otherwise a served request pages as a dead chain (QA 2026-11-03).
            self.ledger.record({"surface": self.surface, "step": step, "tier": "none",
                                "outcome": CHAIN_EXHAUSTED, "kind": CHAIN_EXHAUSTED,
                                "prompt_sha256": res.prompt_sha256, "attempts": res.attempts})
            self._log(f"[model-chain] surface={self.surface} step={step} outcome=chain_exhausted attempts={detail}")
        return res

    def call_fallback(self, prompt: str | None = None, *, messages: Sequence[dict[str, Any]] | None = None,
                      schema: dict[str, Any] | None = None, images: Sequence[str] = (), web: bool = False,
                      max_tokens: int = 4000, temperature: float = 0.0, timeout_s: int | None = None,
                      sensitive: bool = True, step: str = "call", exclude_domains: Iterable[str] = (),
                      web_max_results: int = 5, record_exhausted: bool = True,
                      frequency_penalty: float | None = None) -> ChainResult:
        """The METERED tier only — for a caller that runs its OWN tier-1 ladder
        (``credit_trust``: codex → jev) and reaches here having already decided
        tier 1 declined. Same ``$`` cap, same ledger row, same log line, so a
        fallback that happens on that ladder is as visible and as bounded as one
        that happens inside :meth:`call`. Never touches the subscription."""
        msgs = _messages(prompt, messages)
        prompt_text = prompt if isinstance(prompt, str) else messages_text(msgs)
        res = ChainResult(ok=False, prompt_sha256=sha256_text(prompt_text))
        attempt_no = 0
        while True:
            attempt_no += 1
            att = self._attempt(TIER_FALLBACK, prompt_text, msgs, schema=schema, images=images, web=web,
                                max_tokens=max_tokens, temperature=temperature, timeout_s=timeout_s,
                                sensitive=sensitive, exclude_domains=exclude_domains,
                                web_max_results=web_max_results, step=step,
                                frequency_penalty=frequency_penalty)
            self._record(att, res.prompt_sha256, step, attempt_no)
            res.finish_reason = (att.meta or {}).get("finish_reason")
            res.model_reported = (att.meta or {}).get("model_reported")
            res.attempts.append({"tier": att.tier, "model": att.model, "outcome": att.outcome,
                                 "kind": att.kind, "reason": att.reason, "attempt": attempt_no})
            if att.outcome == "ok":
                res.ok, res.tier, res.model = True, att.tier, att.model
                res.text, res.json, res.citations = att.text, att.json, att.citations
                res.cost_usd, res.latency_ms = att.cost_usd, att.latency_ms or 0
                res.input_tokens, res.output_tokens = att.input_tokens, att.output_tokens
                return res
            if att.kind in ABORT_CHAIN:
                res.error, res.error_kind = f"{att.tier}: {att.reason}", att.kind
                return res
            if att.outcome == "error" and att.kind in RETRY_SAME_TIER and attempt_no < self.retries:
                self._sleep(self._backoff(attempt_no))
                continue
            break
        res.error = f"{TIER_FALLBACK}: {res.attempts[-1]['kind'] or res.attempts[-1]['outcome']}" \
                    + (f" ({res.attempts[-1]['reason']})" if res.attempts[-1].get("reason") else "")
        res.error_kind = res.attempts[-1]["kind"] or UNAVAILABLE
        if res.error_kind not in ABORT_CHAIN and record_exhausted:
            # `callers that reach this rung have nothing after it` (credit-trust's
            # ladder, doc-verify after its free tier), so a failure here IS the
            # end of the user path - and the watchdog's immediate alarm must see it
            # (QA 2026-11-03). An `unsafe` abort is deliberately not exhaustion, and
            # a caller with its OWN recovery (doc-verify's chunk/retry on a truncated
            # answer) passes record_exhausted=False and writes the marker itself only
            # when that recovery gave nothing.
            self.ledger.record({"surface": self.surface, "step": step, "tier": "none",
                                "outcome": CHAIN_EXHAUSTED, "kind": CHAIN_EXHAUSTED,
                                "prompt_sha256": res.prompt_sha256, "attempts": res.attempts})
            self._log(f"[model-chain] surface={self.surface} step={step} outcome=chain_exhausted "
                      f"tier={TIER_FALLBACK} attempts={len(res.attempts)}")
        return res

    # ── internals ───────────────────────────────────────────────────────────
    def _backoff(self, attempt_no: int) -> float:
        return self.backoff_s[min(attempt_no - 1, len(self.backoff_s) - 1)]

    def _attempt(self, tier: str, prompt_text: str, msgs: Sequence[dict[str, Any]], **kw: Any) -> TierAttempt:
        if tier == TIER_SUBSCRIPTION:
            return call_subscription(prompt_text, schema=kw["schema"], web=kw["web"], images=kw["images"],
                                     model=self.subscription_model,
                                     timeout_s=kw["timeout_s"] or SUBSCRIPTION_TIMEOUT_S,
                                     runner=self._subscription_runner, helper=self._codex_helper)
        # The reservation is this REQUEST's ceiling, not a flat guess: reserving a
        # flat $0.05 let a call admitted at $9.95 settle at $10.05, so the "hard
        # $10/day" was only a floor (QA 2026-11-03).
        estimate = estimate_upper_usd(
            self.fallback_model, prompt_text, max_tokens=kw["max_tokens"],
            web_results=kw["web_max_results"] if kw["web"] else 0)
        if estimate is None:
            return TierAttempt(TIER_FALLBACK, "skipped", model=self.fallback_model, kind=UNAVAILABLE,
                               reason=(f"unpriced model {self.fallback_model}: it has no ceiling in "
                                       "PRICE_USD_PER_TOKEN, so no reservation could bound it against "
                                       "MODEL_CHAIN_DAILY_USD (add the price, or set "
                                       "MODEL_CHAIN_UNPRICED_MAX_USD)"))
        reserve = max(RESERVATION_USD, estimate)
        # Check-and-reserve is ONE atomic step (UsageLedger.admit): the cap is a
        # ceiling the reservation must fit under, an unreadable ledger fails CLOSED
        # here ("I could not read it" is not "we spent $0"), and two processes can no
        # longer both read the same below-cap total. `cap <= 0` is UNLIMITED, and
        # admit() still writes the reservation row - otherwise _record() would
        # settle a reservation nobody made and the day's total goes negative, which
        # a later re-enabled cap would read as free headroom (QA 2026-11-03).
        refusal = self.ledger.admit(self.daily_usd_cap, reserve,
                                    surface=self.surface, step=kw.get("step") or "call")
        if refusal:
            return TierAttempt(TIER_FALLBACK, "skipped", model=self.fallback_model, kind=UNAVAILABLE,
                               reason=refusal)
        att = call_deepseek(msgs, schema=kw["schema"], web=kw["web"], max_tokens=kw["max_tokens"],
                            web_max_results=kw["web_max_results"],
                            temperature=kw["temperature"],
                            timeout_s=kw["timeout_s"] or FALLBACK_TIMEOUT_S,
                            sensitive=kw["sensitive"], model=self.fallback_model,
                            exclude_domains=kw["exclude_domains"], opener=self._opener,
                            key=self._key, frequency_penalty=kw.get("frequency_penalty"))
        if att.cost_usd is None and _billable_row({"outcome": att.outcome, "kind": att.kind}):
            # No price in the response: book the ceiling and SAY it was estimated,
            # so the ledger carries a number the cap can add up. `bad_answer` counts
            # too: a truncated or unusable completion was still billed by the
            # provider, and an unrecorded charge would let the day's cap never bind
            # (QA 2026-11-03). A `skipped` attempt never reached the provider.
            att.cost_usd = reserve
            att.meta = {**(att.meta or {}), "cost_estimated": True}
        # The reservation is released in _record(), AFTER this attempt's charge row
        # is durable: releasing here left a window where the day read $9.95 while a
        # $0.05 charge was already spent, so a second process could reserve and both
        # would settle past the cap (QA 2026-11-03). Carrying it on the attempt keeps
        # that ordering per attempt, so concurrent calls on one chain (credit-review
        # reuses its Judge across threads) cannot cross wires.
        att.meta = {**(att.meta or {}), "_reserve_usd": reserve}
        return att

    def _release(self, reserved: float | None, actual: float | None, step: str) -> None:
        """Release a reservation ONLY after the attempt's charge row is durable, so
        the ledger's running total never dips below what was actually spent."""
        if reserved is not None:
            self.ledger.settle(float(reserved), actual, surface=self.surface, step=step)

    def _record(self, att: TierAttempt, prompt_sha: str, step: str, attempt_no: int,
                *, capability: bool = False, defer_ok: bool = False) -> None:
        meta = dict(att.meta or {})
        reserved = meta.pop("_reserve_usd", None)
        if defer_ok and att.outcome == "ok":
            # The caller decides whether this answer was usable; a success row it
            # never confirms would inflate the subscription denominator.
            self._release(reserved, att.cost_usd, step)
            self._log(f"[model-chain] surface={self.surface} step={step} tier={att.tier} "
                      f"model={att.model} outcome=ok attempt={attempt_no} latency_ms="
                      f"{att.latency_ms or 0} served_row=deferred")
            return
        self.ledger.record({
            "surface": self.surface, "step": step, "tier": att.tier, "model": att.model,
            "outcome": att.outcome, "kind": att.kind, "reason": att.reason,
            "prompt_sha256": prompt_sha, "attempt": attempt_no,
            "input_tokens": att.input_tokens, "output_tokens": att.output_tokens,
            "cost_usd": att.cost_usd, "latency_ms": att.latency_ms,
            "citations": len(att.citations or []), "meta": meta or None,
            **({"capability": True} if capability else {}),
        })
        self._release(reserved, att.cost_usd, step)
        self._log(f"[model-chain] surface={self.surface} step={step} tier={att.tier} model={att.model} "
                  f"outcome={att.outcome} attempt={attempt_no} latency_ms={att.latency_ms or 0}"
                  + (f" kind={att.kind} reason={att.reason}" if att.outcome != "ok" else ""))


# ── reporting helpers (the watchdog and the canary read these) ───────────────
def record_chain_exhausted(surface: str, *, step: str, reason: str | None = None,
                           prompt_sha256: str = "", attempts: list[dict[str, Any]] | None = None) -> None:
    """Mark "this USER PATH got no answer" - for a caller whose own ladder (with its
    own recovery) ended without a usable result. Best-effort: a watchdog signal must
    never turn a served request into a failure."""
    try:
        UsageLedger().record({"surface": surface, "step": step, "tier": "none",
                              "outcome": CHAIN_EXHAUSTED, "kind": CHAIN_EXHAUSTED,
                              "reason": reason, "prompt_sha256": prompt_sha256,
                              "attempts": attempts or []})
    except (OSError, ValueError, AccountingUnavailable):
        pass


def estimate_upper_usd(model: str, prompt_text: str, *, max_tokens: int,
                       web_results: int = 0) -> float | None:
    """The most this request can cost, by construction: a prompt has at least one
    character per token, the answer cannot exceed ``max_tokens``, and each web
    result carries a fixed fee. Used as the reservation so ``admit()`` bounds the
    day instead of hoping each call is cheap (QA 2026-11-03).

    ``None`` means "this model has no price ceiling here", which the metered tier
    treats as a refusal: pricing an unpriced (usually frontier) model at the cheap
    fallback's rate is how the daily cap stops being a cap."""
    if model not in PRICE_USD_PER_TOKEN:
        full = UNPRICED_MAX_USD * (1 + max(0, int(web_results)))
        return full if full > 0 else None
    price_in, price_out = PRICE_USD_PER_TOKEN[model]
    return (price_in * len(prompt_text or "") + price_out * max(0, int(max_tokens))
            + WEB_FEE_USD_PER_RESULT.get(model, 0.01) * max(0, int(web_results)))


def record_served(surface: str, *, tier: str, step: str, model: str | None = None,
                  latency_ms: int | None = None, cost_usd: float | None = None) -> None:
    """Record a call that a caller served WITHOUT walking this chain, so the
    watchdog's denominator sees it.

    The subscription share is "how much of the user path ran on the subscription",
    so the subscription's own successes have to be in the ledger even when the
    caller's transport is its own (``credit_trust``'s codex rung writes its SQLite
    audit rows and, before this, no JSONL row - so 1,000 free successes plus 5
    paid fallbacks read as 100% fallback; QA 2026-11-03).

    Best-effort and never raises: bookkeeping must not fail a user request, and a
    missing row can only make the share read WORSE (more pressure), never better.
    """
    try:
        UsageLedger().record({"surface": surface, "step": step, "tier": tier, "outcome": "ok",
                              "model": model, "latency_ms": latency_ms,
                              "cost_usd": 0.0 if cost_usd is None else cost_usd})
    except (OSError, ValueError, AccountingUnavailable):
        pass


def tier_counts(rows: Iterable[dict[str, Any]]) -> dict[str, int]:
    """Served calls per tier, plus the rows that mean 'we could not answer'.

    A row marked ``capability`` is a fallback the SUBSCRIPTION CANNOT DO AT ALL
    (headless web search on the vendored codex-cli), not a failure: it is counted
    in its own bucket so it can never read as an outage (QA 2026-11-03)."""
    counts = {TIER_SUBSCRIPTION: 0, TIER_FALLBACK: 0, CHAIN_EXHAUSTED: 0, "capability": 0}
    for row in rows:
        if row.get("outcome") == "ok":
            if row.get("capability"):
                counts["capability"] += 1
                continue
            tier = str(row.get("tier") or "")
            if tier in counts:
                counts[tier] += 1
        elif row.get("outcome") == CHAIN_EXHAUSTED and not row.get("capability"):
            counts[CHAIN_EXHAUSTED] += 1
    counts["served"] = counts[TIER_SUBSCRIPTION] + counts[TIER_FALLBACK]
    return counts


def fallback_share(rows: Iterable[dict[str, Any]]) -> tuple[float, int]:
    """(share, denominator) of user-path calls that did NOT run on the
    subscription, counting a chain that ran out of tiers as fallback pressure
    (nobody answered). Zero denominator returns 0.0 — an idle hour is not a
    breach, and it is not evidence of health either (the watchdog says so)."""
    c = tier_counts(rows)
    denom = c["served"] + c[CHAIN_EXHAUSTED]
    if denom == 0:
        return 0.0, 0
    return (c[TIER_FALLBACK] + c[CHAIN_EXHAUSTED]) / denom, denom
