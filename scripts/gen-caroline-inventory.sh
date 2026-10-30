#!/usr/bin/env bash
# gen-caroline-inventory.sh — regenerate the two checked-in JSON files that
# drive the Jev pre-turn router for Caroline (docs/designs/2026-09-22-jev-caroline-router.md,
# section A):
#
#   - plugins/intercom/src/caroline-inventory.json — Caroline's tool/skill/
#     intent capability map.
#   - plugins/intercom/src/caroline-questions.json — the exact Jev `questions`
#     object built from that inventory (Choice/Noul/Score primitives), the
#     single source consumed by both the plugin and the backtest.
#
# Sources (never hand-typed, always extracted):
#   - tool names: registered `name: "..."` literals in
#     plugins/support-tools/src/tools/*.ts (excludes *.test.ts and the
#     ticket-format.ts helper, which registers no tool).
#   - tool kind/resolves/requires: workspaces/support/TOOLS.md's numbered
#     `### N. tool_name` sections (Wraps/Bundles + Identity/Auth bullets). A
#     tool present in code but absent from TOOLS.md (today: the two
#     company-finder-batch.ts tools) gets resolves/requires: "undocumented"
#     and a WARN naming it — never a fabricated sentence.
#   - skills: every workspaces/support/skills/*/SKILL.md classified as a
#     customer-request skill (frontmatter description, "## Tools"/"Tools
#     this skill/flow uses" section if present, "## Purpose" first sentence).
#     input-sanitizer and output-sanitizer are pipeline/guard skills (empty
#     `triggers:`, applied to every message pre/post-processing, not
#     customer-request-triggered) and are deliberately excluded.
#   - intents: the SUPPORT_ACTION_ROUTES table in
#     plugins/support-tools/src/tools/support-action-router.ts.
#   - human_required / no_reply: verbatim doctrine strings from the design
#     contract (not extracted from code — there is no code source for them).
#
# Why python3 (not jq) for extraction, jq for final formatting: turning
# TOOLS.md/SKILL.md markdown prose into one-sentence fields and pulling
# fixed-shape literals out of support-action-router.ts needs regex/string
# work jq's language is a poor fit for (same rationale as
# scripts/jev-shadow-report.sh's embedded-python choice). jq -S is used only
# at the very end to re-serialize both files with deterministic key
# ordering; the python side never depends on dict insertion order for the
# on-disk bytes.
#
# Determinism: no timestamps, no hostnames, stable sort (tools/skills/
# intents sorted by name) --> two runs on an unchanged tree are byte-
# identical, which scripts/check-caroline-inventory.sh and
# scripts/tests/gen-caroline-inventory.bats both rely on.
#
# Usage:
#   scripts/gen-caroline-inventory.sh [--out-dir DIR]
#     --out-dir DIR   write caroline-inventory.json and caroline-questions.json
#                     into DIR instead of plugins/intercom/src/ (used by
#                     check-caroline-inventory.sh to regenerate into a temp
#                     dir for diffing).
#
# Exit codes:
#   0 — wrote both files (WARNs about undocumented tools go to stderr, are
#       not fatal)
#   2 — script-level error (bad argument, missing source file, a skill dir
#       that is neither included nor explicitly excluded above)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="${REPO_ROOT}/plugins/intercom/src"

while [ $# -gt 0 ]; do
  case "$1" in
    --out-dir) OUT_DIR="$2"; shift 2 ;;
    *) echo "gen-caroline-inventory.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
done

command -v jq >/dev/null 2>&1 || { echo "FATAL: jq not found on PATH" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 not found on PATH" >&2; exit 2; }

[[ -f "${REPO_ROOT}/workspaces/support/TOOLS.md" ]] || {
  echo "FATAL: ${REPO_ROOT}/workspaces/support/TOOLS.md not found" >&2
  exit 2
}
[[ -f "${REPO_ROOT}/plugins/support-tools/src/tools/support-action-router.ts" ]] || {
  echo "FATAL: support-action-router.ts not found" >&2
  exit 2
}

mkdir -p "$OUT_DIR"

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/gen-caroline-inventory.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT

python3 - "$REPO_ROOT" "$WORK_DIR" <<'PY'
import json
import re
import sys
from pathlib import Path

REPO_ROOT = Path(sys.argv[1])
WORK_DIR = Path(sys.argv[2])
TOOLS_MD = REPO_ROOT / "workspaces/support/TOOLS.md"
TOOLS_TS_DIR = REPO_ROOT / "plugins/support-tools/src/tools"
SKILLS_DIR = REPO_ROOT / "workspaces/support/skills"
ROUTER_TS = TOOLS_TS_DIR / "support-action-router.ts"

WARNINGS = []


def warn(msg):
    WARNINGS.append(msg)


# ---------------------------------------------------------------------------
# 1. Tool names, mechanically extracted from plugins/support-tools/src/tools/*.ts
# ---------------------------------------------------------------------------
def discover_tool_names():
    names = []
    for f in sorted(TOOLS_TS_DIR.glob("*.ts")):
        if f.name == "ticket-format.ts" or f.name.endswith(".test.ts"):
            continue
        for m in re.finditer(r'name:\s*"([a-zA-Z_]+)"', f.read_text(encoding="utf-8")):
            names.append(m.group(1))
    return sorted(set(names)), names


# ---------------------------------------------------------------------------
# 2. TOOLS.md section parsing (resolves / requires / kind)
# ---------------------------------------------------------------------------
def strip_md(s):
    s = re.sub(r"`([^`]*)`", r"\1", s)
    s = re.sub(r"\*\*([^*]*)\*\*", r"\1", s)
    return s


def truncate(s, maxlen):
    s = s.strip()
    if len(s) <= maxlen:
        return s
    return s[: maxlen - 1].rsplit(" ", 1)[0].rstrip(",;: ") + "…"


def first_sentence(s, maxlen=220):
    s = strip_md(s).strip()
    m = re.search(r"(.+?\.)(\s|$)", s)
    sent = (m.group(1) if m else s).strip()
    return truncate(sent, maxlen)


def pick_activates_when(desc, maxlen=300):
    """Prefer the sentence describing *when* the skill activates (contract:
    "frontmatter description/first 'when' sentence"); fall back to the full
    description, truncated (never mid-sentence-cut) to maxlen chars."""
    desc = strip_md(desc).strip()
    sentences = re.split(r"(?<=[.;])\s+", desc)
    for s in sentences:
        if re.search(r"\bwhen\b", s, re.I):
            return truncate(s.strip(), maxlen)
    return truncate(desc, maxlen)


def parse_tools_md():
    text = TOOLS_MD.read_text(encoding="utf-8")
    section_re = re.compile(r"^### \d+\.\s+(\S+)\s*$", re.M)
    matches = list(section_re.finditer(text))
    sections = {}
    for i, m in enumerate(matches):
        name = m.group(1)
        start = m.end()
        end = matches[i + 1].start() if i + 1 < len(matches) else len(text)
        sections[name] = text[start:end]
    return sections


def bullets(body):
    out = {}
    cur_label, cur_lines = None, []

    def flush():
        if cur_label is not None:
            out[cur_label] = " ".join(cur_lines).strip()

    for line in body.splitlines():
        bm = re.match(r"^- \*\*([^*]+)\*\*:\s?(.*)$", line)
        if bm:
            flush()
            cur_label = bm.group(1).strip()
            cur_lines = [bm.group(2)]
        elif cur_label is not None:
            if line.strip() == "" or re.match(r"^\s+-\s", line):
                flush()
                cur_label, cur_lines = None, []
            else:
                cur_lines.append(line.strip())
    flush()
    return out


WRITE_KEYWORD_RE = re.compile(r"\bWRITE\b")
VERB_RE = re.compile(r"\b(DELETE|PUT|POST)\b")
READONLY_RE = re.compile(r"read-only", re.I)
GET_RE = re.compile(r"\bGET\b")


def classify_kind(name, wraps_full_text):
    # create_ticket and support_action_router have no HTTP-verb-shaped Wraps
    # bullet to classify from (a ClickUp task creator, and a deterministic
    # in-process registry respectively) -- hardcoded per the contract's
    # explicit "kind enum has no routing value" note.
    if name == "create_ticket":
        return "handoff"
    if name == "support_action_router":
        return "read"

    # Classify on the tool's DECLARED behavior, never on any HTTP verb that
    # merely appears somewhere in the prose -- credit_verification_check's
    # Wraps bullet opens "read-only lookup..." but later explains, in a
    # negated clause, that it "cannot reach the gated PUT .../approve path";
    # a naive whole-section regex read that PUT as a write declaration
    # (#defect, 2026-09-22 QA). Priority, most-specific declared marker
    # first:
    #   1. an explicit "WRITE" keyword anywhere (every gated write tool's
    #      TOOLS.md prose declares itself this way -- "Gated WRITE",
    #      "APPROVAL-tier ... WRITE counterpart" -- and this is a stronger,
    #      more specific signal than an incidental "read-only" mention
    #      elsewhere in the same bullet, e.g. profiles_claim_self is
    #      "Gated WRITE counterpart of the read-only checks").
    #   2. an explicit "read-only" declaration anywhere in the bullet.
    #   3. an HTTP verb, but ONLY in the bullet's first sentence -- that is
    #      where a tool declares the endpoint IT wraps (e.g. "`PUT
    #      /api/v3/admin/orders/{id}`..."); verbs appearing in later
    #      sentences are routinely describing a DIFFERENT, unreachable
    #      endpoint (what the tool refuses to do), not its own behavior.
    #   4. a bare "GET" anywhere -- last resort, weakest signal.
    if WRITE_KEYWORD_RE.search(wraps_full_text):
        return "write"
    if READONLY_RE.search(wraps_full_text):
        return "read"
    first_sentence = wraps_full_text.split(". ", 1)[0] if wraps_full_text else ""
    if VERB_RE.search(first_sentence):
        return "write"
    if GET_RE.search(wraps_full_text):
        return "read"
    return "read"


def requires_for(b):
    # "Identity" bullets carry suffixes like "(anti-spoof)" / "(anti-spoof,
    # FAIL-CLOSED)"; fall back through Auth, then Parameters, then Required
    # fields for tools (like support_action_router) with no identity bullet.
    id_key = next((k for k in b if k.startswith("Identity")), None)
    for key in ([id_key] if id_key else []) + ["Auth", "Parameters", "Required fields"]:
        if key and key in b:
            return first_sentence(b[key])
    return "No identity precondition documented."


def tool_meta_from_tools_md(name, sections):
    if name not in sections:
        return None
    b = bullets(sections[name])
    wraps_key = "Wraps" if "Wraps" in b else ("Bundles" if "Bundles" in b else None)
    wraps_full = b[wraps_key] if wraps_key else ""
    resolves = first_sentence(wraps_full) if wraps_key else "(no Wraps/Bundles bullet found)"
    requires = requires_for(b)
    kind = classify_kind(name, wraps_full)
    return {"kind": kind, "resolves": resolves, "requires": requires}


# ---------------------------------------------------------------------------
# 3. Skills -- customer-request skills only (see header comment)
# ---------------------------------------------------------------------------
INCLUDE_SKILLS = {
    "action-request",
    "milestone-badge-purchase",
    "order-fulfillment",
    "refund-retention",
    "verification-handoff",
}
EXCLUDE_SKILLS = {
    "input-sanitizer": "pipeline/guard skill (pre-processes messages before the LLM; empty triggers, not customer-request-shaped)",
    "output-sanitizer": "pipeline/guard skill (post-processes agent replies before the customer; empty triggers, not customer-request-shaped)",
}

KNOWN_TOOL_NAME_RE = None  # filled in once tool names are known


def parse_skill(dirpath):
    text = (dirpath / "SKILL.md").read_text(encoding="utf-8")
    fm_m = re.search(r"^---\n(.*?)\n---\n", text, re.S)
    fm = fm_m.group(1) if fm_m else ""
    desc_m = re.search(r"^description:\s*(.*)$", fm, re.M)
    desc = desc_m.group(1).strip() if desc_m else ""
    if desc.startswith('"') and desc.endswith('"'):
        desc = desc[1:-1]
    activates_when = pick_activates_when(desc, maxlen=300)

    tools_used = []
    tm = re.search(
        r"(?:^## Tools[^\n]*\n(.*?)(?:\n## |\Z)|\*\*Tools this (?:skill|flow) uses:\*\*\s*(.*?)(?:\n\n|\Z))",
        text,
        re.S | re.M,
    )
    if tm:
        block = tm.group(1) or tm.group(2) or ""
        for tn in KNOWN_TOOL_NAME_RE.finditer(block):
            if tn.group(0) not in tools_used:
                tools_used.append(tn.group(0))

    purpose_m = re.search(r"^## Purpose\n+(.*?)(?:\n\n|\Z)", text, re.S | re.M)
    outcome = first_sentence((purpose_m.group(1) if purpose_m else desc).replace("\n", " "), maxlen=400)

    return {
        "name": dirpath.name,
        "activates_when": activates_when,
        "tools_used": tools_used,
        "outcome": outcome,
    }


# ---------------------------------------------------------------------------
# 4. Intents, fully regex-extracted from SUPPORT_ACTION_ROUTES
# ---------------------------------------------------------------------------
def parse_intents():
    text = ROUTER_TS.read_text(encoding="utf-8")
    # Routes are either an object literal (`  key: {`) or, for the hand-off-only
    # verification/merge intents (captain 2026-10-28), a builder call
    # (`  key: verificationHandoffRoute(label, goal, actionType, missing, tags)`).
    key_re = re.compile(r"^  ([a-z_]+): (\{|verificationHandoffRoute\()$", re.M)
    keys = [(m.group(1), m.start(), m.group(2) != "{") for m in key_re.finditer(text)]
    intents = []
    for i, (key, start, is_handoff) in enumerate(keys):
        end = keys[i + 1][1] if i + 1 < len(keys) else len(text)
        block = text[start:end]
        if is_handoff:
            args = re.findall(r'"((?:[^"\\]|\\.)*)"', block)
            intents.append(
                {
                    "intent": key,
                    "description": args[1].replace('\\"', '"'),
                    "first_read_tool": "",
                    "write_tools": [],
                    "handoff_when": "Always: this request is decided by the verification / merge agents",
                    "action_type_on_handoff": args[2],
                }
            )
            continue

        def field(name):
            m = re.search(rf'{name}:\s*"((?:[^"\\]|\\.)*)"', block)
            return m.group(1).replace('\\"', '"') if m else None

        def arr_field(name):
            m = re.search(rf"{name}:\s*\[(.*?)\]", block, re.S)
            if not m:
                return []
            items = re.findall(r'"((?:[^"\\]|\\.)*)"', m.group(1))
            return [it.replace('\\"', '"') for it in items]

        goal = field("goal")
        read_tools = arr_field("live_read_tools")
        write_tools = arr_field("live_write_tools")
        handoff_when = "; ".join(arr_field("handoff_when"))

        # tool_refused: handoffStep("<action-type>") gives a fixed action
        # type; billingFailureHandoff() (billing_cancel_refund only) is
        # request-dependent (refund vs. charge-issue packet) and carries no
        # fixed literal in source -- action_type_on_handoff is correctly
        # null there, not a parsing gap.
        tr = re.search(r"tool_refused:\s*(\w+)\(([^)]*)\)", block)
        action_type = None
        if tr and tr.group(1) == "handoffStep":
            am = re.search(r'"((?:[^"\\]|\\.)*)"', tr.group(2))
            action_type = am.group(1) if am else None

        intents.append(
            {
                "intent": key,
                "description": goal,
                "first_read_tool": read_tools[0] if read_tools else "",
                "write_tools": write_tools,
                "handoff_when": handoff_when,
                "action_type_on_handoff": action_type,
            }
        )
    return intents


INSTRUCTIONS_PREFIX = (
    "Caroline is Muso's support agent. Judge the customer's LAST message in the "
    "context of the conversation."
)


def build_questions(inventory):
    tools = inventory["tools"]
    skills = inventory["skills"]
    intents = inventory["intents"]
    read_tools = [t for t in tools if t["kind"] == "read"]

    # caroline_tool has a ~900-char target: per-skill activates_when is
    # capped much tighter here than the skill question's own 300-char
    # criteria (full text) -- this is a compact "name (when)" index, not
    # the activation condition itself.
    skill_parts = [f"{s['name']} ({truncate(s['activates_when'], 20)})" for s in skills]
    caroline_tool_text = (
        "Caroline resolves it herself. Read tools cover the customer's own profile, analytics, "
        "orders, subscription, billing and founding status; gated write tools fix an order "
        "address, apply the retention discount, cancel at period end, and file a structured "
        "ticket. Credit status, documents, claims, removals and merges are ALWAYS a hand-off "
        "(verification-handoff: one ticket, no look-up), never a read. Skills: " + "; ".join(skill_parts)
    )

    resolution_path = {
        "type": "choice",
        "instructions": INSTRUCTIONS_PREFIX
        + " Decide how the customer's need is resolved: does Caroline already have a tool or "
        + "skill that handles it, is one fact missing before a tool can act, does it require a "
        + "human, or does it need no reply at all? The customer's identity is verified by "
        + "Intercom, and Caroline's read tools find their profile, orders and subscription from "
        + "that verified email without asking. Prefer caroline_tool whenever a tool can read or "
        + "act on what the customer is asking about; credit, document, claim and merge questions "
        + "are caroline_tool via the verification-handoff skill (a ticket, never a look-up).",
        "criteria": {
            "caroline_tool": caroline_tool_text,
            "ask_customer": (
                "Caroline cannot start without one specific thing only the customer has: the "
                "exact tracks to remove, which of several profiles they mean, proof or a "
                "screenshot for a credit, an order number when the account has several. Not "
                "for locating their profile or account; the read tools do that from the "
                "verified email."
            ),
            "human_required": "No tool path exists because the request is one of: " + "; ".join(inventory["human_required"]),
            "no_reply": "; ".join(inventory["no_reply"]),
        },
    }

    intent_criteria = {i["intent"]: (i["description"] or "") for i in intents}
    intent_criteria["other"] = "None of the above intents match the customer's request."
    intent_q = {
        "type": "choice",
        "instructions": INSTRUCTIONS_PREFIX
        + " Pick the single support intent that best matches the customer's request.",
        "criteria": intent_criteria,
    }

    create_ticket_resolves = next((t["resolves"] for t in tools if t["name"] == "create_ticket"), "File a structured handoff ticket.")
    first_tool_criteria = {t["name"]: t["resolves"] for t in read_tools}
    first_tool_criteria["create_ticket"] = create_ticket_resolves
    first_tool_criteria["none"] = "No tool call is the right first step for this message."
    first_tool_q = {
        "type": "choice",
        "instructions": INSTRUCTIONS_PREFIX
        + " Pick the first tool Caroline should call to resolve this request, or create_ticket "
        + "if it must go straight to a handoff, or none if no tool call is warranted. Pick the "
        + "tool that reads the specific object the customer is asking about (pending credits → "
        + "credit_verification_check, a claim → profile_claim_status, an order → order_lookup, "
        + "a charge → billing_status); profile_status only when the ask is about the profile "
        + "itself.",
        "criteria": first_tool_criteria,
    }

    skill_criteria = {s["name"]: s["activates_when"] for s in skills}
    skill_criteria["none"] = "No skill's activation condition matches this request."
    skill_q = {
        "type": "choice",
        "instructions": INSTRUCTIONS_PREFIX
        + " Pick the skill whose activation condition matches this request, or none.",
        "criteria": skill_criteria,
    }

    off_topic_q = {
        "type": "noul",
        "instructions": INSTRUCTIONS_PREFIX
        + " Is this message unrelated to the customer's own Muso account or support need, or "
        + "clearly not a good-faith request?",
        "criteria": {
            "true": (
                "unrelated to the customer's own Muso account or support need, or clearly not "
                "a good-faith request (jokes, essays, tests, insults, spam)"
            ),
            "false": "a genuine, on-topic support request about the customer's own Muso account.",
        },
    }

    frustration_q = {
        "type": "score",
        "instructions": INSTRUCTIONS_PREFIX + " Rate the customer's emotional tone in their last message.",
        "criteria": ["Calm", "Concerned", "Frustrated", "Angry"],
    }

    return {
        "resolution_path": resolution_path,
        "intent": intent_q,
        "first_tool": first_tool_q,
        "skill": skill_q,
        "off_topic_or_bad_faith": off_topic_q,
        "frustration": frustration_q,
    }


def main():
    global KNOWN_TOOL_NAME_RE
    tool_names, all_registrations = discover_tool_names()
    if len(all_registrations) != len(tool_names):
        warn(
            f"duplicate tool name registrations detected: {len(all_registrations)} "
            f"registrations, {len(tool_names)} unique names"
        )

    KNOWN_TOOL_NAME_RE = re.compile("|".join(re.escape(n) for n in sorted(tool_names, key=len, reverse=True)))

    sections = parse_tools_md()

    # The two company-finder-batch.ts tools are the one known case of code
    # ahead of TOOLS.md (contract's own example); classified write since
    # both prep and finalize mutate a batch job, but flagged undocumented.
    UNDOCUMENTED_KIND = {
        "company_finder_prep": "write",
        "company_finder_finalize": "write",
    }

    tools = []
    for name in tool_names:
        meta = tool_meta_from_tools_md(name, sections)
        if meta is None:
            warn(f"tool '{name}' is registered in code but not documented in workspaces/support/TOOLS.md")
            tools.append(
                {
                    "name": name,
                    "kind": UNDOCUMENTED_KIND.get(name, "write"),
                    "resolves": "undocumented",
                    "requires": "undocumented",
                }
            )
        else:
            tools.append({"name": name, **meta})
    tools.sort(key=lambda t: t["name"])

    skill_dirs = {p.name for p in SKILLS_DIR.iterdir() if p.is_dir() and (p / "SKILL.md").exists()}
    known = INCLUDE_SKILLS | set(EXCLUDE_SKILLS)
    missing = skill_dirs - known
    extra = known - skill_dirs
    if missing:
        print(f"FATAL: new skill dir(s) not classified include/exclude in gen-caroline-inventory.sh: {sorted(missing)}", file=sys.stderr)
        sys.exit(2)
    if extra:
        print(f"FATAL: classified skill dir(s) no longer exist: {sorted(extra)}", file=sys.stderr)
        sys.exit(2)

    skills = [parse_skill(SKILLS_DIR / n) for n in sorted(INCLUDE_SKILLS)]

    intents = parse_intents()
    intents.sort(key=lambda i: i["intent"])

    # Doctrine, not code-extracted -- verbatim from
    # docs/designs/2026-09-22-jev-caroline-router.md section A.
    human_required = [
        "identity or ownership cannot be verified",
        "cross-owner conflict (someone else claimed or is claiming the customer's profile, credits or workspace)",
        "refund request", "account deletion / GDPR erasure", "profile deletion or unmerge",
        "policy exception or waiver", "role-based bulk credit change",
        "chargeback, fraud or account takeover", "duplicate or post-cancel charge",
        "founding-member free reinstatement", "on-behalf or cross-account request",
    ]
    no_reply = [
        "bare closer after Caroline already acknowledged once",
        "third or later identical message",
    ]

    inventory = {
        "generated_from": {
            "tools": "plugins/support-tools/src/tools/*.ts + workspaces/support/TOOLS.md",
            "skills": "workspaces/support/skills/*/SKILL.md",
            "intents": "plugins/support-tools/src/tools/support-action-router.ts",
        },
        "tools": tools,
        "skills": skills,
        "intents": intents,
        "human_required": human_required,
        "no_reply": no_reply,
    }

    questions = build_questions(inventory)

    for w in WARNINGS:
        print(f"WARN: {w}", file=sys.stderr)

    (WORK_DIR / "caroline-inventory.raw.json").write_text(json.dumps(inventory), encoding="utf-8")
    (WORK_DIR / "caroline-questions.raw.json").write_text(json.dumps(questions), encoding="utf-8")


if __name__ == "__main__":
    main()
PY

# Deterministic, stable key-sorted formatting (jq -S), matching the shape
# shown in the design contract.
jq -S . "${WORK_DIR}/caroline-inventory.raw.json" > "${OUT_DIR}/caroline-inventory.json"
jq -S . "${WORK_DIR}/caroline-questions.raw.json" > "${OUT_DIR}/caroline-questions.json"

echo "gen-caroline-inventory.sh: wrote ${OUT_DIR}/caroline-inventory.json and ${OUT_DIR}/caroline-questions.json" >&2
