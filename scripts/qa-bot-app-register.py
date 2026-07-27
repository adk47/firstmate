#!/usr/bin/env python3
"""qa-bot-app-register.py — register the `muso-qa-bot` GitHub App and capture its key.

There is no headless way to create a GitHub App: the REST API has no
create-an-app endpoint (POST /orgs/{org}/apps is 404), and the only supported
path is the App Manifest flow, which needs a human to click "Create GitHub App"
in a browser. This script reduces that to exactly one click.

    Step 1  we serve a local page that auto-POSTs a manifest to GitHub
    Step 2  you click "Create GitHub App"; GitHub redirects back here with a code
    Step 3  we exchange the code for {id, pem, webhook_secret} and write the
            key store in the shape scripts/lib/qa-github-app-token.sh expects

The whole handshake must finish within one hour, and the code is single-use.

Run it on a machine with a browser (i.e. your Mac, not node-8); it writes the
key store locally and prints the command to install it on node-8.

    python3 scripts/qa-bot-app-register.py
    python3 scripts/qa-bot-app-register.py --org Muso-AI --port 8721

The permission set below is deliberately minimal and repo-scoped: no
organization permissions at all (today's automation runs on an account with
admin:org + admin:enterprise), and NO contents:write — the bot approves and sets
statuses, it never pushes or merges.
"""

import argparse
import http.server
import json
import os
import secrets
import socketserver
import sys
import urllib.error
import urllib.request
import webbrowser
from pathlib import Path

# Least privilege, and kept honest: every entry must map to a call the QA path
# actually makes. `issues: write` was dropped after confirming nothing in the
# review, approval, status or thread-resolution paths touches the /issues/ API —
# `pull_requests: write` already covers the batched review, inline comments and
# resolveReviewThread. Re-add it only alongside the concrete call that needs it.
PERMISSIONS = {
    "metadata": "read",        # mandatory
    "contents": "read",        # gh pr diff, reading files under review
    "pull_requests": "write",  # reviews, inline comments, resolve threads, APPROVE
    "statuses": "write",       # the qa-review gate status
    "checks": "read",          # statusCheckRollup mixes check-runs and statuses
}

result: dict = {}


def build_manifest(org: str, port: int) -> dict:
    return {
        "name": "Muso QA Bot",
        "url": f"https://github.com/{org}/hydra",
        "description": (
            "Automated PR reviewer for Muso. Posts reviews, records approvals, and "
            "publishes the qa-review merge-gate status. Approves; never merges."
        ),
        "public": False,
        "redirect_url": f"http://127.0.0.1:{port}/callback",
        # Webhooks are unused (dispatch comes via repository_dispatch), but the
        # manifest requires hook_attributes; keep it inactive.
        "hook_attributes": {"url": f"https://github.com/{org}", "active": False},
        "default_permissions": PERMISSIONS,
        "default_events": [],
    }


class Handler(http.server.BaseHTTPRequestHandler):
    org = ""
    port = 0
    state = ""

    def log_message(self, *_args):  # keep the console clean
        pass

    def _send(self, code: int, body: str):
        raw = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def do_GET(self):
        if self.path.startswith("/callback"):
            return self._callback()
        manifest = json.dumps(build_manifest(self.org, self.port))
        action = (
            f"https://github.com/organizations/{self.org}/settings/apps/new"
            f"?state={self.state}"
        )
        self._send(200, f"""<!doctype html><meta charset="utf-8">
<title>Register Muso QA Bot</title>
<body style="font:15px system-ui;max-width:40em;margin:4em auto">
<h2>Register the <code>muso-qa-bot</code> GitHub App</h2>
<p>Submitting the manifest to <b>{self.org}</b>. On the GitHub page that opens,
click <b>Create GitHub App</b>. You will be redirected back here automatically.</p>
<p>Permissions requested (repo-scoped only, no org permissions, no write to code):</p>
<pre>{json.dumps(PERMISSIONS, indent=2)}</pre>
<form id="f" method="post" action="{action}">
  <input type="hidden" name="manifest" id="m">
  <button type="submit" style="font-size:1em;padding:.6em 1.2em">Continue to GitHub</button>
</form>
<script>
document.getElementById('m').value = {json.dumps(manifest)};
document.getElementById('f').submit();
</script></body>""")

    def _callback(self):
        from urllib.parse import parse_qs, urlparse

        q = parse_qs(urlparse(self.path).query)
        code = (q.get("code") or [""])[0]
        state = (q.get("state") or [""])[0]

        if state != self.state:
            self._send(400, "<h2>State mismatch — refusing.</h2>"
                            "<p>Possible CSRF. Re-run the script.</p>")
            result["error"] = "state mismatch"
            return
        if not code:
            self._send(400, "<h2>No code in the redirect.</h2>")
            result["error"] = "no code"
            return

        req = urllib.request.Request(
            f"https://api.github.com/app-manifests/{code}/conversions",
            method="POST",
            headers={"Accept": "application/vnd.github+json",
                     "X-GitHub-Api-Version": "2022-11-28",
                     "User-Agent": "muso-qa-bot-register"},
        )
        try:
            with urllib.request.urlopen(req, timeout=30) as r:
                data = json.load(r)
        except urllib.error.HTTPError as e:
            body = e.read().decode(errors="replace")[:300]
            self._send(502, f"<h2>Conversion failed ({e.code})</h2><pre>{body}</pre>")
            result["error"] = f"conversion HTTP {e.code}: {body}"
            return

        result["app"] = data
        self._send(200, f"""<!doctype html><meta charset="utf-8">
<body style="font:15px system-ui;max-width:40em;margin:4em auto">
<h2>Created: {data.get('slug')}</h2>
<p>App ID <b>{data.get('id')}</b>. The private key has been written locally.</p>
<p>Next: install it on <code>Muso-AI/hydra</code> at
<a href="{data.get('html_url')}/installations/new">{data.get('html_url')}/installations/new</a>,
then follow the instructions printed in your terminal.</p>
<p>You can close this tab.</p></body>""")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--org", default="Muso-AI")
    ap.add_argument("--port", type=int, default=8721)
    ap.add_argument("--out", default=str(Path.home() / "qa-bot-app.json"),
                    help="where to write the key store (default ~/qa-bot-app.json)")
    args = ap.parse_args()

    # Never default a private key into a git working tree. This repo has had
    # secrets committed before, and a file named qa-bot-app.json sitting in the
    # checkout is one `git add -A` away from being one of them.
    out_probe = Path(args.out).resolve()
    for parent in [out_probe, *out_probe.parents]:
        if (parent / ".git").exists():
            print(f"REFUSING: {out_probe} is inside a git repository ({parent}).\n"
                  f"Write the key outside any checkout, e.g. --out ~/qa-bot-app.json",
                  file=sys.stderr)
            return 2

    Handler.org, Handler.port = args.org, args.port
    Handler.state = secrets.token_urlsafe(24)

    url = f"http://127.0.0.1:{args.port}/"
    print(f"Opening {url}")
    print("Click 'Create GitHub App' on the GitHub page, then come back here.\n"
          "(The whole handshake must finish within one hour.)")

    socketserver.TCPServer.allow_reuse_address = True
    with socketserver.TCPServer(("127.0.0.1", args.port), Handler) as httpd:
        try:
            webbrowser.open(url)
        except Exception:
            print(f"Could not open a browser — visit {url} manually.")
        while not result:
            httpd.handle_request()

    if "error" in result:
        print(f"FAILED: {result['error']}", file=sys.stderr)
        return 1

    app = result["app"]
    out = Path(args.out)
    # The key store is JSON (not a bare .pem) on purpose: ensure-secret-perms.sh
    # globs "$SECRETS_DIR"/*.json only, so this shape inherits the 0600
    # fail-closed self-heal that a .pem would silently miss.
    #
    # Create it 0600 FROM BIRTH. Two traps here, both real:
    #   - write_text() + chmod leaves the key at the process umask (0644) for the
    #     duration of the write.
    #   - os.open(..., 0o600) applies that mode ONLY when it creates the file. If
    #     --out already exists 0644, O_TRUNC rewrites it in place and the old mode
    #     survives; a chmod afterwards is too late, the key was already exposed.
    # fchmod on the descriptor before writing closes both.
    payload = json.dumps({
        "app_id": str(app["id"]),
        "installation_id": "",   # filled in by qa-bot-app-verify.sh --fix-installation-id
        "private_key": app["pem"],
    }, indent=2) + "\n"
    fd = os.open(out, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    try:
        os.fchmod(fd, 0o600)          # tighten BEFORE any bytes are written
        with os.fdopen(fd, "w") as fh:
            fh.write(payload)
    except BaseException:
        os.close(fd)
        raise

    print(f"\nApp created: {app.get('slug')} (id {app['id']})")
    print(f"Key store written to {out} (0600)\n")
    print("Next steps:")
    print(f"  1. Install on hydra:  {app.get('html_url')}/installations/new")
    print("     Choose 'Only select repositories' -> Muso-AI/hydra")
    print("  2. Install the key on node-8 and fill in the installation id:")
    print(f"     scp {out} root@40.160.32.80:/opt/hydra/secrets/qa-bot-app.json")
    print("     ssh root@40.160.32.80 'chmod 600 /opt/hydra/secrets/qa-bot-app.json'")
    print("     ssh root@40.160.32.80 'bash /opt/hydra/scripts/qa-bot-app-verify.sh --fix-installation-id'")
    print("  3. Verify:  ssh root@40.160.32.80 'bash /opt/hydra/scripts/qa-bot-app-verify.sh'")
    return 0


if __name__ == "__main__":
    sys.exit(main())
