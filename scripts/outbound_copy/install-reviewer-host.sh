#!/usr/bin/env bash
# Install the outbound copy REVIEW ROUND on the reviewer host (the machine that can reach the reviewer model and
# holds the signing key; not node-8).
#
# Why this exists: a customer message leaves node-8 only with a signed reviewer verdict on its exact bytes
# (docs/credit-verification/outbound-copy-gate.md). The round that produces those verdicts is the senders' clock.
# With no round scheduled nothing is refused and nothing fails; every sender simply holds. So the round is a timer,
# installed from this reviewed tree, and node-8's cron-health-watchdog pages when the oldest held body ages past
# its limit.
#
# What it installs (and nothing else):
#   <prefix>/scripts/outbound_copy/{gate.py,review_pull.py}
#   <prefix>/policies/outbound-copy-rubric*.md, outbound-copy-reviewer.allowed_signers, outbound-copy-enforce.json
#   <unit-dir>/outbound-copy-review.{service,timer}        (systemd --user)
#
# It copies from THIS tree, prints the sha256 of every file it wrote, and keeps the previous install beside it
# (<prefix>.bak-<UTC>). The round sends nothing and decides nothing about a request: it reviews copy.
#
#   install-reviewer-host.sh --remote 'ssh -o BatchMode=yes -J root@JUMP root@10.0.0.8' [--enable]
#   install-reviewer-host.sh --uninstall
#
# Refuses when the signing key is not the one policies/outbound-copy-reviewer.allowed_signers pins: every verdict
# such a host signed would be dropped by node-8, and the queue would never drain.
#
# Undo: install-reviewer-host.sh --uninstall   (disables the timer, removes the units; the install dir and its
# backups are left in place and named, so nothing is lost).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"

PREFIX="$HOME/.local/share/muso/outbound-copy-review"
UNIT_DIR="$HOME/.config/systemd/user"
KEY="$HOME/.config/muso/outbound-copy-reviewer/id_ed25519"
REMOTE=""
INTERVAL="15min"
LIMIT=60
ENABLE=0
UNINSTALL=0
SYSTEMCTL=1

usage() { sed -n '2,27p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
die() { printf 'install-reviewer-host: %s\n' "$*" >&2; exit 2; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --prefix)       PREFIX="${2:?}"; shift 2 ;;
    --unit-dir)     UNIT_DIR="${2:?}"; shift 2 ;;
    --key)          KEY="${2:?}"; shift 2 ;;
    --remote)       REMOTE="${2:?}"; shift 2 ;;
    --interval)     INTERVAL="${2:?}"; shift 2 ;;
    --limit)        LIMIT="${2:?}"; shift 2 ;;
    --enable)       ENABLE=1; shift ;;
    --no-systemctl) SYSTEMCTL=0; shift ;;   # write the files only (tests, or a host without a user manager)
    --uninstall)    UNINSTALL=1; shift ;;
    -h|--help)      usage; exit 0 ;;
    *)              die "unknown argument: $1" ;;
  esac
done

SERVICE="$UNIT_DIR/outbound-copy-review.service"
TIMER="$UNIT_DIR/outbound-copy-review.timer"

if [ "$UNINSTALL" -eq 1 ]; then
  if [ "$SYSTEMCTL" -eq 1 ]; then
    systemctl --user disable --now outbound-copy-review.timer 2>/dev/null || true
  fi
  rm -f "$SERVICE" "$TIMER"
  if [ "$SYSTEMCTL" -eq 1 ]; then systemctl --user daemon-reload 2>/dev/null || true; fi
  printf 'uninstalled: the timer is off and the units are removed. Left in place: %s (and any %s.bak-*)\n' "$PREFIX" "$PREFIX"
  printf 'node-8 senders now HOLD every new body until a round runs again.\n'
  exit 0
fi

[ -n "$REMOTE" ] || die "--remote is required (the command prefix that reaches the sender, e.g. 'ssh -J root@jump root@10.0.0.8')"
case "$REMOTE" in *"'"*) die "--remote must not contain a single quote" ;; esac
case "$LIMIT" in ''|*[!0-9]*) die "--limit must be a number" ;; esac
[ -f "$KEY" ] || die "signing key not found: $KEY"
case "$KEY$PREFIX" in *[[:space:]]*) die "--key and --prefix must not contain whitespace (they are written into a unit file)" ;; esac

SIGNERS="$ROOT/policies/outbound-copy-reviewer.allowed_signers"
[ -f "$SIGNERS" ] || die "missing $SIGNERS"
# The public half of the key this host would sign with must be the one the tree pins.
have="$(ssh-keygen -y -f "$KEY" 2>/dev/null | awk '{print $1" "$2}')" || true
[ -n "$have" ] || die "could not read the public half of $KEY"
if ! awk '{for (i = 1; i < NF; i++) if ($i ~ /^ssh-/) print $i" "$(i+1)}' "$SIGNERS" | grep -qxF "$have"; then
  die "the key at $KEY is not the reviewer key policies/outbound-copy-reviewer.allowed_signers pins; node-8 would drop every verdict it signed. Nothing installed."
fi

# The mode table is not read by the round itself; it is installed so `gate.py report` and `gate.py mode` answer here
# from the same reviewed table node-8 reads, instead of failing as unreadable.
files=(scripts/outbound_copy/gate.py scripts/outbound_copy/review_pull.py policies/outbound-copy-reviewer.allowed_signers
       policies/outbound-copy-enforce.json)
while IFS= read -r f; do files+=("policies/$(basename "$f")"); done < <(find "$ROOT/policies" -maxdepth 1 -name 'outbound-copy-rubric*.md' | sort)
[ -f "$ROOT/policies/outbound-copy-rubric.md" ] || die "missing policies/outbound-copy-rubric.md"
[ -f "$ROOT/policies/outbound-copy-enforce.json" ] || die "missing policies/outbound-copy-enforce.json"

stamp="$(date -u +%Y%m%dT%H%M%SZ)"
if [ -d "$PREFIX" ]; then
  cp -a "$PREFIX" "$PREFIX.bak-$stamp"
  printf 'backup: %s\n' "$PREFIX.bak-$stamp"
fi
# A rubric that left the tree must leave the install too: the round refuses when the two hosts enforce different rules.
rm -f "$PREFIX"/policies/outbound-copy-rubric*.md 2>/dev/null || true
for rel in "${files[@]}"; do
  install -D -m 0644 "$ROOT/$rel" "$PREFIX/$rel"
  src="$(sha256sum "$ROOT/$rel" | awk '{print $1}')"; dst="$(sha256sum "$PREFIX/$rel" | awk '{print $1}')"
  [ "$src" = "$dst" ] || die "copy of $rel does not match its source"
  printf 'installed %s  %s\n' "$dst" "$rel"
done

mkdir -p "$UNIT_DIR"
cat > "$SERVICE" <<UNIT
[Unit]
Description=Outbound copy review round: review the customer messages the sender is holding, write signed verdicts back
Documentation=file://$PREFIX/scripts/outbound_copy/review_pull.py

[Service]
Type=oneshot
# The reviewer CLI lives in the user's own bin dir; a user unit does not inherit a login PATH.
Environment=PATH=$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin
# rc 1 = some bodies are still unreviewed (the next round takes them); rc 2 = the round could not run. Both show
# as a failed run here on purpose, and node-8's watchdog pages when the oldest held body ages past its limit.
ExecStart=/usr/bin/python3 $PREFIX/scripts/outbound_copy/review_pull.py --remote '$REMOTE' --key $KEY --limit $LIMIT
TimeoutStartSec=3300
UNIT
cat > "$TIMER" <<UNIT
[Unit]
Description=Outbound copy review round, every $INTERVAL

[Timer]
OnBootSec=5min
OnUnitActiveSec=$INTERVAL
Persistent=true

[Install]
WantedBy=timers.target
UNIT
printf 'unit %s  %s\n' "$(sha256sum "$SERVICE" | awk '{print $1}')" "$SERVICE"
printf 'unit %s  %s\n' "$(sha256sum "$TIMER" | awk '{print $1}')" "$TIMER"

if [ "$SYSTEMCTL" -eq 1 ]; then
  systemctl --user daemon-reload
  if [ "$ENABLE" -eq 1 ]; then
    systemctl --user enable --now outbound-copy-review.timer
    printf 'enabled: outbound-copy-review.timer (every %s, up to %s bodies a round)\n' "$INTERVAL" "$LIMIT"
  else
    printf 'NOT enabled. To start the round: systemctl --user enable --now outbound-copy-review.timer\n'
  fi
fi
printf 'undo: %s --uninstall\n' "${BASH_SOURCE[0]}"
