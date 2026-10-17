#!/usr/bin/env bash
# fraud-cases-query.sh — READ-ONLY query / validator / index renderer for the fraud case KB.
#
# jq + grep + sed only. No network, no DB, no writes: --index prints INDEX.md to stdout, the
# author redirects it (`bash scripts/fraud-cases-query.sh --index > INDEX.md`).
#
# Usage:
#   fraud-cases-query.sh [--vector V] [--outcome O] [--signal S]   list matching cases
#   fraud-cases-query.sh --validate                                 validate every case file
#   fraud-cases-query.sh --index                                    render INDEX.md to stdout
# Env: FRAUD_CASES_DIR  override the cases directory (tests)
# Exit: 0 ok · 1 usage / bad filter value · 2 invalid or missing corpus
#
# Case frontmatter: one `key: <JSON value>` per line between two `---` lines, so a later
# Postgres import is one row per file (`jq` the line values into a jsonb row, mechanically).

set -uo pipefail

SKILL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CASES_DIR="${FRAUD_CASES_DIR:-$SKILL_ROOT/cases}"

VECTORS="claim_impersonation credit_self_add role_inflation muso_only_credits dedupe_abuse removal_social_engineering referral_abuse payment_fraud"
OUTCOMES="confirmed_fraud false_positive inconclusive"
SOURCES="repo_mined notion"
FACTORS="role_inflation source_quality establishment velocity backend_hard_reject muso_only"
EMAIL_RE='[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'
# Phone-shaped digit groups with separators (+1 415 555 0199, (415) 555-0199). Ids, dates, counts and
# UUIDs do not match. Heuristic only: names cannot be machine-checked, see SKILL.md.
PHONE_RE='(^|[^A-Za-z0-9-])(\+[0-9]{1,3}[ .-]?)?(\(?[0-9]{2,4}\)?[ .-]){1,3}[0-9]{3,4}($|[^A-Za-z0-9-])'

die() { echo "fraud-cases-query: $*" >&2; exit "${2:-1}"; }
in_list() { local v="$1" l; for l in $2; do [ "$l" = "$v" ] && return 0; done; return 1; }
# shellcheck disable=SC2086  # $1 is a space-separated closed list; splitting is the point
as_json_array() { printf '%s\n' $1 | jq -R . | jq -sc .; }

mode=query vector="" outcome="" signal=""
while [ $# -gt 0 ]; do
  case "$1" in
    --vector)   [ $# -ge 2 ] || die "--vector needs a value"; vector="$2"; shift 2 ;;
    --outcome)  [ $# -ge 2 ] || die "--outcome needs a value"; outcome="$2"; shift 2 ;;
    --signal)   [ $# -ge 2 ] || die "--signal needs a value"; signal="$2"; shift 2 ;;
    --validate) mode=validate; shift ;;
    --index)    mode=index; shift ;;
    -h|--help)  sed -n '2,15p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[ -z "$vector" ]  || in_list "$vector"  "$VECTORS"  || die "unknown vector '$vector' (one of: $VECTORS)"
[ -z "$outcome" ] || in_list "$outcome" "$OUTCOMES" || die "unknown outcome '$outcome' (one of: $OUTCOMES)"

[ -d "$CASES_DIR" ] || die "cases directory not found: $CASES_DIR" 2
shopt -s nullglob
files=("$CASES_DIR"/*.md)
[ "${#files[@]}" -gt 0 ] || die "no case files in $CASES_DIR" 2

# Frontmatter -> one JSON object on stdout. Fails (non-zero) on a malformed block.
frontmatter_json() {
  awk 'NR==1 { if ($0 != "---") exit 3; next } /^---$/ { closed=1; exit } { print } END { if (!closed) exit 4 }' "$1" |
    jq -Rs '
      [split("\n")[] | select(length > 0)] as $lines
      | [$lines[] | capture("^(?<k>[a-z_]+): (?<v>.*)$")] as $kv
      | if ($kv | length) != ($lines | length) then error("frontmatter line is not `key: json`")
        elif ($kv | length) == 0 then error("frontmatter block is empty")
        else $kv | map({(.k): (.v | fromjson)}) | add end'
}

REQUIRED='["id","title","source","date_opened","date_closed","vector","signals","evidence_sources","outcome","actions_taken","detector_factors_that_fired","what_would_have_caught_it_earlier","related_profiles"]'

# Prints one problem per line for a case; no output = valid.
problems_for() {
  local f="$1" stem obj
  stem="$(basename "$f" .md)"
  [[ "$stem" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}-[a-z0-9][a-z0-9-]*$ ]] || echo "filename must be <YYYY-MM-DD>-<slug>.md"
  grep -qE "$EMAIL_RE" "$f" && echo "contains an email address (no customer PII in cases)"
  grep -qE "$PHONE_RE" "$f" && echo "contains a phone number (no customer PII in cases)"
  if ! obj="$(frontmatter_json "$f" 2>&1)"; then
    echo "frontmatter unreadable: $(printf '%s' "$obj" | head -1)"
    return
  fi
  jq -r --arg stem "$stem" --argjson req "$REQUIRED" \
    --argjson vectors "$(as_json_array "$VECTORS")" \
    --argjson outcomes "$(as_json_array "$OUTCOMES")" \
    --argjson sources "$(as_json_array "$SOURCES")" \
    --argjson factors "$(as_json_array "$FACTORS")" '
    def strs: type == "array" and all(.[]; type == "string");
    def date: type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$");
    . as $o
    | ($req - keys | map("missing field: " + .)[]),
      (keys - $req | map("unknown field: " + .)[]),
      (if (.id // "") != $stem then "id must equal the filename stem" else empty end),
      (if (.date_opened | date | not) then "date_opened must be YYYY-MM-DD"
       elif ($stem[0:10]) != .date_opened then "filename date must equal date_opened" else empty end),
      (if .date_closed != null and (.date_closed | date | not) then "date_closed must be null or YYYY-MM-DD" else empty end),
      (if (.title | type) != "string" or (.title | length) == 0 or (.title | test("\n")) then "title must be a non-empty one-line string" else empty end),
      (if ([.vector] | inside($vectors) | not) then "vector \(.vector | tojson) is outside the closed list" else empty end),
      (if ([.source] | inside($sources) | not) then "source \(.source | tojson) is outside the closed list" else empty end),
      (if ([.outcome] | inside($outcomes) | not) then "outcome \(.outcome | tojson) is outside the closed list" else empty end),
      (["signals","evidence_sources","actions_taken","detector_factors_that_fired","related_profiles"][] as $k
        | if ($o[$k] | strs | not) then "\($k) must be an array of strings" else empty end),
      (if (.signals | strs) and (.signals | any(.[]; test("^[a-z][a-z0-9_]*$") | not)) then "signals must be snake_case tokens" else empty end),
      (if (.evidence_sources | strs) and (.evidence_sources | length) == 0 then "evidence_sources must not be empty" else empty end),
      (if (.detector_factors_that_fired | strs) and (.detector_factors_that_fired - $factors | length) > 0
         then "detector_factors_that_fired has unknown factor(s): \(.detector_factors_that_fired - $factors | join(","))" else empty end),
      (if (.related_profiles | strs) and (.related_profiles | any(.[]; test("^[A-Za-z0-9_-]+$") | not)) then "related_profiles must be ids only" else empty end),
      (if (.what_would_have_caught_it_earlier | type) != "string" or (.what_would_have_caught_it_earlier | length) == 0
         then "what_would_have_caught_it_earlier must be a non-empty string" else empty end)
  ' <<<"$obj" || echo "schema check failed to run"
}

bad=0
for f in "${files[@]}"; do
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    echo "INVALID $(basename "$f"): $p" >&2
    bad=1
  done < <(problems_for "$f")
done
[ "$bad" -eq 0 ] || die "corpus failed validation" 2

if [ "$mode" = validate ]; then
  echo "OK: ${#files[@]} case(s) valid"
  exit 0
fi

# All cases as one sorted JSON array (frontmatter + relative path).
rel="$(basename "$CASES_DIR")"
all="$(for f in "${files[@]}"; do
         frontmatter_json "$f" | jq -c --arg p "$rel/$(basename "$f")" '. + {path: $p}'
       done | jq -sc 'sort_by(.id)')"

if [ "$mode" = index ]; then
  {
    echo "# Fraud case index"
    echo
    echo "<!-- GENERATED by scripts/fraud-cases-query.sh --index. Do not hand-edit. -->"
    echo
    echo "| id | opened | vector | outcome | summary |"
    echo "|---|---|---|---|---|"
    jq -r '.[] | "| [\(.id)](\(.path)) | \(.date_opened) | \(.vector) | \(.outcome) | \(.title) |"' <<<"$all"
  }
  exit 0
fi

out="$(jq -r --arg v "$vector" --arg o "$outcome" --arg s "$signal" '
  .[] | select(($v == "" or .vector == $v) and ($o == "" or .outcome == $o) and ($s == "" or (.signals | index($s))))
      | [.id, .vector, .outcome, .title, .path] | @tsv' <<<"$all")"
if [ -z "$out" ]; then
  echo "fraud-cases-query: no matching cases" >&2
else
  printf '%s\n' "$out"
fi
