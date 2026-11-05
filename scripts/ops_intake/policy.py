"""Requester resolution and the write tiers, read from the two policy files.

Two questions, answered here and nowhere else:

* **Who is asking?** The Slack envelope's ``user``, looked up in
  ``policies/ops-requesters.json``. A name in the text is never identity. An
  unknown id is a real answer, not an error: tier R, writes refused, human path
  named (the census saw a pasted "*Jan Delmo*" header on 11-02 16:31Z).
* **What may they ask for?** ``policies/ops-intake-actions.json`` maps each ask
  class to an action and a tier, lists the W1 actions with their inverse recipe,
  and lists the W2 actions with the human path each one names. A W2 trigger
  anywhere in the message refuses the whole ask - a W1 Intercom note must not
  ride along inside "refund it and add a note".

Everything fails CLOSED: a missing/unparseable policy file raises
:class:`PolicyError` and the router answers with a refusal + page rather than
guessing a tier. That is why the CI guard exists
(scripts/check-ops-intake-policy.sh): a policy file that cannot be parsed
silences writes, and a policy file that is merely WRONG does not.
"""
from __future__ import annotations

import json
import re
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[2]
REQUESTERS_PATH = ROOT / "policies" / "ops-requesters.json"
ACTIONS_PATH = ROOT / "policies" / "ops-intake-actions.json"

# Tier order. R is a subset of W1; W2 is granted to nobody on this surface.
TIER_RANK = {"R": 1, "W1": 2}


class PolicyError(RuntimeError):
    """Policy missing, unparseable, or internally inconsistent - fail closed."""


@dataclass(frozen=True)
class Requester:
    user_id: str
    name: str | None
    tier: str
    staff: bool
    known: bool
    slack_email: str | None = None

    @property
    def can_write(self) -> bool:
        return self.tier in TIER_RANK and TIER_RANK[self.tier] >= TIER_RANK["W1"]


@dataclass(frozen=True)
class ClassPlan:
    cls: str
    action: str | None
    tier: str
    write_action: str | None = None
    requires_register_verdict: tuple[str, ...] = ()
    agent_handles: bool = False
    notes: str = ""


@dataclass(frozen=True)
class W2Trigger:
    action: str
    pattern: re.Pattern[str]
    human_path: str
    why: str


@dataclass
class Policy:
    requesters: dict[str, dict[str, Any]]
    actions: dict[str, Any]
    w2_triggers: tuple[W2Trigger, ...] = field(default_factory=tuple)

    # -- requester --------------------------------------------------------
    def resolve(self, user_id: str | None, *, display_name: str | None = None) -> Requester:
        """Envelope user id -> Requester. Unknown ids get the unknown tier (R)."""
        uid = (user_id or "").strip()
        if not uid:
            return Requester(user_id="", name=None, tier=self.unknown_tier, staff=False,
                             known=False)
        entry = self.requesters.get(uid)
        if entry is None:
            return Requester(user_id=uid, name=display_name, tier=self.unknown_tier,
                             staff=False, known=False)
        return Requester(user_id=uid, name=entry.get("name") or display_name,
                         tier=entry.get("tier", "R"), staff=bool(entry.get("staff")),
                         known=True, slack_email=entry.get("slack_email"))

    @property
    def unknown_tier(self) -> str:
        return self.actions.get("requesters_unknown_tier") or "R"

    # -- class plan -------------------------------------------------------
    def plan_for(self, cls: str) -> ClassPlan:
        entry = self.actions.get("classes", {}).get(cls)
        if entry is None:
            raise PolicyError(f"class {cls!r} has no entry in policies/ops-intake-actions.json")
        tier = entry.get("tier", "R")
        if tier == "W2":
            raise PolicyError(f"class {cls!r} is mapped to W2 - no class may be")
        return ClassPlan(
            cls=cls,
            action=entry.get("action"),
            tier=tier,
            write_action=entry.get("write_action"),
            requires_register_verdict=tuple(entry.get("requires_register_verdict") or ()),
            agent_handles=bool(entry.get("agent_handles")),
            notes=entry.get("notes", ""),
        )

    # -- writes -----------------------------------------------------------
    def write_action(self, name: str) -> dict[str, Any]:
        w1 = self.actions.get("tiers", {}).get("W1", {}).get("actions", {})
        entry = w1.get(name)
        if entry is None:
            raise PolicyError(f"{name!r} is not a declared W1 action")
        if not entry.get("inverse"):
            raise PolicyError(f"W1 action {name!r} declares no inverse")
        return entry

    def may_write(self, requester: Requester, action: str) -> tuple[bool, str]:
        try:
            self.write_action(action)
        except PolicyError as exc:
            return False, str(exc)
        if not requester.known:
            return False, "requester-unknown"
        if not requester.can_write:
            return False, f"tier-{requester.tier}"
        return True, "ok"

    def w2_requests(self, text: str) -> list[W2Trigger]:
        """Every irreversible action the message asks for. Non-empty => refuse."""
        return [t for t in self.w2_triggers if t.pattern.search(text or "")]

    def quotes_staff_name(self, quote: str | None) -> bool:
        """Does this pasted quote header name a STAFF person?"""
        lowered = (quote or "").lower()
        if not lowered:
            return False
        for entry in self.requesters.values():
            if not entry.get("staff"):
                continue
            name = str(entry.get("name") or "").strip().lower()
            if name and name in lowered:
                return True
        return False

    def caps(self) -> dict[str, Any]:
        return self.actions.get("caps", {})

    def fraud_lens(self) -> dict[str, Any]:
        return self.actions.get("fraud_lens", {})

    def reply_rules(self) -> dict[str, Any]:
        return self.actions.get("reply", {})

    def channels(self) -> dict[str, Any]:
        return self.actions.get("channels", {})

    def w2_human_path(self, action: str) -> str:
        return (self.actions.get("tiers", {}).get("W2", {}).get("actions", {})
                .get(action, {}).get("human_path", "a named human session"))


def load(requesters_path: str | Path | None = None,
         actions_path: str | Path | None = None) -> Policy:
    rpath = Path(requesters_path or REQUESTERS_PATH)
    apath = Path(actions_path or ACTIONS_PATH)
    for p in (rpath, apath):
        if not p.is_file():
            raise PolicyError(f"missing policy file {p}")
    try:
        requesters_doc = json.loads(rpath.read_text())
        actions_doc = json.loads(apath.read_text())
    except ValueError as exc:
        raise PolicyError(f"policy file is not JSON: {exc}") from exc

    requesters = requesters_doc.get("requesters")
    if not isinstance(requesters, dict) or not requesters:
        raise PolicyError(f"{rpath} has no .requesters object")
    for uid, entry in requesters.items():
        tier = entry.get("tier")
        if tier not in TIER_RANK:
            raise PolicyError(f"requester {uid} has tier {tier!r}; only R/W1 may be granted")

    triggers: list[W2Trigger] = []
    w2 = actions_doc.get("tiers", {}).get("W2", {})
    if w2.get("requesters"):
        raise PolicyError("tiers.W2.requesters must stay empty: no Slack message may "
                          "trigger an irreversible write, for anyone")
    for name, entry in (w2.get("actions") or {}).items():
        for pattern in entry.get("triggers") or []:
            try:
                rx = re.compile(pattern, re.IGNORECASE)
            except re.error as exc:
                raise PolicyError(f"W2 trigger {name!r} is not a regex: {exc}") from exc
            triggers.append(W2Trigger(name, rx, entry.get("human_path", ""),
                                      entry.get("why", "")))

    classes = actions_doc.get("classes") or {}
    if not classes:
        raise PolicyError(f"{apath} has no .classes object")

    return Policy(requesters=requesters, actions=actions_doc,
                  w2_triggers=tuple(triggers))
