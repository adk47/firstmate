#!/usr/bin/env python3
"""check-agent-exec-policy.py - which OpenClaw agents can run shell commands, enforced from code.

guardrails-1101 gap 2 (H1): tools.exec security=full, ask=off runs every main agent's shell as root on node-8, so a
prompt-injected Slack thread, fetched page or PR body can become `curl ... | sh`. Rulings: security-arch-fable-s1
[key=exec-scope] and [key=exec-lever], 2026-11-01. policies/agent-exec-policy.json records each agent's posture;
the RULES are the constants below, so a PR cannot widen a rule by editing data.

  python3 scripts/check-agent-exec-policy.py                    repo configs vs the registry (deploy, local)
  python3 scripts/check-agent-exec-policy.py --base origin/main  + the re-grant / new-agent / extension rules (PR CI)
  python3 scripts/check-agent-exec-policy.py --live              node-8 live configs vs the repo (post-deploy)
  python3 scripts/check-agent-exec-policy.py --live --live-profile main   only the profiles being deployed

Exit 0 = clean; 1 = a violation (each named on stdout); 2 = a config or registry could not be read (never a pass);
4 = clean, but a dated `full` exception is inside the pre-expiry warning window (--fail-on-expiring only).

WHY THERE IS A WARNING WINDOW (2026-11-09, [key=exec-posture-lapsed]): this script used to be silent about a dated
exception until the DAY AFTER it lapsed, so the first alarm fired once the damage was done - the deploy was already
blocked, the fix was already a rush, and nobody had had a week to write the exit plan the deleted exception asked for.
A full exception now reports as a WARNING (a github ::warning:: annotation, and rc 4 under --fail-on-expiring, which
is what cron-health-watchdog.sh pages on) from EXPIRY_WARNING_DAYS out, naming the date and the countdown so nobody
has to go looking. It stays exit 0 for deploy and PR CI on purpose: an approaching expiry is a reason to plan, never
a reason to refuse the deploy that ships the fix.

Warnings are NOT errors: the `full until` line is replaced by the warning inside the window, because a registry row
that is about to lapse must never read as `ok`. Expiry itself is still an error - the fail-safe direction is to deny,
nothing else.

TWO CALL SITES, both in scripts/deploy.sh, plus the daily watchdog tick (scripts/cron-health-watchdog.sh) so a
quiet week still pages once an exception's expiry date passes:
  - Step 1, pre-sync, repo copy only      -> a repo tree hand-edited on node-8 after review cannot ship a shell
  - Step 4d.5b, post-sync, --live         -> a partial rsync / a live file that never took cannot silently keep a
                                             root shell (the smoke test cannot see this), still BEFORE Step 6's
                                             restart so a failing deploy never reloads the gateway on it
  - cron-health-watchdog, every tick      -> --live, deduped to one page per day
Skipping the post-deploy check is how the H1 exposure could come back unnoticed: the CI gate only ever sees the
repo copy at PR time.
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
REGISTRY = "policies/agent-exec-policy.json"
# Paths are constants on purpose (standing rule: kill/guard paths never come from env).
LIVE_CONFIG = {
    "openclaw-main.json": "/root/.openclaw-main/openclaw.json",
    "openclaw-edge.json": "/root/.openclaw-edge/openclaw.json",
}
# The only agents that may hold exec indefinitely-renewable; everyone else is on borrowed, dated time.
OPS_AGENTS = frozenset({"operations", "devops", "clio"})
MAX_EXPIRY_DAYS = 31
# REVIEWED RE-GRANT ALLOWLIST (firstmate ruling [key=exec-posture-renew-qa], 2026-11-09).
# A non-ops agent that is `denied` on the base branch may be given exec back ONLY when this table carries a claim
# naming that agent, the ruling that authorises it, and the EXACT expiry being granted. Editing
# policies/agent-exec-policy.json alone can therefore never re-grant: the same diff must also touch this table,
# which is the reviewed change the PR body pointed at. `grants` is the narrow set of shell surfaces the agent may
# reach; it is enforced against the config, not merely recorded, so the registry cannot claim a width the config
# does not have (and the config cannot keep a width the registry did not review).
# Removing a claim in a later PR removes the permission - that is the expiry control.
REGRANT_ALLOWLIST = {
    ("openclaw-main.json", "qa"): {
        "ruling": "[key=exec-posture-renew-qa] 2026-11-09",
        "expires": "2026-12-09",
        "grants": ("exec",),
    },
}
# Start warning this many days before a dated exception lapses. A week is long enough to write an exit plan or take a
# ruling, and short enough that the warning is still about the next deploy rather than background noise.
EXPIRY_WARNING_DAYS = 7
RC_CLEAN, RC_VIOLATION, RC_UNREADABLE, RC_EXPIRING = 0, 1, 2, 4
# rc 3 is reserved: cron-health-watchdog.sh uses it for "the checker itself is missing", which this process can
# never observe about itself (a script that is not there cannot exit).

# Shell-capable tool ids a `denied` agent must deny, per profile.
#   exec     - OpenClaw host exec; its codex aliases gateway_exec / node_exec / sandbox_exec follow it, and because
#              exec is not in the codex safe-deny set, denying it also drops the codex-native shell.
#   process  - background shell sessions (gateway_process / sandbox_process follow it).
#   lobster  - @clawdbot/lobster `exec --shell` steps call child_process.spawn with NO tool-policy check (the plugin
#              returns null only when sandboxed), so an exec-denied agent that keeps lobster still has a root shell.
#              hydra grants it to every main agent via tools.alsoAllow ["lobster"].
#   nodes / computer - command and control on paired nodes (paired nodes exist: node_exec calls seen 2026-10).
#   terminal - reads/writes operator-opened terminals.
# Edge requires only exec: Caroline's exact 15-name list belongs to scripts/lib/assert-support-deny.sh (captain
# 2026-10-28) and edge loads no lobster plugin. Hardening her beyond exec is the captain's call, not this script's.
REQUIRED_DENY = {
    "openclaw-main.json": ("exec", "process", "lobster", "nodes", "computer", "terminal"),
    "openclaw-edge.json": ("exec",),
}
TOOL_GROUPS = {  # openclaw 2026.8.35 docs/gateway/config-tools.md "Tool groups" (shell-relevant groups)
    "group:runtime": {"exec", "process", "code_execution"},
    "group:nodes": {"nodes", "computer"},
    "group:ui": {"browser", "screen", "dashboard", "terminal", "portal", "canvas", "show_widget"},
    "group:automation": {"heartbeat_respond", "cron", "gateway"},
}
# A tool call by one of these names is governed by the canonical tool on the right.
ALIASES = {
    "bash": "exec", "gateway_exec": "exec", "node_exec": "exec", "sandbox_exec": "exec",
    "gateway_process": "process", "sandbox_process": "process",
}
SHELL_TOOLS = ("exec", "process", "lobster", "nodes", "computer", "terminal")
NATIVE_SHELL = "codex-native-shell"
# @openclaw/codex CODEX_TOOL_POLICY_SAFE_DENY_NAMES (2026.8.35; mirrored in validate-config-matrix.sh check #8).
# A deny made only of these keeps the codex-native surface (incl. its shell); anything else restricts it.
CODEX_SAFE_DENY = frozenset({
    "automations", "canvas", "dashboard", "gateway", "heartbeat_respond", "image_generate", "memory_get",
    "memory_search", "message", "music_generate", "show_widget", "skill_workshop", "tts", "video_generate",
    "web_fetch", "x_search",
})
EXEC_SHAPE_TRAP = frozenset({"deny", "allowlist"})


class Unreadable(Exception):
    """A config or registry that cannot be parsed: exit 2, never a pass."""


# ---------------------------------------------------------------- config reading
def agents_of(cfg: dict) -> dict:
    agents = cfg.get("agents") or {}
    if isinstance(agents.get("entries"), dict) and agents["entries"]:
        return {k: (v or {}) for k, v in agents["entries"].items()}
    if isinstance(agents.get("list"), list) and agents["list"]:
        return {a["id"]: a for a in agents["list"] if isinstance(a, dict) and a.get("id")}
    raise Unreadable("config has neither a non-empty agents.list nor agents.entries")


def _tools(obj) -> dict:
    t = (obj or {}).get("tools")
    return t if isinstance(t, dict) else {}


def expand(names) -> set:
    out = set()
    for n in names or []:
        out |= TOOL_GROUPS.get(n, {n})
    return out


def deny_set(cfg: dict, agent: dict) -> set:
    """Effective deny: global + agents.defaults + agent (openclaw unions every explicit deny layer)."""
    defaults = (cfg.get("agents") or {}).get("defaults") or {}
    return expand(_tools(cfg).get("deny")) | expand(_tools(defaults).get("deny")) | expand(_tools(agent).get("deny"))


def grants(cfg: dict, agent: dict) -> set:
    t, g = _tools(agent), _tools(cfg)
    return expand(t.get("allow")) | expand(t.get("alsoAllow")) | expand(g.get("allow")) | expand(g.get("alsoAllow"))


def runtime_of(cfg: dict, agent: dict) -> str:
    model = agent.get("model")
    primary = model.get("primary") if isinstance(model, dict) else model
    if not primary:
        dm = ((cfg.get("agents") or {}).get("defaults") or {}).get("model")
        primary = dm.get("primary") if isinstance(dm, dict) else dm
    provider = (primary or "").split("/", 1)[0]
    prov = ((cfg.get("models") or {}).get("providers") or {}).get(provider) or {}
    return ((prov.get("agentRuntime") or {}).get("id")) or "embedded"


def exec_mode(cfg: dict, agent: dict) -> str:
    """Layered like @openclaw/codex applyOpenClawExecPolicyLayer: a `mode` wins over `security` at each layer."""
    mode = "full"
    defaults = (cfg.get("agents") or {}).get("defaults") or {}
    for layer in (_tools(cfg).get("exec"), _tools(defaults).get("exec"), _tools(agent).get("exec")):
        if not isinstance(layer, dict):
            continue
        if layer.get("mode"):
            mode = layer["mode"]
        elif layer.get("security"):
            mode = {"full": "full", "deny": "deny", "allowlist": "allowlist"}.get(layer["security"], mode)
    return mode


def harness_restricted(cfg: dict, agent: dict) -> bool:
    deny = deny_set(cfg, agent)
    narrowing_allow = [a for a in (_tools(agent).get("allow") or []) if a != "*"] or \
                      [a for a in (_tools(cfg).get("allow") or []) if a != "*"]
    return bool(deny - CODEX_SAFE_DENY) or bool(narrowing_allow)


def reachable_shell(cfg: dict, agent: dict, tools=SHELL_TOOLS) -> set:
    """Shell surfaces this agent can still reach, modelled from config (static; the live probe is the runtime proof)."""
    deny, out = deny_set(cfg, agent), set()
    mode = exec_mode(cfg, agent)
    for tool in tools:
        if tool in deny:
            continue
        if tool == "exec" and mode == "deny":
            continue
        if tool == "lobster" and not ("lobster" in ((cfg.get("plugins") or {}).get("allow") or [])
                                      and "lobster" in grants(cfg, agent)):
            continue
        out.add(tool)
    if runtime_of(cfg, agent) == "codex" and not harness_restricted(cfg, agent) and mode == "full":
        out.add(NATIVE_SHELL)
    return out


def resolve_call(cfg: dict, agent: dict, tool_name: str) -> str:
    """'executes' if a call by this tool name would run a command for this agent, else 'refused'."""
    reach = reachable_shell(cfg, agent)
    canonical = ALIASES.get(tool_name, tool_name)
    if tool_name in ("bash", "shell", "exec_command"):  # codex names its native shell tool `bash`
        return "executes" if (NATIVE_SHELL in reach or "exec" in reach) else "refused"
    return "executes" if canonical in reach else "refused"


# ---------------------------------------------------------------- checks
def _date(value, where, errors):
    try:
        return dt.date.fromisoformat(str(value))
    except ValueError:
        errors.append(f"{where}: '{value}' is not a YYYY-MM-DD date")
        return None


def _check_grants(where: str, cfg: dict, agent: dict, entry: dict, errors: list) -> None:
    """A `grants` list is the reviewed width of a `full` posture, enforced against the CONFIG.

    Why this exists: on openclaw 2026.8.35 an allowlist exec mode is refused by the codex harness
    (EXEC_SHAPE_TRAP), so a narrow posture cannot be expressed as tools.exec. It is expressed instead as
    "full exec, every other shell surface denied", and this check refuses a registry row that claims a narrower
    width than the config grants, or a config that grants more than the row reviewed. Without it a narrowing
    would be a comment rather than a rule.
    """
    want = entry.get("grants")
    if want is None:
        return
    reach = reachable_shell(cfg, agent)
    extra = sorted(reach - set(want))
    missing = sorted(set(want) - reach)
    if extra:
        errors.append(f"{where}: posture=full grants {sorted(want)} but the config also reaches {extra} - "
                      "deny them, or widen the reviewed grants list")
    if missing:
        errors.append(f"{where}: posture=full grants {sorted(want)} but the config does not reach {missing}")


def check_profile(profile: str, cfg: dict, reg: dict, today: dt.date, errors: list, notes: list,
                  warnings: list | None = None) -> None:
    agents = agents_of(cfg)
    want = set(reg)
    for missing in sorted(set(agents) - want):
        errors.append(f"{profile}: agent '{missing}' is not in {REGISTRY} - every agent must declare its exec posture")
    for stale in sorted(want - set(agents)):
        errors.append(f"{profile}: {REGISTRY} lists '{stale}' but the config has no such agent - drop the entry")
    for aid in sorted(set(agents) & want):
        a, entry, where = agents[aid], reg[aid], f"{profile}:{aid}"
        posture = entry.get("posture")
        if runtime_of(cfg, a) == "codex" and exec_mode(cfg, a) in EXEC_SHAPE_TRAP:
            errors.append(f"{where}: effective tools.exec mode/security is '{exec_mode(cfg, a)}' on a codex-runtime "
                          "agent - @openclaw/codex refuses every such turn (AgentHarnessPreflightError) and the "
                          "fallback runner silently moves it to openrouter. Use tools.deny instead.")
        if posture == "denied":
            missing = [t for t in REQUIRED_DENY[profile] if t not in deny_set(cfg, a)]
            if missing:
                errors.append(f"{where}: posture=denied but tools.deny lacks {missing}")
            regrant = sorted(set(REQUIRED_DENY[profile]) & expand(_tools(a).get("allow")) |
                             set(REQUIRED_DENY[profile]) & expand(_tools(a).get("alsoAllow")))
            if regrant:
                errors.append(f"{where}: posture=denied but the agent's tools.allow/alsoAllow names {regrant}")
            reach = reachable_shell(cfg, a, REQUIRED_DENY[profile])
            if reach:
                errors.append(f"{where}: posture=denied but shell is still reachable via {sorted(reach)}")
            beyond = reachable_shell(cfg, a) - reach
            if beyond:  # outside this profile's rule (edge: the captain's list) - shown, never silently passed
                notes.append(f"::notice::{where}: not denied (outside {profile}'s REQUIRED_DENY): {sorted(beyond)}")
            if entry.get("since"):
                _date(entry["since"], f"{where}.since", errors)
            notes.append(f"{where}: denied ({len(_tools(a).get('deny') or [])} deny entries)")
        elif posture == "full":
            for k in ("reason", "exit", "ruling"):
                if not str(entry.get(k) or "").strip():
                    errors.append(f"{where}: posture=full needs a non-empty '{k}'")
            _check_grants(where, cfg, a, entry, errors)
            exp = _date(entry.get("expires"), f"{where}.expires", errors)
            if exp is not None:
                if today > exp:
                    errors.append(f"{where}: posture=full EXPIRED on {exp} - deny exec, or renew with a new ruling")
                elif (exp - today).days > MAX_EXPIRY_DAYS:
                    errors.append(f"{where}: expires {exp} is more than {MAX_EXPIRY_DAYS} days out")
                elif (exp - today).days <= EXPIRY_WARNING_DAYS:
                    # Inside the window the row must NOT read as `ok`: replace the clean note with the warning.
                    left = (exp - today).days
                    when = "TODAY" if left == 0 else f"in {left}d"
                    line = (f"{where}: full exception expires {exp} - {when} "
                            f"({EXPIRY_WARNING_DAYS}-day window)")
                    (warnings if warnings is not None else notes).append(line)
                    notes.append(
                        f"::warning::{line}. Renew it with a new ruling and a fresh exit plan, or deny exec, before "
                        "that date: on the day AFTER it lapses this check turns red and the deploy halts at Step 1. "
                        "Denying is the fail-safe; a renewal is a ruling, not a data edit.")
                else:
                    notes.append(f"{where}: full until {exp} ({(exp - today).days}d left)"
                                 + ("" if aid in OPS_AGENTS else " - non-ops, dated exception"))
        else:
            errors.append(f"{where}: posture must be 'denied' or 'full', got {posture!r}")


def check_base(profile: str, cfg: dict, reg: dict, base_cfg, base_reg, errors: list, notes: list) -> None:
    """Rules that need the base branch: no re-grant, no new agent at full, extensions are visible."""
    if base_cfg is None:
        # git_show() only returns None for a VERIFIED-absent path on a readable ref; an unreadable ref raises
        # Unreadable (exit 2) instead. So this is a new config on a valid base, not a skipped comparison.
        notes.append(f"{profile}: verified absent on base")
        # A brand-new profile is brand-new agents: the new-agent prohibition applies to every one of them. Skipping
        # it here let a PR add `openclaw-foo.json` with its first agent at posture=full and still report clean
        # (qa-review finding 4455377794).
        for aid, entry in sorted(reg.items()):
            if entry.get("posture") == "full":
                errors.append(f"{profile}:{aid}: a NEW profile cannot start with exec (posture=full); "
                              f"declare it denied")
        return
    base_agents = agents_of(base_cfg)
    for aid, entry in sorted(reg.items()):
        if entry.get("posture") != "full":
            continue
        if aid not in base_agents:
            errors.append(f"{profile}:{aid}: a NEW agent cannot start with exec (posture=full); declare it denied")
            continue
        base_denied = "exec" in deny_set(base_cfg, base_agents[aid]) or \
            ((base_reg or {}).get(aid) or {}).get("posture") == "denied"
        if base_denied:
            msg = f"{profile}:{aid}: RE-GRANT - exec is denied on base and this change gives it back"
            claim = REGRANT_ALLOWLIST.get((profile, aid))
            if claim and str(claim["expires"]) == str(entry.get("expires")):
                # The reviewed route: this script carries a claim naming the agent, the ruling and THIS expiry.
                notes.append(msg + f" (REVIEWED re-grant per {claim['ruling']}, expires {claim['expires']}, "
                                    f"grants {sorted(claim['grants'])} - reviewer must see this)")
                if str(claim["ruling"]) not in str(entry.get("ruling") or ""):
                    errors.append(f"{profile}:{aid}: RE-GRANT claim {claim['ruling']} is not cited in the "
                                  "registry row's `ruling` field")
            elif claim:
                errors.append(f"{profile}:{aid}: RE-GRANT - reviewed claim {claim['ruling']} authorises "
                              f"{claim['expires']} but the registry says {entry.get('expires')!r}; the claim and "
                              "the data must name the same expiry")
            elif aid in OPS_AGENTS:
                notes.append(msg + " (ops agent: allowed, reviewer must see this)")
            else:
                errors.append(msg + " (non-ops agent: never; a re-grant needs a change to this script's rules)")
        old = ((base_reg or {}).get(aid) or {}).get("expires")
        if old and entry.get("expires") and str(entry["expires"]) > str(old):
            notes.append(f"::warning::{profile}:{aid}: expiry EXTENDED {old} -> {entry['expires']} - needs a ruling")


def check_live(profile: str, repo_cfg: dict, live_cfg: dict, errors: list, notes: list) -> None:
    r, l = agents_of(repo_cfg), agents_of(live_cfg)
    if set(r) != set(l):
        errors.append(f"{profile}: live agents {sorted(l)} != repo agents {sorted(r)}")
    if _tools(repo_cfg).get("exec") != _tools(live_cfg).get("exec"):
        errors.append(f"{profile}: live tools.exec {_tools(live_cfg).get('exec')} != repo {_tools(repo_cfg).get('exec')}")
    for aid in sorted(set(r) & set(l)):
        rd, ld = sorted(_tools(r[aid]).get("deny") or []), sorted(_tools(l[aid]).get("deny") or [])
        if rd != ld:
            errors.append(f"{profile}:{aid}: live tools.deny ({len(ld)}) != repo ({len(rd)}); "
                          f"only-live={sorted(set(ld) - set(rd))} only-repo={sorted(set(rd) - set(ld))}")
        elif rd:
            notes.append(f"{profile}:{aid}: live deny == repo deny ({len(rd)})")
        if _tools(r[aid]).get("exec") != _tools(l[aid]).get("exec"):
            errors.append(f"{profile}:{aid}: live tools.exec differs from repo")


# ---------------------------------------------------------------- io
def load(path: Path) -> dict:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        raise Unreadable(f"cannot read {path}: {exc}") from exc


def git_show(ref: str, rel: str, root: Path):
    """`rel` as it exists on `ref`, or None ONLY when `ref` is readable and the path is genuinely absent there.

    Fail closed: an unreadable base ref (unfetched, shallow clone, not a repo, bad object) raises Unreadable ->
    exit 2, never a pass. Returning None for those would silently disable every base comparison in check_base()
    and let a re-grant of exec to scout/Caroline merge green (qa-review finding on PR #1627, 2026-11-01).
    """
    def git(*args: str) -> subprocess.CompletedProcess:
        return subprocess.run(["git", "-C", str(root), *args], capture_output=True, text=True)

    if git("rev-parse", "--verify", "--quiet", f"{ref}^{{commit}}").returncode != 0:
        raise Unreadable(f"cannot verify base ref {ref!r}: fetch it, or pass a ref that exists "
                         f"(CI: actions/checkout needs fetch-depth: 0)")
    tree = git("ls-tree", "--name-only", ref, "--", rel)
    if tree.returncode != 0:
        raise Unreadable(f"cannot list {rel} on base {ref}: {tree.stderr.strip()}")
    if not tree.stdout.strip():
        return None  # verified absent on a readable base (this PR adds the file)
    shown = git("show", f"{ref}:{rel}")
    if shown.returncode != 0:
        raise Unreadable(f"cannot read {ref}:{rel}: {shown.stderr.strip()}")
    try:
        return json.loads(shown.stdout)
    except ValueError as exc:
        raise Unreadable(f"{ref}:{rel} is not JSON: {exc}") from exc


def run(root: Path = REPO, base: str | None = None, live: bool = False, today: dt.date | None = None,
        live_paths: dict | None = None, live_profiles=None,
        fail_on_expiring: bool = False) -> tuple[int, list, list]:
    """`fail_on_expiring` turns the pre-expiry warning into rc 4 (clean but expiring). Deploy and PR CI leave it off:
    an approaching expiry must never block the deploy that carries the fix, while the watchdog wants an exit code it
    can page on without parsing prose."""
    today = today or dt.datetime.now(dt.timezone.utc).date()
    errors, warnings, notes = [], [], []
    # A partial deploy (--target main|edge) must not be blocked by a profile it never touched: `live_profiles`
    # scopes the LIVE comparison only. Every other rule still runs for every profile.
    scope = None if live_profiles is None else {
        p if p.endswith(".json") else f"openclaw-{p}.json" for p in live_profiles}
    if scope is not None:
        unknown = sorted(scope - set(LIVE_CONFIG))
        if unknown:
            return 2, [f"--live-profile: no live path constant for {unknown} (known: {sorted(LIVE_CONFIG)})"], notes
        live = True
    try:
        registry = load(root / REGISTRY)
        if registry.get("version") != 1 or not isinstance(registry.get("profiles"), dict):
            raise Unreadable(f"{REGISTRY}: expected version 1 with a profiles object")
        on_disk = sorted(p.name for p in root.glob("openclaw-*.json"))
        for name in on_disk:
            if name not in registry["profiles"]:
                errors.append(f"{name}: profile is not in {REGISTRY}")
            if name not in REQUIRED_DENY:
                errors.append(f"{name}: no REQUIRED_DENY rule for this profile in {Path(__file__).name}")
        for name in registry["profiles"]:
            if name not in on_disk:
                errors.append(f"{REGISTRY}: profile {name} has no config file at the repo root")
        base_reg = git_show(base, REGISTRY, root) if base else None
        for profile in on_disk:
            if profile not in registry["profiles"] or profile not in REQUIRED_DENY:
                continue
            cfg, reg = load(root / profile), registry["profiles"][profile]
            check_profile(profile, cfg, reg, today, errors, notes, warnings)
            if base:
                check_base(profile, cfg, reg, git_show(base, profile, root),
                           ((base_reg or {}).get("profiles") or {}).get(profile), errors, notes)
            if live and (scope is None or profile in scope):
                live_cfg = load(Path((live_paths or LIVE_CONFIG)[profile]))
                check_live(profile, cfg, live_cfg, errors, notes)
                # The posture rules must also hold on what node-8 actually runs, not only on the repo copy.
                lerr: list = []
                check_profile(profile, live_cfg, reg, today, lerr, [])
                errors.extend(f"LIVE {e}" for e in lerr)
    except Unreadable as exc:
        return RC_UNREADABLE, [str(exc)], notes
    if errors:
        return RC_VIOLATION, errors, notes
    return (RC_EXPIRING if (fail_on_expiring and warnings) else RC_CLEAN), errors, notes


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--base", help="git ref to compare against (PR CI: origin/main). An unreadable ref exits 2, "
                                    "never 0 - the guard cannot silently skip its base comparison")
    ap.add_argument("--live", action="store_true", help="also compare node-8 live configs (post-deploy)")
    ap.add_argument("--live-profile", action="append", metavar="main|edge",
                    help="limit the --live comparison to these profiles (a partial deploy must not be blocked "
                         "by a profile it does not target); implies --live")
    ap.add_argument("--fail-on-expiring", action="store_true",
                    help="exit 4 when a dated full exception is inside the pre-expiry warning window (the watchdog "
                         "pages on this). Off for deploy and PR CI: an approaching expiry must not block a deploy")
    args = ap.parse_args(argv)
    rc, errors, notes = run(base=args.base, live=args.live, live_profiles=args.live_profile,
                            fail_on_expiring=args.fail_on_expiring)
    for n in notes:
        print(f"ok   {n}" if not n.startswith("::") else n)
    for e in errors:
        print(f"FAIL {e}")
    print({RC_CLEAN: "agent exec policy: clean", RC_VIOLATION: f"agent exec policy: {len(errors)} violation(s)",
           RC_UNREADABLE: "agent exec policy: UNREADABLE input - not a pass",
           RC_EXPIRING: "agent exec policy: clean, but a dated exception is inside the pre-expiry window - "
                        "renew or deny before it lapses"}[rc])
    return rc


if __name__ == "__main__":
    sys.exit(main())
