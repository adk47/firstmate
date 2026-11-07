"""The suggested resolution is a LOOKUP, not a judgement.

`policies/ops-resolutions.json` maps (one intent label from a closed vocabulary) ∩ (one fact pattern
from a closed predicate vocabulary) -> exactly one action key. Rules are tried in file order and the
first one whose intents and `when` block both hold wins; NO rule matching is `unknown`, and
`unknown` is a hand-off, never an improvisation.

Two properties matter more than the rules themselves:

1. **An unknown fact never satisfies a predicate.** If the requests reader failed, `open_requests`
   is unknown, and a rule requiring `>0` does not fire — the card says `suggested: unknown`, which
   is the truth ("we did not measure it"), not a status line written over a guess.
2. **The lookup is closed.** An unknown intent label, predicate name, operator, action key or
   answer-bank line id is a POLICY ERROR (`PolicyError`), raised at load time. A silently ignored
   rule is a rule that never protects anyone, so the loader refuses instead.
"""
from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable, Iterable, Mapping

POLICY_PATH = Path(__file__).resolve().parents[2] / "policies" / "ops-resolutions.json"

# The closed predicate vocabulary. `fact` is the name in `facts.FACT_NAMES`; the operator is
# resolved to a function below. Nothing else can appear in a rule's `when` block.
PREDICATES: dict[str, Callable[[Any, Any], bool]] = {
    "account": lambda v, want: _account_matches(v, want),
    "open_requests": lambda v, want: _compare(len(v), want) if isinstance(v, list) else False,
    "request_status": lambda v, want: v == want,
    # `open_status` asks "is ANY open request in this status", which is the question the
    # single-sender rules actually mean. `request_status` collapses 2+ distinct statuses to
    # "mixed", so a rule written against it silently stops firing the moment a user has a
    # second open request - the double-send bug in a new place.
    "open_status": lambda v, want: isinstance(v, list) and want in v,
    "claims": lambda v, want: _compare(int(v), want) if isinstance(v, int) and not isinstance(v, bool) else False,
    "merges": lambda v, want: _compare(int(v), want) if isinstance(v, int) and not isinstance(v, bool) else False,
    "erasure": lambda v, want: (_erasure_state(v) == want),
    "proof_on_file": lambda v, want: isinstance(v, dict) and _yesno(v.get("proof_on_file")) == want,
    "dv_outcome": lambda v, want: isinstance(v, dict) and v.get("dv_outcome") == want,
    "subscription": lambda v, want: isinstance(v, dict) and v.get("status") == want,
    "tickets": lambda v, want: _compare(int(v), want) if isinstance(v, int) else False,
    "target_popular": lambda v, want: _yesno(v) == want,
}


class PolicyError(RuntimeError):
    """The policy file is not usable. Raised at load time, never swallowed into `unknown`."""


@dataclass(frozen=True)
class Action:
    key: str
    tier: str                 # W1 | W2 | handoff | human
    executes_here: bool
    handoff: str = ""
    line: str = ""            # answer-bank entry id, when the action posts copy
    requires_fact: str = ""   # "open_request" gates a bank line on a code-sourced fact
    inverse: str = ""
    describe: str = ""
    # `page` is the ONLY thing that makes a hand-off reach a human. Nothing on this surface can
    # reassign an Intercom conversation (the router's writers are empty by captain decision), so
    # a hand-off that does not page leaves the case sitting with the bot while the customer has
    # been told someone will follow up. `refuse` marks an ask that must not produce a customer
    # reply at all - a requester-linked account is the case that matters.
    page: bool = False
    refuse: bool = False


@dataclass(frozen=True)
class Suggestion:
    """What the card prints as `suggested`, and what the router may execute on its behalf."""

    rule_key: str
    action: Action
    line_id: str = ""
    why: str = ""
    matched: bool = True

    @property
    def key(self) -> str:
        return self.rule_key

    def render(self) -> str:
        """`<rule key> -> <action>` — the rule key is the one-line PR that changes the mapping."""
        if not self.matched:
            return f"none (unmapped) -> {self.action.key}"
        return f"{self.rule_key} -> {self.action.key}"


@dataclass
class Policy:
    version: str
    intent_labels: frozenset[str]
    actions: dict[str, Action]
    rules: list[dict[str, Any]]
    default_action: str = "unknown"
    path: Path = POLICY_PATH

    # -- loading ---------------------------------------------------------------------------

    @classmethod
    def load(cls, path: Path | None = None, *, bank_ids: Iterable[str] | None = None) -> "Policy":
        p = Path(path) if path else POLICY_PATH
        try:
            doc = json.loads(p.read_text(encoding="utf-8"))
        except OSError as exc:
            raise PolicyError(f"cannot read {p}: {exc}") from exc
        except ValueError as exc:
            raise PolicyError(f"{p} is not valid JSON: {exc}") from exc

        labels = frozenset(str(x) for x in doc.get("intent_labels") or ())
        if not labels:
            raise PolicyError(f"{p}: intent_labels is empty")

        actions: dict[str, Action] = {}
        for key, raw in (doc.get("actions") or {}).items():
            if not isinstance(raw, dict):
                raise PolicyError(f"{p}: action {key} is not an object")
            tier = str(raw.get("tier") or "")
            if tier not in ("W1", "W2", "handoff", "human"):
                raise PolicyError(f"{p}: action {key} has tier {tier!r} (W1|W2|handoff|human)")
            actions[key] = Action(
                key=key, tier=tier,
                executes_here=bool(raw.get("executes_here")),
                handoff=str(raw.get("handoff") or ""),
                line=str(raw.get("line") or ""),
                requires_fact=str(raw.get("requires_fact") or ""),
                inverse=str(raw.get("inverse") or ""),
                describe=str(raw.get("describe") or ""),
                page=bool(raw.get("page")),
                refuse=bool(raw.get("refuse")),
            )
        if not actions:
            raise PolicyError(f"{p}: actions is empty")

        rules = list(doc.get("rules") or [])
        if not rules:
            raise PolicyError(f"{p}: rules is empty")

        default_action = str(doc.get("default_action") or "unknown")
        if default_action not in actions:
            raise PolicyError(f"{p}: default_action {default_action!r} is not an action")

        known_lines = set(bank_ids) if bank_ids is not None else None
        for r in rules:
            rk = str(r.get("key") or "")
            if not rk:
                raise PolicyError(f"{p}: a rule has no key")
            intents = r.get("intents") or []
            if not intents:
                raise PolicyError(f"{p}: rule {rk} has no intents")
            for i in intents:
                if i != "*" and i not in labels:
                    raise PolicyError(f"{p}: rule {rk} names unknown intent {i!r}")
            for name, want in (r.get("when") or {}).items():
                if name not in PREDICATES:
                    raise PolicyError(f"{p}: rule {rk} names unknown predicate {name!r}")
                _check_want(rk, name, want, p)
            act = str(r.get("action") or "")
            if act not in actions:
                raise PolicyError(f"{p}: rule {rk} names unknown action {act!r}")
            line = str(r.get("line") or actions[act].line or "")
            if line and known_lines is not None and line not in known_lines:
                raise PolicyError(f"{p}: rule {rk} names unknown answer-bank line {line!r}")
        return cls(version=str(doc.get("version") or "unversioned"), intent_labels=labels,
                   actions=actions, rules=rules, default_action=default_action, path=p)

    # -- the lookup ------------------------------------------------------------------------

    def suggest(self, intent: str | None, data: Mapping[str, Any],
                measured: Mapping[str, bool] | None = None) -> Suggestion:
        """First matching rule wins. `measured` says which facts a reader actually returned; a
        fact that is not measured can never satisfy a predicate (it reads as unknown)."""
        measured = measured or {}
        label = intent if intent in self.intent_labels else "other"
        for rule in self.rules:
            intents = rule.get("intents") or []
            if "*" not in intents and label not in intents:
                continue
            if not self._when_holds(rule, data, measured):
                continue
            act = self.actions[str(rule["action"])]
            line = str(rule.get("line") or act.line or "")
            return Suggestion(rule_key=str(rule["key"]), action=act, line_id=line,
                              why=str(rule.get("why") or ""), matched=True)
        act = self.actions[self.default_action]
        return Suggestion(rule_key="", action=act, line_id=act.line, why="no rule matched",
                          matched=False)

    @staticmethod
    def _when_holds(rule: Mapping[str, Any], data: Mapping[str, Any],
                    measured: Mapping[str, bool]) -> bool:
        for name, want in (rule.get("when") or {}).items():
            if not measured.get(name, False):
                # UNKNOWN never satisfies a predicate. Falling through to a later rule (or to
                # `unknown`) is the honest outcome; guessing is not.
                return False
            if not PREDICATES[name](data.get(name), want):
                return False
        return True


# ------------------------------------------------------------------------------------------------
# predicate helpers


def _compare(value: int, want: Any) -> bool:
    if isinstance(want, bool) or not isinstance(want, str):
        return False
    w = want.replace(" ", "")
    if w.startswith(">="):
        return value >= int(w[2:])
    if w.startswith("<="):
        return value <= int(w[2:])
    if w.startswith(">"):
        return value > int(w[1:])
    if w.startswith("<"):
        return value < int(w[1:])
    if w.startswith("=="):
        return value == int(w[2:])
    return False


def _yesno(v: Any) -> str:
    if v is True:
        return "yes"
    if v is False:
        return "no"
    return "unknown"


def _erasure_state(row: Any) -> str:
    if row is None:
        return "unknown"
    if isinstance(row, dict):
        return str(row.get("status") or "open")
    return "unknown"


def _account_matches(value: Any, want: Any) -> bool:
    """`account` is special: it is DERIVED (a resolved account id, or a requester-linked refusal)
    by `suggest_for`, not read straight off a fact."""
    return value == want


def _check_want(rule: str, name: str, want: Any, path: Path) -> None:
    if name in ("open_requests", "claims", "merges", "tickets"):
        if not isinstance(want, str) or not any(want.replace(" ", "").startswith(op)
                                                for op in (">", "<", "==")):
            raise PolicyError(f"{path}: rule {rule} predicate {name} wants {want!r} "
                              "(one of >0 ==0 >=1 <=0 >1 <1)")
        try:
            _compare(0, want)
        except ValueError as exc:
            raise PolicyError(f"{path}: rule {rule} predicate {name} wants {want!r}: {exc}") from exc
        return
    allowed = {
        "account": {"resolved", "unresolved", "requester_linked"},
        "erasure": {"open", "closed", "none", "unknown"},
        "proof_on_file": {"yes", "no"},
        "target_popular": {"yes", "no"},
    }
    if name in allowed and str(want) not in allowed[name]:
        raise PolicyError(f"{path}: rule {rule} predicate {name} wants {want!r} "
                          f"(one of {sorted(allowed[name])})")
    if name in ("request_status", "open_status", "dv_outcome", "subscription") \
            and not isinstance(want, str):
        raise PolicyError(f"{path}: rule {rule} predicate {name} wants a string, got {type(want).__name__}")


# ------------------------------------------------------------------------------------------------
# account derivation + the quarantine rule


def account_state(facts: Any, *, requester_email: str | None = None,
                  requester_ids: Iterable[str] = ()) -> str:
    """resolved | unresolved | requester_linked.

    `requester_linked` is the refusal case j2 §4 names: the target account IS the requester's own
    (their Slack email or one of their own presented profiles). Every write from this surface would
    then be self-approval, so the card refuses and pages instead of resolving.
    """
    uid = facts.value("account_id")
    if uid is None:
        return "unresolved"
    email = (facts.value("contact_email") or "").strip().lower()
    if requester_email and email and email == requester_email.strip().lower():
        return "requester_linked"
    ext = str(facts.value("contact_external_id") or "").strip().lower()
    if ext and ext in {str(x).strip().lower() for x in requester_ids if x}:
        return "requester_linked"
    return "resolved"


def data_for(facts: Any, *, requester_email: str | None = None,
             requester_ids: Iterable[str] = ()) -> dict[str, Any]:
    """The predicate input: the fact values, with `account` derived (never read off a fact)."""
    d = dict(facts.data)
    # Derived views over the two facts that carry structure, so a predicate names the THING it
    # means ("is there an open request") rather than a json shape.
    d["open_requests"] = facts.requests
    d["open_status"] = facts.open_request_statuses
    verify = facts.value("verify")
    d["proof_on_file"] = verify if isinstance(verify, dict) else None
    d["dv_outcome"] = verify if isinstance(verify, dict) else None
    d["account"] = account_state(facts, requester_email=requester_email, requester_ids=requester_ids)
    return d


def measured_for(facts: Any, *, requester_email: str | None = None,
                 requester_ids: Iterable[str] = ()) -> dict[str, bool]:
    """Which predicates have a measured input. `erasure` counts as measured whenever the reader
    ran: a store that found no row is a measured `none`, while a store that is not on this host is
    the measured state `unknown` (a staff line, never a customer ask). `account` is always measured
    because r5 puts an empty external_id in the text."""
    out = {name: facts.get(name).measured for name in facts.facts}
    out["account"] = True
    out["open_requests"] = facts.get("requests").measured
    out["open_status"] = facts.get("requests").measured
    out["proof_on_file"] = facts.get("verify").measured
    out["dv_outcome"] = facts.get("verify").measured
    return out


def suggest_for(facts: Any, intent: str | None, policy: Policy, *,
                requester_email: str | None = None,
                requester_ids: Iterable[str] = (),
                quarantined: bool = False) -> Suggestion:
    """The one entry point the card and the executor share.

    A QUARANTINED customer text short-circuits to `unknown` (hand-off): when the injection watch
    fires HIGH, nothing about the ask may drive a write, whatever the facts say.
    """
    if quarantined:
        act = policy.actions.get("unknown") or policy.actions[policy.default_action]
        return Suggestion(rule_key="customer-text-quarantined", action=act, line_id=act.line,
                          why="injection watch HIGH hit: the ask is handed off, never resolved",
                          matched=True)
    return policy.suggest(intent, data_for(facts, requester_email=requester_email,
                                           requester_ids=requester_ids),
                          measured_for(facts, requester_email=requester_email,
                                       requester_ids=requester_ids))
