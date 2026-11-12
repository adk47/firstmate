#!/usr/bin/env bash
set -euo pipefail

# Doctrine gate for Caroline's ANSWER BANK (caroline-guard-g1, captain 2026-11-01: "consistent answers").
#
# plugins/intercom/src/answer-bank.ts is the ONE versioned set of approved process lines. The output guard masks
# them (an approved line is never blocked) and flags a paraphrase; Caroline retrieves them from her workspace.
# This gate keeps the two in lockstep and makes every copy change a visible, versioned event:
#   1. every bank entry is present VERBATIM (whitespace / markdown / curly quotes folded) in its anchor file under
#      workspaces/support -- the knowledge base can never teach a different answer than the guard enforces;
#   2. an entry marked pendingAnchor (its copy PR is still open) must NOT already be live in the anchor: when the
#      PR lands, the marker is dropped in the same change, so "pending" cannot linger;
#   3. the bank's content hash is pinned below together with BANK_VERSION: changing any line without bumping the
#      version and the pin fails here, so a copy edit cannot slip through as a refactor.
# Changing a line: edit answer-bank.ts AND the anchor file, bump BANK_VERSION, update PINNED below, and get the copy
# owner's ruling (caroline-teach-c1 ships, Fable r5 rules).

PINNED_VERSION="2026-11-11.1"
PINNED_SHA256="5440b511105506a6dc2de8e12c6cf404a66377f674bf525e3bf88bc94264bef2"

ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
REL="plugins/intercom/src/answer-bank.ts"
BANK="$ROOT/$REL"
WS="$ROOT/workspaces/support"
[ -f "$BANK" ] || { echo "Missing $BANK" >&2; exit 2; }

# --base REF (CI passes the PR base): the bank at REF is the independent monotonic source. If the
# lines differ from REF, BANK_VERSION must be strictly greater than REF's -- editing the copy, the
# anchor AND the pin together still cannot skip the bump. A --base that does not resolve FAILS
# (never silently skipped); a bank absent at REF is a first introduction.
BASE=""
[ "${1:-}" = "--base" ] && BASE="${2:?--base needs a git ref}"

dump_bank() {  # dump_bank <file>
  node --experimental-strip-types --no-warnings -e "
    import('$1').then((m) => console.log(JSON.stringify({ version: m.BANK_VERSION, entries: m.ANSWER_BANK })));
  "
}
dump="$(dump_bank "$BANK")" \
  || { echo "FAIL: could not load $BANK with node --experimental-strip-types (it must stay import-free)" >&2; exit 2; }

base_dump="null"
if [ -n "$BASE" ]; then
  git -C "$ROOT" rev-parse --verify --quiet "$BASE^{commit}" >/dev/null \
    || { echo "FAIL: --base $BASE does not resolve in $ROOT (fetch it first); the version check cannot be skipped" >&2; exit 2; }
  if git -C "$ROOT" cat-file -e "$BASE:$REL" 2>/dev/null; then
    tmpd="$(mktemp -d)"; trap 'rm -rf "$tmpd"' EXIT
    git -C "$ROOT" show "$BASE:$REL" > "$tmpd/answer-bank.ts"
    base_dump="$(dump_bank "$tmpd/answer-bank.ts")" || { echo "FAIL: could not load the bank at $BASE" >&2; exit 2; }
  else
    echo "NOTE: $REL is new relative to $BASE (first introduction)"
  fi
fi

BASE_DUMP="$base_dump" BASE="$BASE" PINNED_VERSION="$PINNED_VERSION" PINNED_SHA256="$PINNED_SHA256" WS="$WS" python3 - "$dump" <<'PY'
import hashlib, json, os, re, sys
from pathlib import Path

bank = json.loads(sys.argv[1])
ws = Path(os.environ["WS"])

def norm(s: str) -> str:
    s = s.replace("\u2019", "'").replace("\u2018", "'").replace("\u201c", '"').replace("\u201d", '"')
    s = s.replace("**", "").replace("__", "")
    s = re.sub(r"(?m)^[ \t]*>[ \t]?", "", s)        # blockquote markers
    s = re.sub(r"(?m)^[ \t]*[-*][ \t]+(?=\S)", "", s) # list bullets around a quoted line
    return re.sub(r"\s+", " ", s).strip()

fail = False
seen = set()
for e in bank["entries"]:
    if e["id"] in seen:
        print(f"FAIL: duplicate bank id {e['id']}", file=sys.stderr); fail = True
    seen.add(e["id"])
    anchor = ws / e["anchor"]
    if not anchor.is_file():
        print(f"FAIL: {e['id']}: anchor {e['anchor']} does not exist", file=sys.stderr); fail = True; continue
    live = norm(e["text"]) in norm(anchor.read_text(encoding="utf-8"))
    if e.get("pendingAnchor"):
        if live:
            print(f"FAIL: {e['id']}: the text is live in {e['anchor']}; drop pendingAnchor ({e['pendingAnchor']})", file=sys.stderr)
            fail = True
        else:
            print(f"PENDING: {e['id']} waits on {e['pendingAnchor']} (not yet in {e['anchor']})")
    elif not live:
        print(f"FAIL: {e['id']} ({e['source']}): workspaces/support/{e['anchor']} does not carry the approved text verbatim:", file=sys.stderr)
        print(f"      \"{e['text'][:160]}...\"", file=sys.stderr)
        fail = True

digest = hashlib.sha256(json.dumps([[e["id"], e["text"]] for e in bank["entries"]], ensure_ascii=False).encode()).hexdigest()
if bank["version"] != os.environ["PINNED_VERSION"] or digest != os.environ["PINNED_SHA256"]:
    print(f"FAIL: the answer bank changed (version {bank['version']}, sha256 {digest}); a copy change bumps BANK_VERSION "
          f"and the pin in scripts/check-caroline-answer-bank.sh (PINNED_VERSION / PINNED_SHA256) in the same reviewed PR",
          file=sys.stderr)
    fail = True
def vkey(v: str):
    m = re.fullmatch(r"(\d{4})-(\d{2})-(\d{2})\.(\d+)", v or "")
    return tuple(int(x) for x in m.groups()) if m else None

if vkey(bank["version"]) is None:
    print(f"FAIL: BANK_VERSION {bank['version']!r} is not YYYY-MM-DD.N", file=sys.stderr); fail = True
base = json.loads(os.environ["BASE_DUMP"])
if base is not None:
    base_digest = hashlib.sha256(json.dumps([[e["id"], e["text"]] for e in base["entries"]], ensure_ascii=False).encode()).hexdigest()
    if base_digest != digest and not (vkey(bank["version"]) and vkey(base["version"]) and vkey(bank["version"]) > vkey(base["version"])):
        print(f"FAIL: the bank lines changed relative to {os.environ['BASE']} but BANK_VERSION {bank['version']} is not greater "
              f"than {base['version']} there; bump it", file=sys.stderr)
        fail = True
    elif vkey(bank["version"]) and vkey(base["version"]) and vkey(bank["version"]) < vkey(base["version"]):
        print(f"FAIL: BANK_VERSION went backwards ({base['version']} at {os.environ['BASE']} -> {bank['version']})", file=sys.stderr)
        fail = True
if fail:
    print("\nCaroline answer bank drifted. See scripts/check-caroline-answer-bank.sh header.", file=sys.stderr)
    sys.exit(1)
print(f"OK: Caroline answer bank {bank['version']} ({len(bank['entries'])} lines) matches its workspace anchors.")
PY
