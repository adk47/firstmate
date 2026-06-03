#!/usr/bin/env python3
"""
HYDRA Daily Self-Improvement Audit
===================================
Runs daily via cron on node-8. Posts digest to #clio_devops.

Checks:
1. Agent health — success/error rates, unanswered messages
2. Memory bloat — warns if any agent MEMORY.md exceeds threshold
3. Stale LXC containers — counts IPv4 warnings
4. Config drift — agents missing from expected list
5. OpenClaw releases — checks GitHub for new versions
6. OpenClaw PRs — scans for high-value PRs that could benefit HYDRA
7. Improvement suggestions — actionable items based on findings

Schedule (node-8): hydra-daily-audit.timer fires daily at 08:00 UTC and runs
hydra-daily-audit.service (ExecStart = this script). Installed by
scripts/install-aux-units.sh. Set HYDRA_AUDIT_DRY_RUN=1 to print the digest
without posting to Slack.
"""
import json
import urllib.request
import urllib.error
import time
import os
import glob
import re

CONFIG_PATH = os.environ.get("HYDRA_AUDIT_CONFIG", "/root/.openclaw-main/openclaw.json")
EDGE_CONFIG_PATH = os.environ.get("HYDRA_AUDIT_EDGE_CONFIG", "/root/.openclaw-edge/openclaw.json")
WORKSPACE_ROOT = "/opt/hydra/workspaces"
MEMORY_BLOAT_CHARS = 15000      # latency/cost hygiene warning (tiered-memory target ~3500)
MEMORY_TRUNCATE_CHARS = 40000   # real bootstrap cap; see openclaw-main.json:192 (PR #165)
SLACK_CHANNEL = "C0ADV2W76G4"  # #clio_devops
OPENCLAW_REPO = "openclaw/openclaw"  # GitHub repo for releases/PRs
WATCHED_REPOS = [
    "openclaw/openclaw",
]
# PRs/features we're watching (from reference)
WATCHED_PR_NUMBERS = [33309, 31592, 29793, 33223, 34334, 34536]

AUDIT_STATE_FILE = "/tmp/hydra-daily-audit-state.json"

def load_config():
    with open(CONFIG_PATH) as f:
        return json.load(f)

def load_edge_config():
    """Load the edge (CS/Intercom) gateway config; None if absent/unreadable."""
    try:
        with open(EDGE_CONFIG_PATH) as f:
            return json.load(f)
    except Exception:
        return None

def intercom_search(token, payload):
    """POST /conversations/search (Intercom v2.11), with 429 retry.

    Pattern mirrors scripts/cs-analysis/fetch-conversations.py. Returns parsed JSON.
    """
    req = urllib.request.Request(
        "https://api.intercom.io/conversations/search",
        data=json.dumps(payload).encode(),
        headers={
            "Authorization": "Bearer " + token,
            "Accept": "application/json",
            "Content-Type": "application/json",
            "Intercom-Version": "2.11",
        }, method="POST")
    for attempt in range(3):
        try:
            return json.loads(urllib.request.urlopen(req, timeout=30).read())
        except urllib.error.HTTPError as e:
            if e.code == 429 and attempt < 2:
                time.sleep(int(e.headers.get("Retry-After", 5)))
                continue
            raise

def slack_api(token, method, params=""):
    url = "https://slack.com/api/" + method
    if params:
        url += "?" + params
    req = urllib.request.Request(url, headers={"Authorization": "Bearer " + token})
    return json.loads(urllib.request.urlopen(req, timeout=15).read())

def slack_post(token, channel, text):
    data = json.dumps({"channel": channel, "text": text, "unfurl_links": False}).encode()
    req = urllib.request.Request(
        "https://slack.com/api/chat.postMessage",
        data=data,
        headers={"Authorization": "Bearer " + token, "Content-Type": "application/json"})
    try:
        return json.loads(urllib.request.urlopen(req, timeout=10).read()).get("ok", False)
    except Exception:
        return False

_GH_TOKEN_CACHE = []   # one-element lazy cache so `gh auth token` runs at most once
_LAST_GH_ERROR = [""]  # reason for the most recent github_api() failure


def github_token():
    """Best-effort GitHub token: env first, else the box's gh CLI (authed as adk47).

    Lifts the unauthenticated 60/hr limit to 5000/hr. Returns "" if unavailable.
    """
    if _GH_TOKEN_CACHE:
        return _GH_TOKEN_CACHE[0]
    tok = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN") or ""
    if not tok:
        try:
            import subprocess
            tok = subprocess.run(["gh", "auth", "token"],
                                 capture_output=True, text=True, timeout=10).stdout.strip()
        except Exception:
            tok = ""
    _GH_TOKEN_CACHE.append(tok)
    return tok


def github_api(path):
    """Call the GitHub API (authenticated when a token is available).

    Returns parsed JSON on success, or None on failure with the reason stashed in
    _LAST_GH_ERROR so callers can report 404 vs rate-limit vs network honestly.
    """
    url = "https://api.github.com/" + path
    headers = {"Accept": "application/vnd.github+json", "User-Agent": "HYDRA-Audit/1.0"}
    tok = github_token()
    if tok:
        headers["Authorization"] = "Bearer " + tok
    req = urllib.request.Request(url, headers=headers)
    try:
        return json.loads(urllib.request.urlopen(req, timeout=15).read())
    except urllib.error.HTTPError as e:
        if e.code == 404:
            _LAST_GH_ERROR[0] = "repo/path not found (404)"
        elif e.code in (403, 429):
            _LAST_GH_ERROR[0] = "rate limited (HTTP " + str(e.code) + ")"
        else:
            _LAST_GH_ERROR[0] = "HTTP " + str(e.code)
        return None
    except Exception as e:
        _LAST_GH_ERROR[0] = "unreachable: " + str(e)[:80]
        return None

def load_state():
    try:
        with open(AUDIT_STATE_FILE) as f:
            return json.load(f)
    except Exception:
        return {}

def save_state(state):
    with open(AUDIT_STATE_FILE, "w") as f:
        json.dump(state, f)


def audit_agent_health(config):
    """24h MAIN-gateway agent health from journald.

    Edge (CS/Intercom) is Intercom-event-driven and has no `run=` agent turns, so
    it gets its own section (audit_edge_gateway); this stays scoped to main to avoid
    misrepresenting edge. The current openclaw log format does NOT emit per-run
    success markers (the pre-2026 `isError=true/false` markers are gone), so we
    measure two things directly instead of a synthetic success rate:
      - activity:  distinct `session=agent:<name>:<kind> run=<uuid>` pairs (agent turns)
      - failures:  `[diagnostic] message processed: ... outcome=error ... error="..."` lines
    """
    findings = []
    try:
        import subprocess
        logs = subprocess.run(
            ["journalctl", "-u", "openclaw-gateway-main",
             "--since", "24 hours ago", "--no-pager"],
            capture_output=True, text=True, timeout=60
        ).stdout
    except Exception as e:
        findings.append(("health", "error", "Could not read journalctl: " + str(e)))
        return findings

    # Activity: count distinct run= UUIDs per agent (one turn can log many lines).
    runs_by_agent = {}
    seen_runs = set()
    for m in re.finditer(r"session=agent:([a-z0-9_-]+):[a-z]+ run=([0-9a-f-]{36})", logs):
        agent, run_id = m.group(1), m.group(2)
        if run_id in seen_runs:
            continue
        seen_runs.add(run_id)
        runs_by_agent[agent] = runs_by_agent.get(agent, 0) + 1

    if seen_runs:
        top = sorted(runs_by_agent.items(), key=lambda kv: -kv[1])
        summary = ", ".join(a + " " + str(n) for a, n in top)
        findings.append(("health", "info",
            str(len(seen_runs)) + " agent runs across " + str(len(runs_by_agent))
            + " agents in 24h (" + summary + ")"))
    else:
        findings.append(("health", "warn",
            "No agent runs recorded in last 24h - gateway may be down or not logging"))

    # Idle detection: expected (configured) agents with zero runs.
    expected = {a["id"] for a in config.get("agents", {}).get("list", [])}
    idle = sorted(expected - set(runs_by_agent))
    if idle:
        findings.append(("health", "info", "No runs in 24h from: " + ", ".join(idle)))

    # Failures: outcome=error from the structured 'message processed' diagnostic.
    error_reasons = {}
    err_total = 0
    for line in logs.splitlines():
        if "message processed:" not in line or "outcome=error" not in line:
            continue
        err_total += 1
        em = re.search(r'error="(.*?)"', line)
        reason = (em.group(1) if em else "unknown")[:120]
        error_reasons[reason] = error_reasons.get(reason, 0) + 1
    if err_total > 0:
        findings.append(("health", "warn", str(err_total) + " run failures in 24h:"))
        for reason, count in sorted(error_reasons.items(), key=lambda kv: -kv[1])[:3]:
            findings.append(("health", "warn", "  ↳ " + str(count) + "× " + reason))

    # Infrastructure markers (still grepped as plain substrings).
    timeouts = logs.count("idle timed out") + logs.count("reason=timeout")
    overloaded = logs.count("overloaded_error")
    stale_sockets = logs.count("stale-socket")
    no_ipv4 = logs.count("no IPv4 address")
    if timeouts > 0:
        findings.append(("health", "warn", str(timeouts) + " turn-timeout events"))
    if overloaded > 0:
        findings.append(("health", "warn", str(overloaded) + " API overloaded errors"))
    if stale_sockets > 3:
        findings.append(("health", "warn", str(stale_sockets) + " stale socket restarts"))
    if no_ipv4 > 0:
        findings.append(("lxc", "warn", str(no_ipv4) + " LXC containers missing IPv4 (NemoClaw issue)"))

    return findings


def audit_edge_gateway():
    """24h health of the EDGE gateway (CS/Caroline on Intercom) from journald.

    Edge is Intercom-event-driven, so we measure the event flow — not agent runs.
    A 24h with zero `[intercom]` events is the silent-CS-outage failure mode that ran
    14 days undetected in April 2026 (hydra #... / intercom webhook outage).
    """
    findings = []
    try:
        import subprocess
        logs = subprocess.run(
            ["journalctl", "-u", "openclaw-gateway-edge",
             "--since", "24 hours ago", "--no-pager"],
            capture_output=True, text=True, timeout=60
        ).stdout
    except Exception as e:
        findings.append(("edge", "error", "Could not read edge journalctl: " + str(e)))
        return findings

    intercom_events = logs.count("[intercom]")
    new_convs = logs.count("conversation.user.created")
    user_events = len(re.findall(r"\[intercom\][^\n]*conversation\.user\.", logs))
    # Caroline's outbound replies: the gateway logs each delivered reply as
    # `[intercom:default] replied conv=<id> partId=<id> chunks=<n>`. Count distinct
    # conversations (raw lines double-count multi-part / follow-up replies). The old
    # `sessionKey=agent:support:` marker only hits diagnostic lines and undercounts
    # by ~100× (2 vs ~558 real replies in 24h).
    reply_convs = set(re.findall(r"\[intercom:default\] replied conv=(\d+)", logs))
    reply_msgs = len(re.findall(r"\[intercom:default\] replied conv=\d+", logs))

    # Liveness / silent-outage guard — the headline edge check.
    if intercom_events == 0:
        findings.append(("edge", "critical",
            "Edge Intercom pipeline appears DOWN - no webhook events in 24h (possible silent CS outage)"))
        return findings
    findings.append(("edge", "ok", "Intercom pipeline healthy (" + str(intercom_events) + " events in 24h)"))
    findings.append(("edge", "info",
        str(new_convs) + " new conversations, " + str(user_events) + " customer events in 24h"))
    findings.append(("edge", "info",
        "Caroline replied in " + str(len(reply_convs)) + " conversations ("
        + str(reply_msgs) + " messages) in 24h"))

    # Edge errors. Thresholds are set above the normal daily baseline (~29 invalid/day,
    # 0 lane-waits) so healthy days stay quiet — only anomalies surface.
    invalid = logs.count("] invalid ")
    oversized = logs.count("dropped oversized")
    lane_waits = logs.count("lane wait exceeded")
    edge_run_errors = sum(1 for ln in logs.splitlines()
                          if "message processed:" in ln and "outcome=error" in ln)
    if invalid > 100:
        findings.append(("edge", "warn", str(invalid) + " invalid webhook events (elevated)"))
    if oversized > 0:
        findings.append(("edge", "warn", str(oversized) + " oversized payloads dropped"))
    if lane_waits > 0:
        findings.append(("edge", "warn", str(lane_waits) + " lane-wait (queue backpressure) events"))
    if edge_run_errors > 2:
        findings.append(("edge", "warn", str(edge_run_errors) + " support-agent run failures"))

    return findings


def audit_cs_responsiveness(edge_config):
    """CS responsiveness from the Intercom API, scoped to the LAST 24h.

    Deliberately does NOT report the all-time waiting backlog (currently ~1.4k, a known
    *paused* state — see queue-cleanup) which would be daily noise. Instead: of the
    conversations that arrived in the last 24h, how many got a reply, and which recent
    ones are still stranded. journald counts are inflated by webhook redelivery, so the
    reply rate needs the API. Fail-soft: any error → one warn line, never crash.
    """
    findings = []
    token = ""
    if edge_config:
        token = (edge_config.get("channels", {}).get("intercom", {})
                 .get("accounts", {}).get("default", {}).get("token", ""))
    if not token:
        findings.append(("cs", "warn", "No Intercom token in edge config - skipped CS responsiveness"))
        return findings

    now = int(time.time())
    since = now - 24 * 3600
    convs = []
    total_new = 0
    try:
        starting_after = None
        for _ in range(3):  # cap at 3 pages (≤450) — ample for daily volume
            pg = {"per_page": 150}
            if starting_after:
                pg["starting_after"] = starting_after
            page = intercom_search(token, {
                "query": {"field": "created_at", "operator": ">", "value": since},
                "pagination": pg})
            convs.extend(page.get("conversations", []))
            total_new = page.get("total_count", len(convs))
            starting_after = ((page.get("pages") or {}).get("next") or {}).get("starting_after")
            if not starting_after:
                break
    except Exception as e:
        findings.append(("cs", "warn", "Could not reach Intercom: " + str(e)[:80]))
        return findings

    if not convs:
        findings.append(("cs", "ok", "No new conversations in 24h"))
        return findings

    answered = [c for c in convs if (c.get("statistics") or {}).get("first_admin_reply_at")]
    by_ai = sum(1 for c in convs if c.get("ai_agent_participated"))
    rate = round(len(answered) / len(convs) * 100, 1)
    extra = (" (" + str(by_ai) + " by Caroline)") if by_ai else ""
    findings.append(("cs", "info",
        str(total_new) + " new conversations in 24h, " + str(len(answered)) + "/"
        + str(len(convs)) + " answered (" + str(rate) + "%)" + extra))

    # Recently stranded: created >2h ago (not just-arrived), still open, no admin reply.
    stranded = [c for c in convs
                if not (c.get("statistics") or {}).get("first_admin_reply_at")
                and c.get("state") == "open"
                and (c.get("created_at") or now) < now - 2 * 3600]
    if stranded:
        findings.append(("cs", "warn",
            str(len(stranded)) + " conversations from the last 24h still unanswered (>2h, no admin reply)"))
        for c in stranded[:5]:
            findings.append(("cs", "info", "  ↳ conv " + str(c.get("id"))))

    return findings


def audit_memory_sizes():
    """Check all agent MEMORY.md files for bloat."""
    findings = []
    for md in glob.glob(WORKSPACE_ROOT + "/*/MEMORY.md"):
        agent = md.split("/")[-2]
        try:
            with open(md, encoding="utf-8", errors="replace") as fh:
                size = len(fh.read())
            if size > MEMORY_TRUNCATE_CHARS:
                findings.append(("memory", "critical",
                    "@" + agent + " MEMORY.md is " + str(size) + " chars (cap " + str(MEMORY_TRUNCATE_CHARS) + ") - WILL be truncated at bootstrap, may cause timeouts"))
            elif size > MEMORY_BLOAT_CHARS:
                findings.append(("memory", "warn",
                    "@" + agent + " MEMORY.md is " + str(size) + " chars - over the "
                    + str(MEMORY_BLOAT_CHARS) + "-char warn threshold (hard cap "
                    + str(MEMORY_TRUNCATE_CHARS) + ", not yet truncated); prune via the weekly "
                    "self-improve loop (muso-devops-self-improve)"))
        except Exception:
            pass
    if not findings:
        findings.append(("memory", "ok", "All agent memories within limits"))
    return findings


def audit_unanswered(config):
    """Scan for unanswered @mentions in last 24h."""
    findings = []
    accounts = ["clio", "ceo", "cmo", "cto", "qa", "finance", "operations", "devops", "design", "support"]
    oldest = str(int(time.time()) - 24 * 3600)

    bot_ids = set()
    tokens = {}
    acct_to_bot = {}
    for acct in accounts:
        token = config.get("channels", {}).get("slack", {}).get("accounts", {}).get(acct, {}).get("botToken", "")
        if not token:
            continue
        tokens[acct] = token
        try:
            bid = slack_api(token, "auth.test").get("user_id", "")
            bot_ids.add(bid)
            acct_to_bot[acct] = bid
        except Exception:
            pass

    unanswered_count = 0
    answered_count = 0
    unanswered_items = []  # (acct, channel-label) for the ones we'll list
    seen = set()

    for acct in accounts:
        token = tokens.get(acct, "")
        if not token:
            continue
        my_bot_id = acct_to_bot.get(acct, "")
        if not my_bot_id:
            continue

        for conv_type in ["public_channel,private_channel", "im"]:
            try:
                resp = slack_api(token, "users.conversations",
                    "types=" + conv_type + "&limit=200&exclude_archived=true")
            except Exception:
                continue

            for ch in resp.get("channels", []):
                ch_id = ch.get("id", "")
                key = acct + ":" + ch_id
                if key in seen:
                    continue
                seen.add(key)
                ch_label = ("#" + ch["name"]) if ch.get("name") else ("DM" if ch.get("is_im") else ch_id)

                try:
                    hist = slack_api(token, "conversations.history",
                        "channel=" + ch_id + "&oldest=" + oldest + "&limit=100")
                except Exception:
                    continue

                msgs = hist.get("messages", [])
                msgs_chrono = list(reversed(msgs))

                for i, msg in enumerate(msgs_chrono):
                    sender = msg.get("user", "")
                    if sender in bot_ids or msg.get("bot_id"):
                        continue
                    text = msg.get("text", "")
                    if my_bot_id and ("<@" + my_bot_id + ">" in text):
                        # Top-level reply by this bot anywhere later in the channel?
                        replied = any(
                            msgs_chrono[j].get("user") == my_bot_id
                            for j in range(i + 1, len(msgs_chrono))
                        )
                        # Else check the thread: bots usually reply in-thread, which
                        # conversations.history does not surface. This was the main
                        # undercount source.
                        if not replied:
                            thread_ts = msg.get("thread_ts") or msg.get("ts")
                            if thread_ts:
                                try:
                                    rep = slack_api(token, "conversations.replies",
                                        "channel=" + ch_id + "&ts=" + thread_ts + "&limit=50")
                                    replied = any(r.get("user") == my_bot_id
                                                  for r in rep.get("messages", []))
                                except Exception:
                                    pass
                        if replied:
                            answered_count += 1
                        else:
                            unanswered_count += 1
                            unanswered_items.append((acct, ch_label))

    findings = []
    total = answered_count + unanswered_count
    if total > 0:
        rate = round(answered_count / total * 100, 1)
        findings.append(("response", "info",
            str(answered_count) + "/" + str(total) + " @mentions answered (" + str(rate) + "%)"))
    if unanswered_count > 0:
        # Only alarm when it's actually concerning; a couple of stragglers is FYI.
        # (The "agents stuck / API degraded" improvement suggestion keys off this warn.)
        lvl = "warn" if (rate < 80 or unanswered_count >= 5) else "info"
        findings.append(("response", lvl,
            str(unanswered_count) + " unanswered @mentions in last 24h"))
        # List a few so it's actionable, not just a percentage. Dedup repeats.
        shown = []
        for acct, label in unanswered_items:
            tag = "@" + acct + " in " + label
            if tag not in shown:
                shown.append(tag)
        for tag in shown[:5]:
            findings.append(("response", "info", "  ↳ " + tag))
    elif total > 0:
        findings.append(("response", "ok", "All @mentions answered"))

    return findings


def _check_profile_config(profile, cfg, expected_agents):
    """Validate one gateway profile's agent roster + workspaces. Returns findings."""
    findings = []
    if cfg is None:
        findings.append(("config", "warn", profile + ": config unreadable"))
        return findings
    actual = {a["id"] for a in cfg.get("agents", {}).get("list", [])}
    missing = expected_agents - actual
    extra = actual - expected_agents
    if missing:
        findings.append(("config", "warn", profile + ": missing agents: " + ", ".join(sorted(missing))))
    if extra:
        findings.append(("config", "info", profile + ": extra agents: " + ", ".join(sorted(extra))))
    for agent in cfg.get("agents", {}).get("list", []):
        ws = agent.get("workspace", "")
        if ws and not os.path.isdir(ws):
            findings.append(("config", "warn", profile + ": @" + agent["id"] + " workspace missing: " + ws))
    if not missing and not extra:
        findings.append(("config", "ok", profile + ": " + str(len(actual)) + " agents OK"))
    return findings


def audit_config(config, edge_config):
    """Check for config drift across both gateway profiles.

    main roster = the 9 real agents; edge roster = {support} (Caroline). Listing
    support/sentinel as main-expected used to fire a permanent false "missing" alarm.
    """
    findings = []
    findings += _check_profile_config("main",
        config, {"clio", "ceo", "cmo", "cto", "qa", "finance", "operations", "devops", "design"})
    findings += _check_profile_config("edge", edge_config, {"support"})
    return findings


def audit_openclaw_releases(state):
    """Check for new OpenClaw releases on GitHub."""
    findings = []
    last_seen = state.get("last_release", "")

    releases = github_api("repos/" + OPENCLAW_REPO + "/releases?per_page=5")
    if releases is None:
        findings.append(("releases", "warn", "Could not check OpenClaw releases: " + _LAST_GH_ERROR[0]))
        return findings, state

    new_releases = []
    for rel in releases:
        tag = rel.get("tag_name", "")
        if tag == last_seen:
            break
        name = rel.get("name", tag)
        url = rel.get("html_url", "")
        prerelease = rel.get("prerelease", False)
        new_releases.append((tag, name, url, prerelease))

    if new_releases:
        state["last_release"] = new_releases[0][0]
        for tag, name, url, pre in new_releases:
            label = " (pre-release)" if pre else ""
            findings.append(("releases", "info",
                "New OpenClaw release: *" + name + "*" + label + " - " + url))
    else:
        findings.append(("releases", "ok", "No new OpenClaw releases (current: " + (last_seen or "unknown") + ")"))

    return findings, state


def audit_watched_prs(state):
    """Check status of watched PRs and scan for new high-value PRs."""
    findings = []
    last_pr_check = state.get("last_pr_scan_id", 0)

    # Check watched PRs
    for pr_num in WATCHED_PR_NUMBERS:
        pr = github_api("repos/" + OPENCLAW_REPO + "/pulls/" + str(pr_num))
        if not pr:
            continue
        title = pr.get("title", "")
        merged = pr.get("merged", False)
        # Only the merged case is actionable ("adopt this"). Closed-not-merged is
        # terminal and has no dedup state, so reporting it would repeat forever.
        if merged:
            findings.append(("prs", "info",
                "Watched PR #" + str(pr_num) + " *MERGED*: " + title + " - consider adopting"))

    # Scan recent PRs for security/agent-relevant keywords
    prs = github_api("repos/" + OPENCLAW_REPO + "/pulls?state=open&sort=created&direction=desc&per_page=20")
    if prs:
        keywords = ["security", "injection", "sandbox", "audit", "memory", "agent", "heartbeat",
                     "slack", "failover", "quarantine", "trust", "cron", "watchdog"]
        new_interesting = []
        for pr in prs:
            pr_id = pr.get("number", 0)
            if pr_id <= last_pr_check:
                continue
            title = (pr.get("title", "") + " " + (pr.get("body", "") or "")[:200]).lower()
            matched = [k for k in keywords if k in title]
            if matched:
                new_interesting.append((pr["number"], pr.get("title", ""), pr.get("html_url", ""), matched))

        if new_interesting:
            state["last_pr_scan_id"] = max(pr.get("number", 0) for pr in prs)
            for num, title, url, kws in new_interesting[:5]:
                findings.append(("prs", "info",
                    "New PR #" + str(num) + ": " + title + " (tags: " + ", ".join(kws) + ") - " + url))

    if not findings:
        findings.append(("prs", "ok", "No new relevant PRs"))

    return findings, state


def build_digest(all_findings):
    """Build the Slack message."""
    icons = {"ok": ":white_check_mark:", "info": ":information_source:", "warn": ":warning:", "critical": ":rotating_light:", "error": ":x:"}

    sections = {}
    for category, level, msg in all_findings:
        if category not in sections:
            sections[category] = []
        sections[category].append((level, msg))

    labels = {
        "health": "Agent Health",
        "memory": "Memory Audit",
        "lxc": "NemoClaw Containers",
        "response": "Response Rate",
        "edge": "Edge / CS Gateway",
        "cs": "CS Responsiveness",
        "config": "Configuration",
        "releases": "OpenClaw Releases",
        "prs": "Community PRs",
        "improve": "Improvement Suggestions",
    }

    lines = [":octopus: *HYDRA Daily Audit* - " + time.strftime("%b %d, %Y", time.gmtime())]
    lines.append("")

    for cat in ["health", "response", "edge", "cs", "memory", "lxc", "config", "releases", "prs", "improve"]:
        items = sections.get(cat, [])
        if not items:
            continue
        lines.append("*" + labels.get(cat, cat) + "*")
        for level, msg in items:
            lines.append(icons.get(level, ":grey_question:") + " " + msg)
        lines.append("")

    return "\n".join(lines)


def generate_improvements(all_findings):
    """Generate actionable improvement suggestions based on findings."""
    improvements = []

    has_memory_warn = any(cat == "memory" and lvl in ("warn", "critical") for cat, lvl, _ in all_findings)
    has_unanswered = any(cat == "response" and lvl == "warn" for cat, lvl, _ in all_findings)
    has_lxc = any(cat == "lxc" for cat, lvl, _ in all_findings)
    has_timeouts = any("timeout" in msg for _, _, msg in all_findings)
    has_merged_pr = any("MERGED" in msg for cat, _, msg in all_findings if cat == "prs")
    edge_down = any(cat == "edge" and lvl == "critical" for cat, lvl, _ in all_findings)
    cs_stranded = any(cat == "cs" and "still unanswered" in msg for cat, _, msg in all_findings)

    if edge_down:
        improvements.append(("improve", "critical",
            "CS Intercom pipeline appears down - check edge gateway + Intercom webhook delivery"))
    if cs_stranded:
        improvements.append(("improve", "warn",
            "Recent CS conversations unanswered - check Caroline coverage / human handoff"))
    if has_memory_warn:
        improvements.append(("improve", "warn",
            "Agent memory bloat detected - consider moving operational data to reference/ files"))
    if has_unanswered:
        improvements.append(("improve", "warn",
            "Unanswered messages found - check if agents are stuck or API is degraded"))
    if has_lxc:
        improvements.append(("improve", "info",
            "LXC IPv4 issues persist across restarts - investigate NemoClaw network namespace config"))
    if has_timeouts:
        improvements.append(("improve", "warn",
            "Timeouts detected - check agent context sizes and API latency"))
    if has_merged_pr:
        improvements.append(("improve", "info",
            "Watched OpenClaw PR was merged - evaluate for HYDRA adoption"))

    return improvements


def main():
    config = load_config()
    edge_config = load_edge_config()
    state = load_state()

    print("[hydra-audit " + time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()) + "] Starting daily audit")

    all_findings = []

    # 1. Agent health (main gateway)
    all_findings.extend(audit_agent_health(config))

    # 2. Unanswered messages (main Slack)
    all_findings.extend(audit_unanswered(config))

    # 3. Edge gateway health (CS/Intercom, journald)
    all_findings.extend(audit_edge_gateway())

    # 4. CS responsiveness (Intercom API)
    all_findings.extend(audit_cs_responsiveness(edge_config))

    # 5. Memory sizes
    all_findings.extend(audit_memory_sizes())

    # 6. Config check (both profiles)
    all_findings.extend(audit_config(config, edge_config))

    # 7. OpenClaw releases
    release_findings, state = audit_openclaw_releases(state)
    all_findings.extend(release_findings)

    # 8. Watched PRs
    pr_findings, state = audit_watched_prs(state)
    all_findings.extend(pr_findings)

    # 9. Generate improvement suggestions
    all_findings.extend(generate_improvements(all_findings))

    # Save state
    save_state(state)

    # Build and post digest
    digest = build_digest(all_findings)
    print(digest)

    # Dry-run: print the digest only, skip the Slack post (used for testing on node-8).
    if os.environ.get("HYDRA_AUDIT_DRY_RUN"):
        print("[dry-run] Slack post skipped (HYDRA_AUDIT_DRY_RUN set)")
        print("[hydra-audit] Complete")
        return

    # Post to Slack
    devops_token = config.get("channels", {}).get("slack", {}).get("accounts", {}).get("devops", {}).get("botToken", "")
    if devops_token:
        if slack_post(devops_token, SLACK_CHANNEL, digest):
            print("Posted to #clio_devops")
        else:
            print("Failed to post to Slack")
    else:
        print("No devops token - skipping Slack post")

    print("[hydra-audit] Complete")


if __name__ == "__main__":
    main()
