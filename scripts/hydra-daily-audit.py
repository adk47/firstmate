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

Cron (node-8):
  0 8 * * * /opt/hydra/scripts/hydra-daily-audit.py >> /var/log/hydra-daily-audit.log 2>&1
"""
import json
import urllib.request
import time
import os
import glob

CONFIG_PATH = "/root/.openclaw/openclaw.json"
WORKSPACE_ROOT = "/opt/hydra/workspaces"
MEMORY_BLOAT_CHARS = 15000      # latency/cost hygiene warning (tiered-memory target ~3500)
MEMORY_TRUNCATE_CHARS = 40000   # real bootstrap cap; see openclaw-main.json:192 (PR #165)
SLACK_CHANNEL = "C0ADV2W76G4"  # #clio_devops
OPENCLAW_REPO = "open-claw/open-claw"  # GitHub repo for releases/PRs
WATCHED_REPOS = [
    "open-claw/open-claw",
]
# PRs/features we're watching (from reference)
WATCHED_PR_NUMBERS = [33309, 31592, 29793, 33223, 34334, 34536]

AUDIT_STATE_FILE = "/tmp/hydra-daily-audit-state.json"

def load_config():
    with open(CONFIG_PATH) as f:
        return json.load(f)

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

def github_api(path):
    """Call GitHub API (unauthenticated, rate-limited to 60/hr)."""
    url = "https://api.github.com/" + path
    req = urllib.request.Request(url, headers={
        "Accept": "application/vnd.github+json",
        "User-Agent": "HYDRA-Audit/1.0"
    })
    try:
        return json.loads(urllib.request.urlopen(req, timeout=15).read())
    except Exception:
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
    """Check 24h success/error rates from journalctl."""
    findings = []
    try:
        import subprocess
        logs = subprocess.run(
            ["journalctl", "-u", "openclaw-gateway", "--since", "24 hours ago", "--no-pager"],
            capture_output=True, text=True, timeout=30
        ).stdout

        successes = logs.count("isError=false")
        errors = logs.count("isError=true")
        total = successes + errors
        timeouts = logs.count("reason=timeout")
        overloaded = logs.count("overloaded_error")
        stale_sockets = logs.count("stale-socket")
        no_ipv4 = logs.count("no IPv4 address")

        if total > 0:
            success_rate = round(successes / total * 100, 1)
            findings.append(("health", "info",
                str(successes) + "/" + str(total) + " agent runs succeeded (" + str(success_rate) + "%)"))
            if success_rate < 90:
                findings.append(("health", "warn",
                    "Success rate below 90% - " + str(errors) + " failures"))
        else:
            findings.append(("health", "info", "No agent runs in last 24h (idle)"))

        if timeouts > 0:
            findings.append(("health", "warn", str(timeouts) + " timeout events"))
        if overloaded > 0:
            findings.append(("health", "warn", str(overloaded) + " API overloaded errors"))
        if stale_sockets > 3:
            findings.append(("health", "warn", str(stale_sockets) + " stale socket restarts"))
        if no_ipv4 > 0:
            findings.append(("lxc", "warn", str(no_ipv4) + " LXC containers missing IPv4 (NemoClaw issue)"))

    except Exception as e:
        findings.append(("health", "error", "Could not read journalctl: " + str(e)))

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
                    "@" + agent + " MEMORY.md is " + str(size) + " chars - bloated (target ~3500, hard cap " + str(MEMORY_TRUNCATE_CHARS) + "); prune for latency/cost, not yet truncated"))
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

                try:
                    hist = slack_api(token, "conversations.history",
                        "channel=" + ch_id + "&oldest=" + oldest + "&limit=50")
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
                        replied = any(
                            msgs_chrono[j].get("user") == my_bot_id
                            for j in range(i + 1, len(msgs_chrono))
                        )
                        if replied:
                            answered_count += 1
                        else:
                            unanswered_count += 1

    findings = []
    total = answered_count + unanswered_count
    if total > 0:
        rate = round(answered_count / total * 100, 1)
        findings.append(("response", "info",
            str(answered_count) + "/" + str(total) + " @mentions answered (" + str(rate) + "%)"))
    if unanswered_count > 0:
        findings.append(("response", "warn",
            str(unanswered_count) + " unanswered @mentions in last 24h"))
    elif total > 0:
        findings.append(("response", "ok", "All @mentions answered"))

    return findings


def audit_config(config):
    """Check for config drift or inconsistencies."""
    findings = []
    expected_agents = {"clio", "ceo", "cmo", "cto", "qa", "finance", "operations", "devops", "design", "support", "sentinel"}
    actual_agents = {a["id"] for a in config.get("agents", {}).get("list", [])}

    missing = expected_agents - actual_agents
    extra = actual_agents - expected_agents

    if missing:
        findings.append(("config", "warn", "Missing agents: " + ", ".join(missing)))
    if extra:
        findings.append(("config", "info", "Extra agents: " + ", ".join(extra)))

    # Check workspace directories exist
    for agent in config.get("agents", {}).get("list", []):
        ws = agent.get("workspace", "")
        if ws and not os.path.isdir(ws):
            findings.append(("config", "warn",
                "@" + agent["id"] + " workspace missing: " + ws))

    if not findings:
        findings.append(("config", "ok", "All agents configured correctly"))

    return findings


def audit_openclaw_releases(state):
    """Check for new OpenClaw releases on GitHub."""
    findings = []
    last_seen = state.get("last_release", "")

    releases = github_api("repos/" + OPENCLAW_REPO + "/releases?per_page=5")
    if not releases:
        findings.append(("releases", "info", "Could not check OpenClaw releases (rate limited or unreachable)"))
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
        pr_state = pr.get("state", "")
        merged = pr.get("merged", False)
        if merged:
            findings.append(("prs", "info",
                "Watched PR #" + str(pr_num) + " *MERGED*: " + title + " - consider adopting"))
        elif pr_state == "closed":
            findings.append(("prs", "info",
                "Watched PR #" + str(pr_num) + " closed (not merged): " + title))

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
        "config": "Configuration",
        "releases": "OpenClaw Releases",
        "prs": "Community PRs",
        "improve": "Improvement Suggestions",
    }

    lines = [":octopus: *HYDRA Daily Audit* - " + time.strftime("%b %d, %Y", time.gmtime()) + " <!channel>"]
    lines.append("")

    for cat in ["health", "response", "memory", "lxc", "config", "releases", "prs", "improve"]:
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
    state = load_state()

    print("[hydra-audit " + time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()) + "] Starting daily audit")

    all_findings = []

    # 1. Agent health
    all_findings.extend(audit_agent_health(config))

    # 2. Memory sizes
    all_findings.extend(audit_memory_sizes())

    # 3. Unanswered messages
    all_findings.extend(audit_unanswered(config))

    # 4. Config check
    all_findings.extend(audit_config(config))

    # 5. OpenClaw releases
    release_findings, state = audit_openclaw_releases(state)
    all_findings.extend(release_findings)

    # 6. Watched PRs
    pr_findings, state = audit_watched_prs(state)
    all_findings.extend(pr_findings)

    # 7. Generate improvement suggestions
    all_findings.extend(generate_improvements(all_findings))

    # Save state
    save_state(state)

    # Build and post digest
    digest = build_digest(all_findings)
    print(digest)

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
