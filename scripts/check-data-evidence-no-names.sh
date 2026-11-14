#!/usr/bin/env bash
# check-data-evidence-no-names.sh — CI guard: a committed evidence file under data/
# that is ABOUT an erasure/hide request must not also carry the data subject's name.
#
# WHY (captain, 2026-11-07, firstmate inbox 005). The gdpr-tombstone-repair-21 evidence
# committed 24 full names next to their erasure requests, register rows, credit
# counts and delete timestamps — the exact class of record those requests are
# about, in a repo every collaborator, the in-cluster PR-validation pod and every
# clone can read. The doctrine already existed in prose
# (scripts/gdpr_pipeline/hide_batch.py:8, "Ids only in files and PR text: no
# requester names"); a rule that lives only in a comment is a rule the next
# person in a hurry breaks. This is the mechanical backstop.
#
# Fails (exit 1) when a file tracked under data/ whose text carries erasure-request
# vocabulary ALSO carries either
#   (a) a JSON/JSONL key whose last dotted segment is name, display_name,
#       full_name, legal_name or real_name with a non-empty string value, or
#   (b) a markdown table header cell that is exactly name, full name or
#       display name.
# The ids alone are the evidence; a name is re-derivable from the live admin API.
#
# Usage: check-data-evidence-no-names.sh
# Env:   REPO_ROOT (defaults to the repo this script lives in)
# Exit:  0 clean, 1 violation, 2 unreadable input.
set -euo pipefail

ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
DOCTRINE='scripts/gdpr_pipeline/hide_batch.py:8 — "Ids only in files and PR text: no requester names"'
# Anchored on LETTERS, not on `\b`: the vocabulary has to match the snake_case spellings the pipeline
# actually uses (`privacy_erasure`, `hidden_at`), where `_` is a word character and `\b` never fires -- but
# it must NOT match `erase` inside `erased`, which is ordinary prose (a QA-bot message body in
# data/fleet-velocity-fable-v1/evidence.json says "erased-recent-base-work" and its PR runs carry a CI check
# name, and an unanchored alternative turned that into a violation on every PR).
VOCAB='(?<![A-Za-z])erasure(?![A-Za-z])|(?<![A-Za-z])erase(?![A-Za-z])|(?<![A-Za-z])takedown(?![A-Za-z])|(?<![A-Za-z])take-down(?![A-Za-z])|(?<![A-Za-z])gdpr(?![A-Za-z])|(?<![A-Za-z])hidden(?![A-Za-z])|(?<![A-Za-z])hide(?![A-Za-z])|(?<![A-Za-z])removal request(?![A-Za-z])|(?<![A-Za-z])register(?![A-Za-z])'

cd "$ROOT" || { echo "check-data-evidence-no-names: cannot enter $ROOT" >&2; exit 2; }
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
    echo "check-data-evidence-no-names: $ROOT is not a git work tree" >&2; exit 2; }

violations=0
while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    [ -f "$rel" ] || continue
    hits="$(VOCAB="$VOCAB" python3 - "$rel" <<'PY'
import json
import os
import re
import sys

# `requester_name` is the field the erasure register itself uses (scripts/ops_intake/hide.py writes it from the
# Slack author / Intercom contact). Leaving it out meant a file carrying a whole register row -- the exact record
# this gate exists to keep names out of -- passed as "clean (ids only)" (QA review 5901028355 finding 3).
NAME_KEYS = {"name", "display_name", "full_name", "legal_name", "real_name", "requester_name"}
MD_HEADERS = {"name", "full name", "display name"}
VOCAB = re.compile(os.environ["VOCAB"], re.I)


def walk(obj, prefix=""):
    if isinstance(obj, dict):
        for key, value in obj.items():
            path = f"{prefix}.{key}" if prefix else key
            if key.lower() in NAME_KEYS and isinstance(value, str) and value.strip():
                yield path
            yield from walk(value, path)
    elif isinstance(obj, list):
        for item in obj:
            yield from walk(item, prefix)


path = sys.argv[1]
with open(path, encoding="utf-8", errors="replace") as fh:
    lines = fh.readlines()
raw = "".join(lines)

# A pretty-printed .json file puts "name": "..." on its own indented line, so
# parse the whole document first; only fall back to per-line JSONL parsing when
# the file is not one JSON value.
whole_parsed = False
try:
    document = json.loads(raw)
except ValueError:
    document = None
else:
    whole_parsed = True

# The vocabulary test runs on the RAW bytes AND on the DECODED document. A JSON
# string may spell the class "privacy_\u0065rasure", which never matches the raw
# text, so a raw-only test would skip the file before the name walk ever ran.
line_docs = {}
if not whole_parsed:
    for lineno, line in enumerate(lines, 1):
        text = line.strip()
        if not (text.startswith("{") or text.startswith("[")):
            continue
        try:
            line_docs[lineno] = json.loads(text)
        except ValueError:
            continue

decoded = [raw]
if whole_parsed:
    decoded.append(json.dumps(document))
else:
    decoded.extend(json.dumps(doc) for doc in line_docs.values())
if not VOCAB.search("\n".join(decoded)):
    sys.exit(0)

if whole_parsed:
    for field in walk(document):
        print(f"{path}:1: JSON field {field} carries a name")

for lineno, line in enumerate(lines, 1):
    text = line.strip()
    if text.startswith("|"):
        cells = [c.strip().strip("*`_").lower() for c in text.strip("|").split("|")]
        if any(c in MD_HEADERS for c in cells):
            print(f"{path}:{lineno}: markdown table header names a person: {text}")
    if whole_parsed:
        continue
    parsed = line_docs.get(lineno)
    if parsed is None:
        continue
    for field in walk(parsed):
        print(f"{path}:{lineno}: JSON field {field} carries a name")
PY
)" || { echo "check-data-evidence-no-names: cannot scan $rel" >&2; exit 2; }
    if [ -n "$hits" ]; then
        violations=$((violations + 1))
        printf '%s\n' "$hits"
    fi
done < <(git ls-files data/)

if [ "$violations" -gt 0 ]; then
    echo ""
    echo "VIOLATION: ${violations} evidence file(s) under data/ record a data subject's NAME next to an"
    echo "  erasure/hide request. Ids only: ${DOCTRINE}"
    echo "  Drop the name column / the JSON name field; the id is the evidence, and the name is"
    echo "  re-derivable from the live admin API when a person needs it."
    exit 1
fi

echo "check-data-evidence-no-names: clean (ids only in data/ evidence)"
