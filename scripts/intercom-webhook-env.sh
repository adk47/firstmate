#!/usr/bin/env bash
# intercom-webhook-env.sh — the ONLY path by which intercom-webhook.service gets
# its secrets.
#
# WHY THIS EXISTS (T13, node8-to-pods plan 2026-10-27)
#
# Until this landed, `intercom-webhook.service` carried its Intercom token,
# Intercom webhook signing secret, OpenClaw gateway token and Notion token as
# plaintext `Environment=` lines in
# /etc/systemd/system/intercom-webhook.service.d/env.conf. systemd's own
# `Environment=` is not a secret store: the values are visible in
# `systemctl show -p Environment`, in `systemd-analyze dump`, in
# /proc/<pid>/environ, and in every copy of /etc that anyone ever made (that
# drop-in also shipped to the server with an `env.conf.bak.prod` sitting next
# to it). T13 moves them into a root-only EnvironmentFile so the unit file
# itself carries no secret bytes at all.
#
# SOURCE OF TRUTH, in precedence order (first hit wins, per key):
#
#   1. the ESO-synced Kubernetes Secret `hydra/intercom-webhook`, which is an
#      ExternalSecret of Vault path k8s/hydra/intercom-webhook
#      (H-DevOps k8s/prod/security/external-secrets-hydra.yaml). Read with the
#      kubectl node-8 already has — the same transport scripts/muso-stack-read.sh
#      uses. This is the ESO-backed half, and it is authoritative: it already
#      carries INTERCOM_WEBHOOK_SECRET, INTERCOM_BOT_ADMIN_ID and
#      INTERCOM_WORKSPACE_ID, and any other managed key added to the Vault path
#      later is picked up with no code change here.
#   2. an existing /etc/hydra/intercom-webhook.env (so a re-render never drops a
#      key whose source is momentarily unreachable).
#   3. the legacy plaintext drop-in, DURING MIGRATION ONLY. Every key resolved
#      from here is reported as ROTATION DEBT: the value still exists in a place
#      it should not, and T13 deliberately does not rotate it (rotation is the
#      captain's call — see docs/runbooks/RUNBOOK.md § intercom-webhook secrets).
#
# Usage:
#   intercom-webhook-env.sh render [--dry-run]   # write the EnvironmentFile
#   intercom-webhook-env.sh check                # prove the invariant holds
#
# `check` is the mechanical acceptance test for T13: exit 0 only when the
# rendered file is root-only, every required key is present, and NO installed
# unit file for intercom-webhook carries a secret-looking `Environment=` value.
# It runs at the end of every deploy (scripts/install-aux-units.sh).
#
# Exit codes: 0 ok · 1 the invariant is violated (check) · 2 usage/read error ·
#             3 render refused because required keys are unresolved.
#
# Values are never printed — not to stdout, not to stderr, not to any log line.
# Every log names keys and a sha256 prefix only.
set -euo pipefail

# The SAME assignment parser the CI gate uses: systemd applies SEVERAL
# space-separated assignments on one `Environment=` line, so a prefix-parse would
# certify `Environment=PORT=1 OPENCLAW_TOKEN=…` as clean (Fable r5 / QA Critical).
# shellcheck source=scripts/lib/systemd-env-assignments.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/systemd-env-assignments.sh"

ENV_FILE="${INTERCOM_WEBHOOK_ENV_FILE:-/etc/hydra/intercom-webhook.env}"
UNIT_DIR="${INTERCOM_WEBHOOK_UNIT_DIR:-/etc/systemd/system}"
UNIT_NAME="intercom-webhook.service"
LEGACY_ENV_FILE="${INTERCOM_WEBHOOK_LEGACY_ENV_FILE:-$UNIT_DIR/intercom-webhook.service.d/env.conf}"
SECRET_NS="${INTERCOM_WEBHOOK_SECRET_NS:-hydra}"
SECRET_NAME="${INTERCOM_WEBHOOK_SECRET_NAME:-intercom-webhook}"
KUBECTL="${KUBECTL:-kubectl}"
NO_KUBECTL="${INTERCOM_WEBHOOK_ENV_NO_KUBECTL:-0}"
# deploy.sh runs with a NARROW PATH; resolve the kubectl that node-8 actually
# has (muso-stack-read.sh and trino-query.sh reach the cluster the same way)
# rather than silently falling back to "ESO unavailable" every deploy.
if ! command -v "$KUBECTL" >/dev/null 2>&1; then
  for cand in /usr/local/bin/kubectl /usr/bin/kubectl; do
    [ -x "$cand" ] && { KUBECTL="$cand"; break; }
  done
fi

usage() { sed -n '3,45p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }

case "${1:-}" in
  render)    MODE=render; shift; DRY_RUN=0
             [ "${1:-}" = "--dry-run" ] && DRY_RUN=1 ;;
  check)     MODE=check ;;
  -h|--help) usage ;;
  *)         usage ;;
esac

# ── the managed key set ──────────────────────────────────────────────────────
# Only names in this list are ever written. An unrelated key sitting in the
# Vault path (the ESO target also carries `type`) must not leak into a file
# systemd reads, and a future secret added upstream must be a deliberate edit
# here rather than an automatic widening of what node-8 holds.
MANAGED_KEYS=(
  INTERCOM_WEBHOOK_SECRET
  INTERCOM_TOKEN
  INTERCOM_BOT_ADMIN_ID
  INTERCOM_WORKSPACE_ID
  OPENCLAW_TOKEN
  NOTION_API_TOKEN
  NOTION_VERIFICATION_DB_ID
)
# scripts/intercom-webhook.js refuses to start without these.
REQUIRED_KEYS=(
  INTERCOM_WEBHOOK_SECRET
  INTERCOM_TOKEN
  INTERCOM_BOT_ADMIN_ID
  OPENCLAW_TOKEN
)

# ── secret-looking value detection (shared by check + the CI gate's copy) ────
# A value is LITERAL when it is not a systemd specifier/expansion. The name side
# is spelled inline in check() as case globs (token/secret/pass/api_key/
# credential). Both tests are deliberately blunt: a gate that only recognises the
# exact tokens we have today stops working on the next one.
# stat portability: node-8 is GNU coreutils, a developer laptop is BSD. The
# check runs in CI (Linux) and locally before a push; it must not report a
# violation on one and pass on the other.
file_mode() { if stat -c '%a' "$1" >/dev/null 2>&1; then stat -c '%a' "$1"; else stat -f '%Lp' "$1"; fi; }
file_owner() { if stat -c '%U:%G' "$1" >/dev/null 2>&1; then stat -c '%U:%G' "$1"; else stat -f '%Su:%Sg' "$1"; fi; }

# The secret-NAME predicate and the VALUE rule are NOT defined here: they live in
# scripts/lib/systemd-env-assignments.sh (sdenv_name_is_secret /
# sdenv_value_is_violation), shared with the CI gate. Two copies drifted once
# already and this side silently lost API_KEY/_DSN/_KEY.

# ── render ──────────────────────────────────────────────────────────────────
render() {
  local secret_json="" read_err=0
  if [ "$NO_KUBECTL" != "1" ] && command -v "$KUBECTL" >/dev/null 2>&1; then
    # Read-only get of OUR OWN ExternalSecret target. A failure here is not
    # fatal: precedence falls through to the env file / legacy drop-in and the
    # per-key lines below say exactly which source each value came from.
    secret_json="$("$KUBECTL" -n "$SECRET_NS" get secret "$SECRET_NAME" -o json 2>/dev/null)" || read_err=1
    [ -n "$secret_json" ] || read_err=1
  else
    read_err=1
  fi
  if [ "$read_err" -eq 1 ]; then
    echo "[intercom-webhook-env] NOTE: could not read Secret $SECRET_NS/$SECRET_NAME with kubectl —" >&2
    echo "[intercom-webhook-env]       ESO-backed keys are unavailable this run; falling back per key." >&2
  fi

  SECRET_JSON="$secret_json" \
  ENV_FILE="$ENV_FILE" \
  LEGACY_ENV_FILE="$LEGACY_ENV_FILE" \
  DRY_RUN="$DRY_RUN" \
  MANAGED="${MANAGED_KEYS[*]}" \
  REQUIRED="${REQUIRED_KEYS[*]}" \
  python3 - <<'PY'
import hashlib, json, os, re, sys

managed = os.environ["MANAGED"].split()
required = os.environ["REQUIRED"].split()
env_file = os.environ["ENV_FILE"]
legacy_file = os.environ["LEGACY_ENV_FILE"]
dry_run = os.environ.get("DRY_RUN") == "1"

def parse_envfile(path):
    """KEY=VALUE lines from a systemd EnvironmentFile (no shell evaluation)."""
    out = {}
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            for line in fh:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, v = line.split("=", 1)
                k = k.strip()
                v = v.strip()
                if len(v) >= 2 and v[0] == v[-1] and v[0] in "\"'":
                    v = v[1:-1]
                out[k] = v
    except FileNotFoundError:
        return {}
    return out

def parse_legacy_dropin(path):
    out = {}
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            for line in fh:
                line = line.strip()
                if not line.startswith("Environment="):
                    continue
                body = line[len("Environment="):]
                if "=" not in body:
                    continue
                k, v = body.split("=", 1)
                k = k.strip()
                v = v.strip()
                if len(v) >= 2 and v[0] == v[-1] and v[0] in "\"'":
                    v = v[1:-1]
                out[k] = v
    except FileNotFoundError:
        return {}
    return out

eso = {}
raw = os.environ.get("SECRET_JSON") or ""
if raw.strip():
    try:
        data = json.loads(raw).get("data") or {}
        import base64
        for k, v in data.items():
            eso[k] = base64.b64decode(v).decode("utf-8", "replace")
    except Exception as exc:  # malformed JSON is a read failure, not a crash
        print(f"[intercom-webhook-env] WARN: Secret JSON unreadable ({type(exc).__name__}) — ignoring ESO source", file=sys.stderr)
        eso = {}

existing = parse_envfile(env_file)
legacy = parse_legacy_dropin(legacy_file)

resolved, source = {}, {}
for key in managed:
    if eso.get(key):
        resolved[key], source[key] = eso[key], "eso"
    elif existing.get(key):
        resolved[key], source[key] = existing[key], "envfile"
    elif legacy.get(key):
        resolved[key], source[key] = legacy[key], "legacy-dropin"

missing = [k for k in required if not resolved.get(k)]
if missing:
    print("[intercom-webhook-env] REFUSED: required keys unresolved: " + ", ".join(missing), file=sys.stderr)
    print(f"[intercom-webhook-env] Refusing to write {env_file} — the unit would fail at boot with", file=sys.stderr)
    print("[intercom-webhook-env] 'missing required env vars'. Legacy drop-in left untouched.", file=sys.stderr)
    sys.exit(3)

allowed = re.compile(r"^[A-Za-z0-9_.:/+@=-]+$")
bad = [k for k in resolved if not allowed.match(resolved[k])]
if bad:
    print("[intercom-webhook-env] REFUSED: value(s) contain characters an EnvironmentFile cannot "
          "carry unquoted: " + ", ".join(bad) + " — quote them deliberately, do not guess.", file=sys.stderr)
    sys.exit(3)

lines = ["# intercom-webhook.service environment — RENDERED, do not hand-edit.",
         "# Rendered by scripts/intercom-webhook-env.sh from the ESO-synced Secret",
         "# hydra/intercom-webhook (Vault k8s/hydra/intercom-webhook) plus, during",
         "# migration, the legacy plaintext drop-in. Mode 0600 root:root.",
         "# Regenerate: /opt/hydra/scripts/intercom-webhook-env.sh render"]
for key in managed:
    if key in resolved:
        lines.append(f"{key}={resolved[key]}")
payload = "\n".join(lines) + "\n"

for key in managed:
    if key not in resolved:
        continue
    digest = hashlib.sha256(resolved[key].encode()).hexdigest()[:12]
    print(f"[intercom-webhook-env]   {key:<28} <- {source[key]:<14} sha256:{digest}")

# Legacy-sourced values split by consequence: a CREDENTIAL left in the retired
# drop-in is a rotation candidate (the same secret then exists in two places);
# an identifier (workspace id, database id) is copied, not rotated. Reporting
# them together would inflate the captain's rotation list with values that
# cannot be rotated.
credentialish = re.compile(r"TOKEN|SECRET|PASSWORD|API_KEY|CREDENTIAL|_DSN", re.I)
debt = [k for k in resolved if source[k] == "legacy-dropin" and credentialish.search(k)]
copied = [k for k in resolved if source[k] == "legacy-dropin" and not credentialish.search(k)]
if debt:
    print("[intercom-webhook-env] ROTATION DEBT (credential still sourced from the plaintext "
          "drop-in, so the SAME secret exists in two places until rotated): " + ", ".join(debt))
if copied:
    print("[intercom-webhook-env] copied identifiers (not credentials, nothing to rotate): "
          + ", ".join(copied))

if dry_run:
    print(f"[intercom-webhook-env] --dry-run: would write {env_file} ({len(resolved)} keys, mode 600)")
    sys.exit(0)

os.makedirs(os.path.dirname(env_file) or ".", mode=0o755, exist_ok=True)
tmp = env_file + ".tmp"
fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
try:
    os.write(fd, payload.encode())
    os.fsync(fd)
finally:
    os.close(fd)
os.chmod(tmp, 0o600)
try:
    os.chown(tmp, 0, 0)
except PermissionError:
    pass
os.replace(tmp, env_file)
print(f"[intercom-webhook-env] wrote {env_file} ({len(resolved)} keys, mode 600 root:root)")
PY
}

# ── check ───────────────────────────────────────────────────────────────────
check() {
  local rc=0 unit_files=()

  # 1) the EnvironmentFile exists and only root can read it.
  if [ ! -f "$ENV_FILE" ]; then
    echo "FAIL: $ENV_FILE is missing — intercom-webhook has no secret source." >&2
    echo "      Run: $0 render" >&2
    rc=1
  else
    local mode owner
    mode="$(file_mode "$ENV_FILE")"
    owner="$(file_owner "$ENV_FILE")"
    case "$mode" in
      600|400) ;;
      *) echo "FAIL: $ENV_FILE mode is $mode (need 600 or 400) — secrets in a systemd EnvironmentFile must not be group/other readable." >&2
         rc=1 ;;
    esac
    # Owner is only assertable as root: a non-root caller could not have set it,
    # so reporting it there would be a permanent false failure on a laptop.
    # Deploy runs as root, where this line has teeth.
    if [ "${EUID:-$(id -u)}" -eq 0 ]; then
      [ "$owner" = "root:root" ] || { echo "FAIL: $ENV_FILE owned by $owner (need root:root)." >&2; rc=1; }
    fi

    # 2) every key the script requires is present and non-empty.
    local key
    for key in "${REQUIRED_KEYS[@]}"; do
      if ! grep -qE "^${key}=..+" "$ENV_FILE"; then
        echo "FAIL: $ENV_FILE has no non-empty $key — intercom-webhook.js exits at boot without it." >&2
        rc=1
      fi
    done
  fi

  # 3) no INSTALLED unit file carries a secret-looking inline Environment=.
  local f name value line_no
  if [ -f "$UNIT_DIR/$UNIT_NAME" ]; then
    unit_files+=("$UNIT_DIR/$UNIT_NAME")
  else
    echo "FAIL: $UNIT_DIR/$UNIT_NAME is not installed — cannot prove it carries no inline tokens." >&2
    rc=1
  fi
  while IFS= read -r f; do unit_files+=("$f"); done < <(
    find "$UNIT_DIR/$UNIT_NAME.d" -maxdepth 1 -name '*.conf' -type f 2>/dev/null | LC_ALL=C sort
  )
  for f in "${unit_files[@]:-}"; do
    [ -n "$f" ] || continue
    # Whole FILE, not line by line: systemd JOINS a line ending in an odd run of
    # backslashes with the next (`Environment=\` then `FOO_SECRET=…`), so a
    # line-at-a-time parser reports this unit clean while systemd loads the
    # credential (QA round 5). The shared parser handles continuations, several
    # assignments per line, quoted spaces and tabs, and yields the first physical
    # line of each logical line.
    while IFS= read -r rec; do
      [ -n "$rec" ] || continue
      line_no="${rec%%$'\t'*}"
      rest="${rec#*$'\t'}"
      name="${rest%%$'\t'*}"
      value="${rest#*$'\t'}"
      case "$name" in EnvironmentFile|Environment) continue ;; esac
      # SAME predicate + value rule as the CI gate (shared lib): the two drifted
      # once and this side lost API_KEY (with no underscore requirement), _DSN
      # and _KEY, so a host drop-in with a literal INTERCOM_API_KEY made this
      # check print OK with a plaintext credential still loaded.
      if sdenv_name_is_secret "$name" && sdenv_value_is_violation "$value"; then
        echo "FAIL: $f:$line_no carries an inline secret value for $name." >&2
        echo "      Move it into $ENV_FILE (via $0 render); units may name secrets, never hold them." >&2
        echo "      (Continuation lines and several assignments per line are all examined.) Value not printed." >&2
        rc=1
        continue
      fi
      # POSITIVE allow-list, belt to the heuristic's braces: this unit's surfaces
      # may name ONLY the three non-secret knobs, whatever the value looks like.
      # That verdict does not depend on how the value parsed, so no parser
      # semantic can turn an unknown name into a pass — which is precisely what
      # nine rounds of heuristic hardening kept failing to guarantee.
      if ! sdenv_name_allowed_in_intercom_webhook_unit "$name"; then
        echo "FAIL: $f:$line_no names $name; this unit's allow-list is only" >&2
        echo "      ($SDENV_INTERCOM_WEBHOOK_ALLOWED_ENV). Credentials belong in $ENV_FILE via" >&2
        echo "      EnvironmentFile=; any other knob needs a PR that adds it to the list." >&2
        rc=1
      fi
    done < <(sdenv_assignments < "$f")
  done

  # 4) systemd's OWN view of the loaded unit: EnvironmentFile= referenced,
  #    and no secret-looking value in the effective Environment=.
  if [ "${INTERCOM_WEBHOOK_ENV_NO_SYSTEMCTL:-0}" != "1" ] && command -v systemctl >/dev/null 2>&1; then
    # FAIL CLOSED on an unavailable query (QA new finding 2): a systemd that
    # cannot be asked used to skip this whole block, so `check` printed OK
    # without ever proving the loaded unit or its EnvironmentFile. "Not asked"
    # is not "verified".
    if ! systemctl cat "$UNIT_NAME" >/dev/null 2>&1; then
      echo "FAIL: systemctl cannot read $UNIT_NAME (bus/query failure) — the loaded definition is UNVERIFIED, refusing to report OK." >&2
      echo "      Re-run when systemd answers: systemctl cat $UNIT_NAME" >&2
      rc=1
    else
      local eff eff_rc=0
      # A FAILED query is not an empty clean result (QA): `|| true` turned it
      # into "no inline secrets found", so `check` could pass without proving
      # anything about the loaded unit.
      eff="$(systemctl show "$UNIT_NAME" -p Environment --value 2>/dev/null)" || eff_rc=$?
      if [ "$eff_rc" -ne 0 ]; then
        echo "FAIL: systemctl could not report the loaded Environment for $UNIT_NAME (rc=$eff_rc) — UNVERIFIED, refusing to report OK." >&2
        rc=1
      else
      local tok
      for tok in $eff; do
        name="${tok%%=*}"
        value="${tok#*=}"
        if sdenv_name_is_secret "$name" && sdenv_value_is_violation "$value"; then
          echo "FAIL: systemd's loaded $UNIT_NAME has an inline secret for $name (Environment= is not a secret store)." >&2
          rc=1
        fi
      done
      fi
      # EXACT path match, not a substring (QA round 6): systemctl prints each
      # entry as `<path> (ignore_errors=no|yes)`, and `grep "$ENV_FILE"` accepted
      # `/etc/hydra/intercom-webhook.env.old` — a unit still loading the PREVIOUS
      # file would be certified as using the validated one, so after a gateway
      # token rotation the receiver could keep its old token and 401 while the
      # deploy claimed the cutover was sound. Strip the annotation, split into
      # entries, require one entry to equal $ENV_FILE exactly.
      local eff_files eff_files_rc=0
      eff_files="$(systemctl show "$UNIT_NAME" -p EnvironmentFiles --value 2>/dev/null)" || eff_files_rc=$?
      if [ "$eff_files_rc" -ne 0 ]; then
        echo "FAIL: systemctl could not report EnvironmentFiles for $UNIT_NAME (rc=$eff_files_rc) — UNVERIFIED, refusing to report OK." >&2
        rc=1
      else
        local entry match=0
        while IFS= read -r entry; do
          [ -n "$entry" ] || continue
          [ "$entry" = "$ENV_FILE" ] && match=1
        done <<<"$(printf '%s' "$eff_files" | sed 's/ (ignore_errors=[^)]*)//g' | tr ' ' '\n')"
        if [ "$match" -ne 1 ]; then
          echo "FAIL: systemd's loaded $UNIT_NAME does not load $ENV_FILE exactly (it reports: $eff_files)." >&2
          echo "      A daemon-reload or the unit template is missing it, or it loads an older file." >&2
          rc=1
        fi
      fi
    fi
  fi

  if [ "$rc" -eq 0 ]; then
    echo "OK: intercom-webhook unit carries no inline tokens; secrets come from $ENV_FILE (root-only)."
  fi
  return "$rc"
}

case "$MODE" in
  render) render ;;
  check)  check ;;
esac
