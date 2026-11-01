"""batch-judge: the per-batch read of rendered outbound bodies, as ONE tool-less model call (Fable [key=scale-now-openclaw],
consolidated final 204).

STOP-ONLY. The judge reads COPY + CONSISTENCY only - every body against the approved copy ref and the barred list,
number agreement, facts <-> body <-> first-hits - never a credit fact. The coded gates make a batch sendable; this
judge can only stop it ('pass' means "no stop found", never "approved").

What p1 + r5 did by hand per outbound batch - read the rendered bodies against the facts, the copy ref, the barred
phrases and the class rules - becomes one judge-only call on node-8:

  * the call goes through ``credit_trust.llm.Provider`` (Codex on the subscription via codex-judge-exec.sh, tool-less,
    an append-only ``llm_calls`` row with the prompt sha256). NEVER an OpenClaw agent turn (AGENTS.md);
  * the metered OpenRouter fallback runs only when the $0 ladder served nothing, and only through
    ``credit_review.decide.CappedJudge`` (the single owner of the per-run and $25/day caps);
  * the judge APPROVES NOTHING and writes nothing outside the llm ledger: this module has no core, admin or Intercom
    path. Its verdict is the batch's signature of record; the tick (#1541, h2) applies only on ``may_apply``.

Fail closed, everywhere -> the batch verdict is 'stop' (NO APPLY): a call that failed, timed out, was cut off
(finish=length) or did not parse; a model outside ALLOWED_MODELS; an answer for another batch sha; an input body that
is empty, carries a duplicate id or the section markers; a body missing from the answer, duplicated or unknown; any body or batch verdict
other than 'pass' (``UNKNOWN = stop``). A fallback-model pass on the FIRST batch of a class is not enough: that
batch keeps r5's hand signature (``may_apply(first_of_class=True)``). The instructions (facts row + copy ref + barred list + class rules, one verdict per body) are b1's;
this module builds the ID-bound rendered-body section itself (render_prompt) and owns the call path, the verdict
contract and the rail predicate.

Verdict schema (one answer per batch):
  {"batch_sha": "<the sha in the prompt>", "verdict": "pass"|"stop",
   "bodies": [{"id": "<body id>", "verdict": "pass"|"stop", "reason_code": "<short code>", "evidence_quote": "..."}]}
"""
from __future__ import annotations

import hashlib
import json
from dataclasses import asdict, dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterable

from credit_trust import llm

STEP = "batch_judge"
# Constants, never env (the [key=unattended] bar): the only models whose answer can sign a batch.
CODEX_MODEL = "gpt-6.1-sol"
CODEX_FALLBACK_MODEL = "gpt-6-sol"
OPENROUTER_MODEL = "x-ai/grok-4.3"
ALLOWED_MODELS = frozenset({CODEX_MODEL, CODEX_FALLBACK_MODEL, OPENROUTER_MODEL})
CUT_OFF = ("length", "max_tokens", "max_output_tokens", "incomplete")
APPROVAL_REF = "scale-now-openclaw"
VERDICTS = ("pass", "stop")

VERDICT_SCHEMA: dict[str, Any] = {
    "type": "object",
    "additionalProperties": False,
    "required": ["batch_sha", "verdict", "bodies"],
    "properties": {
        "batch_sha": {"type": "string"},
        "verdict": {"type": "string", "enum": list(VERDICTS)},
        "bodies": {"type": "array", "items": {
            "type": "object", "additionalProperties": False,
            "required": ["id", "verdict", "reason_code", "evidence_quote"],
            "properties": {"id": {"type": "string"}, "verdict": {"type": "string", "enum": list(VERDICTS)},
                           "reason_code": {"type": "string"}, "evidence_quote": {"type": "string"}}}},
    },
}


def _code_sha() -> str:
    """sha256[:12] of this module + llm.py: which judge code produced a verdict (the signature's judge sha)."""
    h = hashlib.sha256()
    for p in (Path(__file__), Path(llm.__file__)):
        h.update(p.read_bytes())
    return h.hexdigest()[:12]


JUDGE_SHA = _code_sha()


def batch_sha(bodies: Iterable[dict[str, Any]], facts: Any, copy_ref: str, barred: Iterable[str],
              rules: Any) -> str:
    """The batch's identity: canonical sha256 over exactly what is judged (bodies by id, facts, copy ref, barred
    phrases, class rules). The tick computes it before the call and checks it again before the apply."""
    doc = {"bodies": sorted(({"id": str(b["id"]), "body": str(b["body"])} for b in bodies), key=lambda b: b["id"]),
           "facts": facts, "copy_ref": copy_ref, "barred": sorted(str(x) for x in barred), "rules": rules}
    return hashlib.sha256(json.dumps(doc, sort_keys=True, separators=(",", ":"), default=str).encode()).hexdigest()


@dataclass
class BodyVerdict:
    id: str
    verdict: str
    reason_code: str
    evidence_quote: str = ""


@dataclass
class BatchVerdict:
    batch_sha: str
    verdict: str                                   # pass | stop (fail closed)
    reasons: list[str] = field(default_factory=list)
    bodies: list[BodyVerdict] = field(default_factory=list)
    stop_ids: list[str] = field(default_factory=list)
    provider: str | None = None
    model: str | None = None
    prompt_sha256: str = ""
    schema_sha256: str | None = None
    llm_call_id: int | None = None
    cost_usd: float | None = None
    judge_sha: str = JUDGE_SHA
    fallback_model: bool = False
    at: str = ""

    def signature_row(self) -> dict[str, Any]:
        """The row the tick writes to its batch_verdicts table (h2): the batch's signature of record."""
        d = asdict(self)
        d["bodies"] = [asdict(b) for b in self.bodies]
        d["approved_by"] = f"{'openrouter' if self.fallback_model else 'codex'}-judge/{self.judge_sha}"
        d["approval_ref"] = APPROVAL_REF
        return d


def normalize(answer: Any, *, batch: str, body_ids: Iterable[str]) -> tuple[str, list[str], list[BodyVerdict]]:
    """(verdict, reasons, per-body rows) from the model's answer. 'pass' only when the answer is for THIS batch,
    names every body exactly once and nothing else, and every body AND the batch say 'pass'."""
    want = [str(i) for i in body_ids]
    reasons: list[str] = []
    rows: list[BodyVerdict] = []
    if not isinstance(answer, dict):
        return "stop", ["unparseable"], rows
    if answer.get("batch_sha") != batch:
        reasons.append("batch_sha_mismatch")
    seen: dict[str, int] = {}
    for b in answer.get("bodies") if isinstance(answer.get("bodies"), list) else []:
        if not isinstance(b, dict):
            reasons.append("body_row_unreadable")
            continue
        bid, v = str(b.get("id", "")), b.get("verdict")
        seen[bid] = seen.get(bid, 0) + 1
        rows.append(BodyVerdict(bid, v if v in VERDICTS else "stop",
                                str(b.get("reason_code") or ("unknown" if v not in VERDICTS else ""))[:80],
                                str(b.get("evidence_quote") or "")[:400]))
    missing = [i for i in want if i not in seen]
    extra = [i for i in seen if i not in want]
    dup = [i for i, n in seen.items() if n > 1]
    if not isinstance(answer.get("bodies"), list):
        reasons.append("bodies_missing")
    if missing:
        reasons.append(f"missing_bodies:{len(missing)}")
        rows += [BodyVerdict(i, "stop", "no_verdict") for i in missing]
    if extra:
        reasons.append(f"unknown_bodies:{len(extra)}")
    if dup:
        reasons.append(f"duplicate_bodies:{len(dup)}")
    if any(r.verdict != "pass" for r in rows):
        reasons.append("body_stop")
    if answer.get("verdict") != "pass":
        reasons.append("batch_stop" if answer.get("verdict") == "stop" else "batch_verdict_unknown")
    if not want:
        reasons.append("empty_batch")
    return ("stop" if reasons else "pass"), reasons, rows


def _cut_off(meta: Any) -> bool:
    if not isinstance(meta, dict):
        return False
    vals = [str(meta.get(k) or "").lower() for k in ("finish_reason", "stop_reason", "status", "incomplete_reason")]
    return any(v in CUT_OFF for v in vals)


BODY_OPEN = "<<<RENDERED BODY id="
BODY_CLOSE = "<<<END RENDERED BODY id="


def render_prompt(instructions: str, batch: str, bodies: list[dict[str, str]]) -> str:
    """The exact prompt the judge reads: b1's instructions (facts, copy ref, barred list, class rules), then the batch
    sha, then an ID-bound section holding EVERY rendered body - built HERE, so a body cannot be 'present' only as a
    stray substring of the facts (QA #1586)."""
    parts = [instructions.rstrip(), "", f"BATCH SHA: {batch}",
             f"RENDERED BODIES ({len(bodies)}; judge each one, answer one row per id):"]
    for b in bodies:
        parts += [f"{BODY_OPEN}{b['id']}>>>", b["body"], f"{BODY_CLOSE}{b['id']}>>>"]
    return "\n".join(parts) + "\n"


def default_provider() -> llm.Provider:
    """Codex only (Jev answers typed questions, it does not read bodies), on the constant models."""
    return llm.Provider(ladder=("codex",), codex_model=CODEX_MODEL, codex_fallback_model=CODEX_FALLBACK_MODEL)


def judge_batch(instructions: str, *, batch: str, bodies: Iterable[dict[str, Any]], provider: Any = None,
                fallback: Any = None, now: datetime | None = None) -> BatchVerdict:
    """ONE judge-only call for one outbound batch. ``instructions`` are b1's (facts, copy ref, barred list, class
    rules); this function appends the batch sha and the ID-bound section of EVERY rendered body (render_prompt), so
    the prompt sha in the verdict row covers exactly the bodies judged. ``fallback`` is an OpenRouterBatchJudge
    wrapped in ``credit_review.decide.CappedJudge``, used only when Codex served nothing. A model failure is a
    'stop', never a raise."""
    bl = [{"id": str(b["id"]), "body": str(b["body"])} for b in bodies]
    ids = [b["id"] for b in bl]
    at = (now or datetime.now(timezone.utc)).strftime("%Y-%m-%dT%H:%M:%SZ")
    v = BatchVerdict(batch_sha=batch, verdict="stop", at=at, schema_sha256=llm.schema_sha256(VERDICT_SCHEMA))
    dup_in = sorted({i for i in ids if ids.count(i) > 1})
    empty = [b["id"] for b in bl if not b["body"].strip() or not b["id"].strip()]
    forged = [b["id"] for b in bl if BODY_OPEN in b["body"] or BODY_CLOSE in b["body"] or ">>>" in b["id"]]
    pre_forged = BODY_OPEN in instructions or BODY_CLOSE in instructions
    bad_sha = not (isinstance(batch, str) and len(batch) == 64)
    if not ids or dup_in or empty or forged or pre_forged or bad_sha:
        v.reasons = ((["empty_batch"] if not ids else []) + ([f"duplicate_input_ids:{len(dup_in)}"] if dup_in else [])
                     + ([f"body_missing_from_input:{len(empty)}"] if empty else [])
                     + ([f"body_marker_in_input:{len(forged)}"] if forged else [])
                     + (["instructions_carry_body_markers"] if pre_forged else []) + (["bad_batch_sha"] if bad_sha else []))
        v.stop_ids = sorted(set(dup_in + empty + forged)) or ids
        return v
    prompt = render_prompt(instructions, batch, bl)
    v.prompt_sha256 = llm.prompt_sha256(prompt)
    answer: Any = None
    try:
        res = (provider or default_provider()).judge(prompt, VERDICT_SCHEMA, step=STEP)
    except Exception as exc:  # noqa: BLE001 - a failed call is a stop, never a pass
        res = llm.LLMResult(ok=False, error=f"{type(exc).__name__}: {exc}"[:200])
    if res.ok and _cut_off(res.meta):
        res = llm.LLMResult(ok=False, error="finish_length", provider=res.provider, model=res.model)
    if res.ok:
        v.provider, v.model, v.llm_call_id, v.cost_usd = res.provider, res.model, res.llm_call_id, res.cost_usd
        answer = res.json
    elif fallback is not None:
        try:
            j = fallback.judge(STEP, {"prompt": prompt, "schema": VERDICT_SCHEMA})
        except Exception as exc:  # noqa: BLE001
            j = None
            v.reasons.append(f"fallback_error:{type(exc).__name__}")
        if j is not None and getattr(j, "ok", False):
            v.provider, v.model, v.cost_usd = "openrouter", getattr(j, "model", None), getattr(j, "cost_usd", None)
            v.fallback_model = True
            try:
                answer = llm.parse_json_answer(getattr(j, "rationale", ""))
            except (ValueError, json.JSONDecodeError):
                answer = None
        elif j is not None:
            v.reasons.append(f"fallback_refused:{str(getattr(j, 'error', '') or '')[:80]}")
    if answer is None:
        v.reasons = [f"no_verdict:{(res.error or 'unparseable')[:120]}", *v.reasons]
        v.stop_ids = ids
        return v
    v.verdict, reasons, v.bodies = normalize(answer, batch=batch, body_ids=ids)
    v.reasons += reasons
    if v.model not in ALLOWED_MODELS:
        v.verdict = "stop"
        v.reasons.append(f"model_not_allowed:{v.model}")
    body_stops = sorted({b.id for b in v.bodies if b.verdict != "pass"})
    # a batch-level stop with no body named (wrong sha, a 'stop' batch verdict, a model off the list) stops them all
    v.stop_ids = body_stops or (ids if v.verdict != "pass" else [])
    return v


def may_apply(row: dict[str, Any] | None, batch: str, *, first_of_class: bool = False) -> bool:
    """The #1541 rail predicate (h2's tick calls it before any apply): True ONLY for a recorded verdict row for THIS
    batch sha, verdict 'pass', no stop ids, a model on ALLOWED_MODELS and this module's approval ref. A missing row, a
    'stop', an unknown verdict, another batch's row -> no apply. On the FIRST batch of a class a fallback-model pass
    is not a signature (r5 signs that batch by hand)."""
    return (isinstance(row, dict) and isinstance(batch, str) and len(batch) == 64 and row.get("batch_sha") == batch
            and row.get("verdict") == "pass" and row.get("approval_ref") == APPROVAL_REF
            and _id_list(row.get("stop_ids")) == [] and _id_list(row.get("reasons")) is not None
            and _allowed_model(row.get("model"))
            and not (first_of_class and row.get("fallback_model") is not False))


def _allowed_model(model: Any) -> bool:
    """Only a str on ALLOWED_MODELS; a list / dict / None is not allowed and never raises (frozenset membership hashes)."""
    return isinstance(model, str) and model in ALLOWED_MODELS


def _id_list(value: Any) -> list[str] | None:
    """A persisted list of ids/reasons, or None when it is not one (an int, a dict, nested lists): the caller holds."""
    if value is None:
        return []
    if not isinstance(value, list) or not all(isinstance(x, (str, int)) and not isinstance(x, bool) for x in value):
        return None
    return [str(x) for x in value]


# r5 + p1 judge rail FINAL for 29b (10-31 21:4xZ): per-BODY verdicts. A body-level stop holds only that body; these are
# the only reasons a per-body apply tolerates - anything else is a batch-level failure and holds every body.
PER_BODY_REASONS = frozenset({"body_stop", "batch_stop"})
WHOLE_HOLD_SHARE = 0.10                        # >= 10 % of the bodies stopped: a rule gap, the whole batch is hand-read


def applicable(row: dict[str, Any] | None, batch: str, body_ids: Iterable[str], *,
               first_of_class: bool = False) -> dict[str, Any]:
    """The per-body rail (replaces the whole-batch may_apply at the tick): {"apply": ids, "held": [...], "hold_whole": ""}.
    apply = exactly the ids THIS batch's verdict row marks pass, in input order. held = every stopped body with its
    reason code and quote (-> the hand-read tray, listed). hold_whole = why nothing applies: no/foreign/invalid row, a
    batch-level failure, a batch stop that names no body, or >= 10 % of the bodies stopped. Never a second call: a stopped
    body is not re-judged and neither is the remainder (a second sample of the same input biases toward pass)."""
    ids = [str(i) for i in body_ids]
    out: dict[str, Any] = {"apply": [], "held": [], "hold_whole": ""}

    def whole(why: str) -> dict[str, Any]:
        out["apply"], out["hold_whole"] = [], why
        return out

    if not ids:
        return whole("empty_batch")
    if not (isinstance(row, dict) and isinstance(batch, str) and len(batch) == 64 and row.get("batch_sha") == batch):
        return whole("no_verdict_for_this_batch")
    if row.get("approval_ref") != APPROVAL_REF or not _allowed_model(row.get("model")):
        return whole("verdict_not_a_signature")
    if first_of_class and row.get("fallback_model") is not False:
        return whole("first_of_class_fallback_model")          # r5 signs that batch by hand
    bodies = row.get("bodies") if isinstance(row.get("bodies"), list) else []
    by_id = {str(b.get("id")): b for b in bodies if isinstance(b, dict)}
    if len(bodies) != len(ids) or sorted(by_id) != sorted(ids):
        return whole("verdict_bodies_do_not_match_the_batch")
    reasons, raw_stop_ids = _id_list(row.get("reasons")), _id_list(row.get("stop_ids"))
    if reasons is None or raw_stop_ids is None:
        return whole("verdict_row_unreadable")                 # a malformed persisted row holds, never raises
    other = sorted(set(reasons) - PER_BODY_REASONS)
    if other:
        return whole("batch_level:" + ",".join(other)[:200])
    stop_ids = set(raw_stop_ids)
    if stop_ids - set(ids):
        return whole("stop_ids_not_in_batch")                  # QA #1597: an inconsistent stop signal applies nothing
    stopped = [i for i in ids if by_id[i].get("verdict") != "pass" or i in stop_ids]
    out["held"] = [{"id": i, "reason_code": str(by_id[i].get("reason_code") or "")[:80],
                    "evidence_quote": str(by_id[i].get("evidence_quote") or "")[:400]} for i in stopped]
    # QA #1597: a per-body apply needs every held body to carry the model's REAL reason and quote for the hand read; a
    # stop without them is an unexplained verdict - nothing applies (fail closed), the held list still names them
    if any(not h["reason_code"].strip() or not h["evidence_quote"].strip() for h in out["held"]):
        return whole("held_body_without_reason_or_quote")
    if row.get("verdict") != "pass" and not stopped:
        return whole("batch_stop_names_no_body")
    if stopped and len(stopped) >= WHOLE_HOLD_SHARE * len(ids):
        return whole(f"stopped_{len(stopped)}_of_{len(ids)}_at_or_above_10pct")
    out["apply"] = [i for i in ids if i not in set(stopped)]
    return out


class OpenRouterBatchJudge:
    """The metered fallback's inner judge (wrap it in CappedJudge): one chat call with the batch prompt, no web, JSON
    answer, cost from OpenRouter's usage. ``.judge(mode, evidence)`` matches CappedJudge's inner contract."""

    def __init__(self, *, timeout: int = 120, key: str | None = None):
        from credit_review import judge as cr_judge
        self._j = cr_judge.Judge(OPENROUTER_MODEL, web=False, timeout=timeout, key=key)
        self.model = self._j.model

    def judge(self, mode: str, evidence: dict[str, Any]) -> Any:
        from credit_review import judge as cr_judge
        res = cr_judge.JudgeResult(ok=False, model=self.model, provider="openrouter")
        body = {"model": self.model, "temperature": 0, "max_tokens": 6000, "usage": {"include": True},
                "response_format": {"type": "json_object"},
                "messages": [{"role": "system", "content": llm.DATA_RULE},
                             {"role": "user", "content": str(evidence.get("prompt") or "")}]}
        data = self._j._post(body, res)
        if data is None:
            return res
        usage = data.get("usage") or {}
        res.cost_usd = usage.get("cost") if isinstance(usage.get("cost"), (int, float)) else None
        try:
            choice = data["choices"][0]
            res.rationale = cr_judge.Judge._text(choice["message"])
        except (KeyError, IndexError, TypeError):
            res.error = "no choices in response"
            return res
        if str(choice.get("finish_reason") or "").lower() in CUT_OFF:
            res.error = "finish_length"
            return res
        res.ok = bool(res.rationale)
        return res
