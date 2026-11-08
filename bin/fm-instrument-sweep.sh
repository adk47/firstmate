#!/usr/bin/env bash
# fm-instrument-sweep.sh - find checks whose output does not depend on their input.
#
# An instrument that reports the same verdict in the healthy and the broken case
# is worse than no instrument: it trains the reader to trust a signal that cannot
# fail. This script is the mechanical test for that class over the registered
# custom checks in <state>/*.check.sh.
#
# It never runs a registered check. Static detectors read the check text. The
# only execution path is a differential probe directory that declares itself a
# fixture corpus with an instrument-sweep.probes file; the live state directory
# never contains that declaration, so a live check is never executed. Nothing
# outside TMPDIR is written.
#
# Verdict per check, in precedence order:
#   DEFECT                  at least one mechanical defect was found; the result
#                           line names the highest-damage one by class and line.
#   PROVEN-DISTINGUISHING   a differential probe showed the check emitting
#                           different stdout, stderr, or status for a healthy and
#                           a broken fact.
#   UNPROVEN(reason)        neither of the above. Absence of evidence is never a
#                           pass: a check the sweep cannot analyse is UNPROVEN
#                           with the reason, never proven.
#
# The seven defect classes (stable ids, used verbatim in output):
#   vacuous-comparison               a comparison that cannot fail: -n/-z over a
#                                    command that always prints (grep -c, wc -l,
#                                    date), a test on a variable whose only
#                                    assignment is a literal, or a multi-word
#                                    list compared to an integer.
#   rate-without-denominator         shell arithmetic dividing by a variable with
#                                    no adjacent zero guard on that variable.
#   identical-output                 byte-identical stdout, stderr, and status
#                                    across a healthy and a broken fact
#                                    (differential probe), or a top-level echo
#                                    with no variable and no substitution.
#   orphan-marker                    reads a marker file that nothing in the
#                                    corpus writes, or compares a value read from
#                                    a marker against a label no writer writes.
#   discarded-negative-assertion     a standalone negative assertion whose status
#                                    is not consumed and is not last, so a later
#                                    command decides the outcome.
#   stale-reading                    reads a file mtime it writes itself instead
#                                    of the fact it claims to measure.
#   failure-path-exit-zero           a failed state read, or an error branch, that
#                                    exits 0 (silence reported as health).
#
# Usage:
#   fm-instrument-sweep.sh [--state DIR] [--probe-dir DIR] [--writers DIR]...
#                          [--tsv] [--fail-on-defect] [--help]
#
#   --state DIR        directory holding <id>.check.sh (default
#                      $FM_STATE_OVERRIDE, then $FM_HOME/state, then this repo's
#                      state directory)
#   --probe-dir DIR    differential probe directory; <id>.probe.sh sets up the
#                      fact for FM_PROBE_VARIANT=healthy|broken under
#                      $FM_PROBE_ROOT
#   --writers DIR      extra directory of scripts to read for marker write
#                      evidence (default: this repo's bin/); repeatable
#   --tsv              machine-readable rows (see "TSV rows" below)
#   --fail-on-defect   exit 1 when any DEFECT was found; 2 on a usage error
#   --help             print this text
#
# TSV rows (stable, one record per line):
#   finding  <check-id> <class> <file> <line> <message [source: exact source line]>
#   note     <check-id> unproven <file> <line> <reason>
#   verdict  <check-id> <DEFECT|PROVEN-DISTINGUISHING|UNPROVEN> <reason>
#   rank     <n> <damage> <check-id> <class> <file> <line>
#   summary  checks=<n> defect=<n> unproven=<n> proven=<n>
#
# Damage weights are stable per class: identical-output 10, vacuous-comparison 9,
# failure-path-exit-zero 8, discarded-negative-assertion 8, stale-reading 7,
# orphan-marker 6, rate-without-denominator 5. A check is ranked by its
# highest-damage defect, then by defect count.
#
# Differential probe contract: the sweep runs
#   FM_PROBE_VARIANT=<variant> FM_PROBE_ROOT=<sandbox> bash <probe>
# then, in that sandbox,
#   FM_PROBE_VARIANT=<variant> FM_PROBE_ROOT=<sandbox> bash <check>
# for variant healthy then broken, comparing stdout, stderr, and exit status.
# A probe that cannot set up reports UNPROVEN, never a pass.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
PROBE_TIMEOUT=${FM_INSTRUMENT_SWEEP_PROBE_TIMEOUT:-20}

usage() {
  sed -n '2,/^set -u$/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'
}

STATE_ARG=
PROBE_DIR=
EXTRA_WRITERS=()
TSV=0
FAIL_ON_DEFECT=0
while [ "$#" -gt 0 ]; do
  case $1 in
  --state)
    [ "$#" -ge 2 ] || { echo "error: --state needs a directory" >&2; exit 2; }
    STATE_ARG=$2
    shift 2
    ;;
  --probe-dir)
    [ "$#" -ge 2 ] || { echo "error: --probe-dir needs a directory" >&2; exit 2; }
    PROBE_DIR=$2
    shift 2
    ;;
  --writers)
    [ "$#" -ge 2 ] || { echo "error: --writers needs a directory" >&2; exit 2; }
    EXTRA_WRITERS[${#EXTRA_WRITERS[@]}]=$2
    shift 2
    ;;
  --tsv)
    TSV=1
    shift
    ;;
  --fail-on-defect)
    FAIL_ON_DEFECT=1
    shift
    ;;
  --help | -h)
    usage
    exit 0
    ;;
  *)
    echo "error: unrecognised argument: $1" >&2
    exit 2
    ;;
  esac
done

if [ -z "$STATE_ARG" ]; then
  if [ -n "${FM_STATE_OVERRIDE:-}" ]; then
    STATE_ARG=$FM_STATE_OVERRIDE
  elif [ -n "${FM_HOME:-}" ]; then
    STATE_ARG=$FM_HOME/state
  else
    STATE_ARG=$FM_ROOT/state
  fi
fi

[ -d "$STATE_ARG" ] || { echo "error: state directory is unavailable: $STATE_ARG" >&2; exit 2; }
STATE=$(cd "$STATE_ARG" && pwd) || exit 2

if [ -n "$PROBE_DIR" ]; then
  [ -d "$PROBE_DIR" ] || { echo "error: probe directory is unavailable: $PROBE_DIR" >&2; exit 2; }
  PROBE_DIR=$(cd "$PROBE_DIR" && pwd) || exit 2
  if [ ! -f "$PROBE_DIR/instrument-sweep.probes" ]; then
    echo "error: probe directory is not a declared fixture corpus (missing instrument-sweep.probes)" >&2
    exit 2
  fi
fi

if [ "${#EXTRA_WRITERS[@]}" -eq 0 ]; then
  EXTRA_WRITERS=("$FM_ROOT/bin")
fi

TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-instrument-sweep.XXXXXX") || exit 1
trap 'rm -rf -- "$TMP"' EXIT HUP INT TERM

# --- bookkeeping ------------------------------------------------------------

F_ID=()
F_CLASS=()
F_FILE=()
F_LINE=()
F_MSG=()
F_SNIPPET=()
N_ID=()
N_MSG=()
CK_ID=()
CK_TRUST=()
CK_DELEGATE=()
CK_VERDICT=()
CK_REASON=()
CK_BODIES=()

display_path() { # absolute file -> path relative to the invocation directory when inside it
  case $1 in
  "$PWD"/*) printf '%s\n' "${1#"$PWD"/}" ;;
  *) printf '%s\n' "$1" ;;
  esac
}

damage_of() {
  case $1 in
  identical-output) echo 10 ;;
  vacuous-comparison) echo 9 ;;
  failure-path-exit-zero) echo 8 ;;
  discarded-negative-assertion) echo 8 ;;
  stale-reading) echo 7 ;;
  orphan-marker) echo 6 ;;
  rate-without-denominator) echo 5 ;;
  *) echo 1 ;;
  esac
}

snippet_of() { # file line -> exact source line
  sed -n "${2}p" "$1" 2>/dev/null | tr '\t' ' '
}

add_finding() { # id class file line message
  F_ID[${#F_ID[@]}]=$1
  F_CLASS[${#F_CLASS[@]}]=$2
  F_FILE[${#F_FILE[@]}]=$3
  F_LINE[${#F_LINE[@]}]=$4
  F_MSG[${#F_MSG[@]}]=$5
  F_SNIPPET[${#F_SNIPPET[@]}]=$(snippet_of "$3" "$4")
}

add_note() { # id message
  N_ID[${#N_ID[@]}]=$1
  N_MSG[${#N_MSG[@]}]=$2
}

add_check() { # id trust delegate
  CK_ID[${#CK_ID[@]}]=$1
  CK_TRUST[${#CK_TRUST[@]}]=$2
  CK_DELEGATE[${#CK_DELEGATE[@]}]=$3
  CK_BODIES[${#CK_BODIES[@]}]=$4
}

sha256_of() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" 2>/dev/null | awk '{print $1}'
  else
    return 1
  fi
}

trust_state() { # state id check -> ok|mismatch|missing
  local trust version hash actual
  trust="$1/$2.check-trust"
  if [ ! -f "$trust" ] || [ -L "$trust" ]; then
    echo missing
    return 0
  fi
  version=$(sed -n '1p' "$trust" 2>/dev/null)
  hash=$(sed -n '2p' "$trust" 2>/dev/null)
  if [ "$version" != fm-custom-check-v1 ] || [ -z "$hash" ]; then
    echo mismatch
    return 0
  fi
  actual=$(sha256_of "$3") || { echo mismatch; return 0; }
  [ "$actual" = "$hash" ] && echo ok || echo mismatch
}

# --- delegate resolution ----------------------------------------------------
#
# A registered check is often a byte-pinned shim that execs a firstmate-owned
# reporter. The shim body carries no logic, so its evidence lives in the target;
# the sweep analyses that target and keeps the finding attributed to it.
delegate_of() { # file -> path or empty
  local file=$1 tok home
  home=$(awk '
    /^[ \t]*(export[ \t]+)?FM_HOME=/ {
      s = $0
      sub(/^[ \t]*(export[ \t]+)?FM_HOME=/, "", s)
      gsub(/["\047]/, "", s)
      print s
      exit
    }' "$file" 2>/dev/null)
  tok=$(awk '
    /^[ \t]*exec[ \t]+["\047]?\/[^ \t"\047]+/ {
      s = $0
      sub(/^[ \t]*exec[ \t]+/, "", s)
      sub(/[ \t].*$/, "", s)
      gsub(/["\047]/, "", s)
      print s
      exit
    }' "$file" 2>/dev/null)
  [ -n "$tok" ] || { echo ""; return 0; }
  # shellcheck disable=SC2016 # Single quotes are the point: these match a literal $FM_HOME or $HOME prefix in a shim path, which is what the shim itself would expand.
  case $tok in
  '$FM_HOME'/*) tok="${home}${tok#\$FM_HOME}" ;;
  '$HOME'/*) tok="${HOME}${tok#\$HOME}" ;;
  esac
  if [ -f "$tok" ]; then
    echo "$tok"
  else
    echo ""
  fi
}

is_shim_body() { # file -> 0 when the body is only setup plus one exec
  local code
  code=$(grep -vc -E '^[[:space:]]*(#|$|set -u|set -eu|export |umask |cd |exec )' "$1" 2>/dev/null)
  [ "${code:-1}" = 0 ]
}

# --- static detectors -------------------------------------------------------
#
# One awk pass over a body plus one evidence pass for guards and self-writes.
# A defect row is "<line>\t<class>\t<message>"; a note row is
# "0\tunproven\t<reason>".
collect_evidence() { # file -> "guard\t<var>" / "touch\t<base>" rows
  awk '
  function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
  function base_of(t,   n, a, v) {
    gsub(/["\047`]/, "", t)
    sub(/[;,)&|]+$/, "", t)
    # ${VAR:-default} carries its value in the default branch.
    sub(/^\$\{[A-Za-z_][A-Za-z0-9_]*:-/, "", t)
    gsub(/\}/, "", t)
    if (t ~ /^\$[A-Za-z_][A-Za-z0-9_]*$/) {
      v = substr(t, 2)
      if (v in MAP) t = MAP[v]
    } else if (t ~ /^\$\{[A-Za-z_][A-Za-z0-9_]*\}$/) {
      v = t
      gsub(/[${}]/, "", v)
      if (v in MAP) t = MAP[v]
    }
    gsub(/["\047`]/, "", t)
    sub(/[;,)&|]+$/, "", t)
    # ${VAR:-default} carries its value in the default branch.
    sub(/^\$\{[A-Za-z_][A-Za-z0-9_]*:-/, "", t)
    gsub(/\}/, "", t)
    sub(/^\$\{[A-Za-z_][A-Za-z0-9_]*:-/, "", t)
    gsub(/\}/, "", t)
    n = split(t, a, "/")
    return a[n]
  }
  { L[FNR] = $0 }
  END {
    n = FNR
    for (i = 1; i <= n; i++) {
      line = L[i]
      if (line ~ /^[ \t]*#/) continue
      if (match(line, /^[ \t]*(export[ \t]+)?[A-Za-z_][A-Za-z0-9_]*=/)) {
        s = substr(line, RSTART, RLENGTH)
        gsub(/^[ \t]*(export[ \t]+)?/, "", s)
        v = substr(s, 1, index(s, "=") - 1)
        if (!(v in MAP)) MAP[v] = trim(substr(line, RSTART + RLENGTH))
      }
    }
    for (i = 1; i <= n; i++) {
      line = L[i]
      if (line ~ /^[ \t]*#/) continue
      if (match(line, /\$?[A-Za-z_][A-Za-z0-9_]*"?[ \t]*-(gt|ge|ne)[ \t]+(0|1)/) ||
          match(line, /\$?[A-Za-z_][A-Za-z0-9_]*"?[ \t]*-(eq|le)[ \t]+0/) ||
          match(line, /\$?[A-Za-z_][A-Za-z0-9_]*"?[ \t]*-lt[ \t]+1/) ||
          match(line, /\$?[A-Za-z_][A-Za-z0-9_]*"?[ \t]*==?[ \t]*"?0"?/)) {
        s = substr(line, RSTART, RLENGTH)
        gsub(/[$" \t]/, "", s)
        sub(/-(gt|ge|ne|eq|le|lt).*$/, "", s)
        sub(/==?.*$/, "", s)
        if (s != "") printf "guard\t%s\n", s
      }
      if (match(line, /\[\[?[ \t]+-z[ \t]+"?\$\{?[A-Za-z_][A-Za-z0-9_]*/)) {
        s = substr(line, RSTART, RLENGTH)
        sub(/^.*-z[ \t]+"?\$\{?/, "", s)
        sub(/[^A-Za-z0-9_].*$/, "", s)
        if (s != "") printf "guard\t%s\n", s
      }
      if (line ~ /(^|[ \t;|&(])(touch|>>?)/) {
        m = split(line, a, /[ \t;|&()]+/)
        for (k = 1; k <= m; k++) {
          tok = a[k]
          cmd = tok
          sub(/^.*\//, "", cmd)
          if (tok ~ /^>>?./) {
            sub(/^>>?/, "", tok)
            b = base_of(tok)
          } else if (tok ~ /^>>?$/ || cmd == "touch") {
            b = base_of(a[k + 1])
          } else {
            continue
          }
          if (b ~ /^[.A-Za-z0-9_][A-Za-z0-9_.-]*$/ && b !~ /^[0-9]+$/) printf "touch\t%s\n", b
        }
      }
    }
  }
  ' "$1"
}

detect_static() { # file evidence-file -> defect rows
  awk '
  # count_assigns counts occurrences of "var=" that are real assignment starts.
  function count_assigns(line, v,   i, len, vlen, prev) {
    len = length(line); vlen = length(v)
    c = 0
    for (i = 1; i + vlen <= len; i++) {
      if (substr(line, i, vlen) != v) continue
      if (substr(line, i + vlen, 1) != "=") continue
      prev = (i > 1) ? substr(line, i - 1, 1) : ""
      if (prev ~ /[A-Za-z0-9_]/) continue
      c++
    }
    return c
  }
  NR == FNR {
    if ($1 == "guard") GUARDED[$2] = 1
    else if ($1 == "touch") TOUCHED[$2] = 1
    next
  }
  { L[FNR] = $0 }
  END {
    n = FNR
    for (i = 1; i <= n; i++) {
      line = L[i]
      if (line ~ /^[ \t]*#/) continue
      if (match(line, /^[ \t]*(export[ \t]+)?[A-Za-z_][A-Za-z0-9_]*=/)) {
        s = substr(line, RSTART, RLENGTH)
        gsub(/^[ \t]*(export[ \t]+)?/, "", s)
        v = substr(s, 1, index(s, "=") - 1)
        if (!(v in MAP)) MAP[v] = substr(line, RSTART + RLENGTH)
        gsub(/^[ \t]+/, "", MAP[v])
        gsub(/[ \t]+$/, "", MAP[v])
      }
    }
    # A variable is a constant only when every assignment in the file is the one
    # line-initial assignment seen above. Mid-line reassignment (&& running=1) is
    # just as real, so count occurrences anywhere in the body.
    for (v in MAP) {
      cnt = 0
      for (i = 1; i <= n; i++) {
        if (L[i] ~ /^[ \t]*#/) continue
        cnt += count_assigns(L[i], v)
      }
      COUNTV[v] = cnt
    }
    for (i = 1; i <= n; i++) {
      line = L[i]
      if (line ~ /^[ \t]*#/) continue
      # --- vacuous-comparison: always-printing command in a test -----------
      if (line ~ /\[\[?[ \t]+(-n|-z)[ \t]+"?\$\(/) {
        st = index(line, "$(")
        subj = substr(line, st)
        if (subj ~ /(grep[ \t]+-[A-Za-z]*c|grep[ \t]+-c|wc[ \t]+-[lwc]|(^|[|;( ])date[ )|;])/) {
          printf "%d\tvacuous-comparison\t-n/-z over a command that always prints a value (grep -c, wc -l, date)\n", i
        }
      }
      if (match(line, /\[\[?[ \t]+(-n|-z)[ \t]+"?\$[A-Za-z_][A-Za-z0-9_]*"?[ \t]*\]\]?/)) {
        seg = substr(line, RSTART, RLENGTH)
        v = seg
        sub(/^\[\[?[ \t]+(-n|-z)[ \t]+"?\$/, "", v)
        sub(/".*$/, "", v)
        sub(/[^A-Za-z0-9_].*$/, "", v)
        if (v != "" && (v in MAP) && COUNTV[v] == 1 && MAP[v] ~ /(grep[ \t]+-[A-Za-z]*c|wc[ \t]+-[lwc])/) {
          printf "%d\tvacuous-comparison\t-n/-z over %s, which is assigned a command that always prints a number\n", i, v
        }
      }
      # --- vacuous-comparison: numeric test over a variable ----------------
      if (match(line, /\[\[?[ \t]+"?\$[A-Za-z_][A-Za-z0-9_]*"?[ \t]+-(gt|ge|lt|le|eq|ne)[ \t]+-?[0-9]+/)) {
        seg = substr(line, RSTART, RLENGTH)
        quoted = (seg ~ /"\$/)
        rest = seg
        sub(/^\[\[?[ \t]+"?\$/, "", rest)
        v = rest
        sub(/[^A-Za-z0-9_].*$/, "", v)
        op = rest
        sub(/^[A-Za-z0-9_]+"?[ \t]+-/, "", op)
        sub(/[ \t].*$/, "", op)
        num = seg
        sub(/^.*[ \t]/, "", num)
        if (v != "" && (v in MAP) && COUNTV[v] == 1) {
          rhs = MAP[v]
          if (rhs ~ /^-?[0-9]+$/) {
            lhs = rhs + 0; rhs2 = num + 0; hit = 0
            if (op == "gt") hit = (lhs > rhs2)
            else if (op == "ge") hit = (lhs >= rhs2)
            else if (op == "lt") hit = (lhs < rhs2)
            else if (op == "le") hit = (lhs <= rhs2)
            else if (op == "eq") hit = (lhs == rhs2)
            else if (op == "ne") hit = (lhs != rhs2)
            if (hit) printf "%d\tvacuous-comparison\tcompares %s=%s to %s and is fixed true\n", i, v, rhs, num
          } else if (!quoted && rhs ~ /\$\(/ && rhs !~ /^\$\(\(/ && rhs !~ /(wc[ \t]+-[lwc]|grep[ \t]+-[A-Za-z]*c|cut |head |tail |sort |awk )/) {
            printf "%d\tvacuous-comparison\tcompares the list in %s to the integer %s\n", i, v, num
          }
        }
      }
      # --- rate-without-denominator ---------------------------------------
      # Only a division whose operand sits at paren depth 0 of the arithmetic
      # expression counts: a %Y format or a 2>/dev/null inside a nested command
      # substitution is not a denominator.
      if (line ~ /\$\(\(/) {
        st = index(line, "$((")
        tail2 = substr(line, st + 3)
        expr = ""
        depth = 1
        for (c = 1; c <= length(tail2); c++) {
          ch = substr(tail2, c, 1)
          if (ch == "(") { expr = expr ch; continue }
          if (ch == ")") {
            if (substr(tail2, c + 1, 1) == ")") break
            expr = expr ch
            continue
          }
          expr = expr ch
        }
        depth = 0
        delete SEENDEN
        for (c = 1; c <= length(expr); c++) {
          ch = substr(expr, c, 1)
          if (ch == "(") { depth++; continue }
          if (ch == ")") { depth--; continue }
          if (depth != 0) continue
          if (ch != "/" && ch != "%") continue
          if (ch == "%") {
            prevc = substr(expr, c - 1, 1)
            nextc = substr(expr, c + 1, 1)
            if (prevc != " " && prevc != "\t") continue
            if (nextc != " " && nextc != "\t") continue
          }
          rest = substr(expr, c + 1)
          gsub(/^[ \t]+/, "", rest)
          if (!match(rest, /^\$?[A-Za-z_][A-Za-z0-9_]*/)) continue
          den = substr(rest, RSTART, RLENGTH)
          gsub(/^\$/, "", den)
          if (den == "" || den in GUARDED || den in SEENDEN) continue
          SEENDEN[den] = 1
          printf "%d\trate-without-denominator\tdivides by %s with no zero guard on %s\n", i, den, den
        }
      }
      # --- discarded-negative-assertion -----------------------------------
      if (line ~ /^[ \t]*(!|[[]\[?[ \t]+!|[[]\[?[ \t]+"?\$[A-Za-z_][A-Za-z0-9_]*"?[ \t]+(!=|-ne)[ \t])/) {
        if (line !~ /(&&|\|\||;)/) {
          consumed = 0
          for (j = i - 1; j >= 1; j--) {
            if (L[j] ~ /^[ \t]*#/ || L[j] ~ /^[ \t]*$/) continue
            prev = L[j]
            gsub(/^[ \t]+/, "", prev)
            if (prev ~ /(then|do)$/ || prev ~ /^(if|elif|while|until) /) consumed = 1
            break
          }
          lastcode = 1
          for (j = i + 1; j <= n; j++) {
            if (L[j] ~ /^[ \t]*#/ || L[j] ~ /^[ \t]*$/) continue
            lastcode = 0
            break
          }
          if (!consumed && !lastcode) {
            printf "%d\tdiscarded-negative-assertion\tstatus discarded by a later command so the check cannot fail here\n", i
          }
        }
      }
      # --- stale-reading ---------------------------------------------------
      if (line ~ /(stat[ \t]+[-A-Za-z]*[ \t]*%[Ym]|date[ \t]+-r|find[ \t].*-m(time|min)|-newer)/) {
        tok = ""
        if (match(line, /%[Ym]/)) {
          tail = substr(line, RSTART + RLENGTH)
          gsub(/^[ \t"`\\]+/, "", tail)
          sub(/[ \t].*$/, "", tail)
          tok = tail
        } else {
          m = split(line, a, /[ \t]+/)
          tok = a[m]
        }
        b = tok
        gsub(/["\047`]/, "", b)
        sub(/[;,)&|]+$/, "", b)
        v = b
        sub(/^\$/, "", v)
        if ((v in MAP) && b ~ /^\$/) b = MAP[v]
        gsub(/["\047`]/, "", b)
        nsplit = split(b, q, "/")
        b = q[nsplit]
        if (b != "" && (b in TOUCHED)) {
          printf "%d\tstale-reading\treads the mtime of %s which this check writes itself instead of the fact it measures\n", i, b
        }
      }
      # --- failure-path-exit-zero ------------------------------------------
      # What is guarded decides the reading, and the reading is stated per hit.
      # Silence after a failed MEASUREMENT reports a broken instrument as
      # health; silence after a failed PRESENCE GATE reports absence as health,
      # which a poll shim with an optional trigger may intend. Both are the
      # same class; the message says which one this hit is.
      if (match(line, /\|\|[ \t]*exit[ \t]+0/)) {
        pre = substr(line, 1, RSTART - 1)
        sub(/^[ \t]+/, "", pre)
        if (pre ~ /(^|[^A-Za-z0-9_])(grep|stat|cat|curl|python3?|jq|git|find|date|awk|sqlite3|kubectl|aws|sed|wc|head|tail|sort|command)([^A-Za-z0-9_]|$)/ || pre ~ /=\$\(/) {
          printf "%d\tfailure-path-exit-zero\ta failed measurement exits 0, reporting an unreadable instrument as health\n", i
        } else if (pre ~ /^\[/ || pre ~ /exec[ \t]+[0-9]+</ || pre ~ /IFS= read/ || pre ~ /^case /) {
          GATES = GATES (GATES == "" ? "" : ",") i
        }
      }
      if (line ~ /^[ \t]*exit[ \t]+0[ \t]*$/) {
        for (k = i - 1; k >= 1 && k >= i - 2; k--) {
          if (L[k] ~ /^[ \t]*#/ || L[k] ~ /^[ \t]*$/) continue
          low = tolower(L[k])
          if (low ~ /(error|fail|unable|unavailable|missing|absent|cannot|refus)/) {
            printf "%d\tfailure-path-exit-zero\terror branch exits 0\n", i
            break
          }
        }
      }
    }
    if (GATES != "") {
      k = split(GATES, g, ",")
      shown = ""
      for (j = 1; j <= k && j <= 12; j++) shown = shown (shown == "" ? "" : ",") g[j]
      printf "0\tunproven\t%d presence gate(s) exit 0 (lines %s%s); whether absence is an anomaly depends on each check contract, so these are not proven clean\n", k, shown, (k > 12 ? ",..." : "")
    }
    if (n > 0) {
      for (i = 1; i <= n; i++) {
        if (L[i] ~ /^[ \t]*#/ || L[i] ~ /^[ \t]*$/) continue
        if (L[i] ~ /(^|[^A-Za-z])awk[ \t]/) { printf "0\tunproven\tawk-program arithmetic is not analysed\n"; break }
      }
    }
  }
  ' "$2" "$1"
}

# --- marker corpus ----------------------------------------------------------

# globals_index records one assignment per variable across the whole corpus.
# Firstmate resolves state paths through variables assigned in one bin script and
# read in another (FM_WAKE_QUEUE, STATE, ...), so a per-file map would call every
# such marker unwritten. One level of indirection is what the corpus needs.
globals_index() { # files... -> "var<TAB>value" rows
  local f
  : > "$TMP/globals.tsv"
  for f in "$@"; do
    [ -f "$f" ] || continue
    awk '
    { L[FNR] = $0 }
    END {
      n = FNR
      for (i = 1; i <= n; i++) {
        if (L[i] !~ /^[ \t]*(export[ \t]+)?[A-Za-z_][A-Za-z0-9_]*=/) continue
        s = L[i]
        sub(/^[ \t]*(export[ \t]+)?/, "", s)
        v = substr(s, 1, index(s, "=") - 1)
        # A corpus-wide map collides on loop variables (d, f, k). Keep only
        # names that read as constants.
        if (v !~ /^[A-Z][A-Z0-9_]*$/ && length(v) < 4) continue
        if (v in SEEN) continue
        SEEN[v] = 1
        val = substr(s, index(s, "=") + 1)
        sub(/[ \t]+#.*$/, "", val)
        sub(/[ \t]+$/, "", val)
        gsub(/["\047]/, "", val)
        printf "%s\t%s\n", v, val
      }
    }
    ' "$f" >> "$TMP/globals.tsv"
  done
}

writer_index() { # files... -> "base<TAB>literal" rows
  local f
  : > "$TMP/writers.tsv"
  for f in "$@"; do
    [ -f "$f" ] || continue
    awk '
    function valid_base(b) {
      return b ~ /^[.A-Za-z0-9_][A-Za-z0-9_.-]*$/
    }
    BEGIN {
      SQ = sprintf("%c", 39)
      DYN_SQ = "(printf|echo)[ \t]+" SQ "[^" SQ "]*" SQ
      DYN_SQ_PREFIX = "^(printf|echo)[ \t]+" SQ
    }
    function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
    function base_of(t,   n, a, v) {
      gsub(/["\047`]/, "", t)
      sub(/[;,)&|]+$/, "", t)
      if (t ~ /^\$[A-Za-z_][A-Za-z0-9_]*$/) {
        v = substr(t, 2)
        if (v in MAP) t = MAP[v]
      } else if (t ~ /^\$\{[A-Za-z_][A-Za-z0-9_]*\}$/) {
        v = t
        gsub(/[${}]/, "", v)
        if (v in MAP) t = MAP[v]
      }
      gsub(/["\047`]/, "", t)
      sub(/[;,)&|]+$/, "", t)
      gsub(/["\047`]/, "", t)
      sub(/[;,)&|]+$/, "", t)
      sub(/^\$\{[A-Za-z_][A-Za-z0-9_]*:-/, "", t)
    gsub(/\}/, "", t)
    n = split(t, a, "/")
      return a[n]
    }
    { L[FNR] = $0 }
    END {
      n = FNR
      for (i = 1; i <= n; i++) {
        line = L[i]
        if (line ~ /^[ \t]*#/) continue
        if (match(line, /^[ \t]*(export[ \t]+)?[A-Za-z_][A-Za-z0-9_]*=/)) {
          s = substr(line, RSTART, RLENGTH)
          gsub(/^[ \t]*(export[ \t]+)?/, "", s)
          v = substr(s, 1, index(s, "=") - 1)
          if (!(v in MAP)) MAP[v] = trim(substr(line, RSTART + RLENGTH))
        }
      }
      for (i = 1; i <= n; i++) {
        line = L[i]
        if (line ~ /^[ \t]*#/) continue
        if (line !~ /(>>?|touch|tee|mv|cp|install)/) continue
        lit = ""
        if (match(line, /(printf|echo)[ \t]+"[^"]*"/)) {
          s = substr(line, RSTART, RLENGTH)
          sub(/^(printf|echo)[ \t]+"/, "", s)
          sub(/"$/, "", s)
          if (s !~ /\$/) lit = s
        } else if (match(line, DYN_SQ)) {
          s = substr(line, RSTART, RLENGTH)
          sub(DYN_SQ_PREFIX, "", s)
          sub(SQ "$", "", s)
          if (s !~ /\$/) lit = s
        }
        # A redirect may be attached to its target (>>"$Q") or separated
        # (>> "$Q"), so strip leading >s from the token before treating the
        # remainder as the written path.
        m = split(line, a, /[ \t;|&()]+/)
        for (k = 1; k <= m; k++) {
          tok = a[k]
          cmd = tok
          sub(/^.*\//, "", cmd)
          if (tok ~ /^>>?./) {
            sub(/^>>?/, "", tok)
            b = base_of(tok)
          } else if (tok ~ /^>>?$/) {
            b = base_of(a[k + 1])
          } else if (cmd == "touch" || cmd == "tee") {
            b = base_of(a[k + 1])
          } else if (cmd == "mv" || cmd == "cp") {
            last = ""
            for (q = 1; q <= m; q++) if (a[q] != "") last = a[q]
            b = base_of(last)
          } else {
            continue
          }
          if (!valid_base(b) || b ~ /^[0-9]+$/) continue
          printf "%s\t%s\n", b, lit
        }
      }
    }
    ' "$f" >> "$TMP/writers.tsv"
  done
  printf '%s\t\n' '-' >> "$TMP/writers.tsv"
}

detect_markers() { # file -> defect rows
  awk '
  function valid_base(b) {
    return b ~ /^[.A-Za-z0-9_][A-Za-z0-9_.-]*$/
  }
  function markerish(b) {
    if (!valid_base(b)) return 0
    return b ~ /^\./ || b ~ /\.(json|jsonl|log|last|seen|marker|beat|state|status|tmp)$/
  }
  # A label comparison is only meaningful when it tests equality against a
  # non-numeric word; numeric thresholds against a timestamp marker are a
  # different question and are not this class.
  function label_in(line,   s) {
    if (!match(line, /(^|[ \t])==?[ \t]*"?[A-Za-z][A-Za-z0-9_.:-]*/)) return ""
    s = substr(line, RSTART, RLENGTH)
    gsub(/^[ \t=]+/, "", s)
    gsub(/^"/, "", s)
    return s
  }
  # resolved_path substitutes known assignments so the sweep can tell whether the
  # marker lives in the namespace it actually scanned.
  function strip_path(t) {
    gsub(/["\047`]/, "", t)
    sub(/[;,)&|]+$/, "", t)
    return t
  }
  function resolved_path(t,   v, s, rest, guard) {
    guard = 0
    while (guard++ < 4) {
      t = strip_path(t)
      if (t ~ /^\$HOME\//) { t = HOME_ROOT substr(t, 6); continue }
      if (PROBE_DIR != "" && t ~ /^\$\{?FM_PROBE_ROOT\}?\//) {
        sub(/^\$\{?FM_PROBE_ROOT\}?\//, "", t)
        t = PROBE_DIR "/" t
        continue
      }
      if (t ~ /^~\//) { t = HOME_ROOT substr(t, 2); continue }
      if (match(t, /^\$\{?[A-Za-z_][A-Za-z0-9_]*\}?(\/|$)/)) {
        s = substr(t, RSTART, RLENGTH)
        v = s
        gsub(/[${}]/, "", v)
        sub(/\/.*$/, "", v)
        if ((v in MAP) || (v in GMAP)) {
          rest = substr(t, RLENGTH + 1)
          t = strip_path((v in MAP) ? MAP[v] : GMAP[v]) rest
          continue
        }
      }
      break
    }
    return strip_path(t)
  }
  function scanned_path(t,   r) {
    r = resolved_path(t)
    if (r !~ /^\//) return 1
    if (index(r, STATE_ROOT) == 1) return 1
    if (index(r, FM_ROOT) == 1) return 1
    if (PROBE_DIR != "" && index(r, PROBE_DIR) == 1) return 1
    return 0
  }
  function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
  function base_of(t,   n, a, v) {
    gsub(/["\047`]/, "", t)
    sub(/[;,)&|]+$/, "", t)
    # ${VAR:-default} carries its value in the default branch.
    sub(/^\$\{[A-Za-z_][A-Za-z0-9_]*:-/, "", t)
    gsub(/\}/, "", t)
    if (t ~ /^\$[A-Za-z_][A-Za-z0-9_]*$/) {
      v = substr(t, 2)
      if (v in MAP) t = MAP[v]
      else if (v in GMAP) t = GMAP[v]
    } else if (t ~ /^\$\{[A-Za-z_][A-Za-z0-9_]*\}$/) {
      v = t
      gsub(/[${}]/, "", v)
      if (v in MAP) t = MAP[v]
      else if (v in GMAP) t = GMAP[v]
    }
    gsub(/["\047`]/, "", t)
    sub(/[;,)&|]+$/, "", t)
    # ${VAR:-default} carries its value in the default branch.
    sub(/^\$\{[A-Za-z_][A-Za-z0-9_]*:-/, "", t)
    gsub(/\}/, "", t)
    sub(/^\$\{[A-Za-z_][A-Za-z0-9_]*:-/, "", t)
    gsub(/\}/, "", t)
    n = split(t, a, "/")
    return a[n]
  }
  BEGIN {
    gf = ENVIRON["FM_SWEEP_GLOBALS"]
    if (gf != "") {
      while ((getline gl < gf) > 0) {
        split(gl, gp, "\t")
        if (gp[1] != "" && !(gp[1] in GMAP)) GMAP[gp[1]] = gp[2]
      }
      close(gf)
    }
  }
  NR == FNR { WRITTEN[$1] = 1; if ($2 != "") WRLIT[$1] = WRLIT[$1] SUBSEP $2; next }
  { L[FNR] = $0 }
  END {
    n = FNR
    for (i = 1; i <= n; i++) {
      line = L[i]
      if (line ~ /^[ \t]*#/) continue
      if (match(line, /^[ \t]*(export[ \t]+)?[A-Za-z_][A-Za-z0-9_]*=/)) {
        s = substr(line, RSTART, RLENGTH)
        gsub(/^[ \t]*(export[ \t]+)?/, "", s)
        v = substr(s, 1, index(s, "=") - 1)
        rhs = trim(substr(line, RSTART + RLENGTH))
        if (!(v in MAP)) MAP[v] = rhs
        if (rhs ~ /(cat[ \t]+|read[ \t].*-r[ \t]|<[ \t]*"?\$)/) {
          tok = rhs
          m = split(tok, z, /[ \t;|&()]+/)
          for (k = 1; k <= m; k++) {
            b = base_of(z[k])
            if (markerish(b) && (b in WRITTEN)) SRC[v] = b
          }
        }
      }
    }
    for (i = 1; i <= n; i++) {
      line = L[i]
      if (line ~ /^[ \t]*#/) continue
      read_tok = ""
      if (match(line, /-[fserd][ \t]+[^ \t\])]+/)) {
        s = substr(line, RSTART, RLENGTH)
        sub(/^-[fserd][ \t]+/, "", s)
        read_tok = s
      } else if (match(line, /(cat|tee|stat)[ \t]+[^ \t\])]+/)) {
        s = substr(line, RSTART, RLENGTH)
        sub(/^(cat|tee|stat)[ \t]+/, "", s)
        read_tok = s
      }
      if (read_tok != "") {
        b = base_of(read_tok)
        if (markerish(b) && !(b in WRITTEN)) {
          rp = resolved_path(read_tok)
          if (rp ~ /\$/) {
            printf "0\tunproven\tline %d: marker path %s depends on a value the sweep cannot resolve, so an unseen writer there is unproven\n", i, rp
          } else if (scanned_path(read_tok)) {
            printf "%d\torphan-marker\treads marker %s, which nothing in the scanned writer corpus (state checks plus bin) writes\n", i, b
          } else {
            printf "0\tunproven\tline %d: marker %s lives outside the scanned writer space (state dir and repo), so an unseen writer there is unproven, not a defect\n", i, rp
          }
        } else if (markerish(b) && (b in WRLIT)) {
          lit = label_in(line)
          if (lit != "" && index(WRLIT[b], SUBSEP lit) == 0) {
            printf "%d\torphan-marker\tcompares %s against the label %s, which no writer of %s writes\n", i, b, lit, b
          }
        }
      }
    }
    for (v in SRC) {
      for (i = 1; i <= n; i++) {
        line = L[i]
        if (line ~ /^[ \t]*#/) continue
        if (line !~ ("\\$" v "([^A-Za-z0-9_]|$)")) continue
        lit = label_in(line)
        if (lit == "") continue
        b = SRC[v]
        if (index(WRLIT[b], SUBSEP lit) == 0) {
          printf "%d\torphan-marker\tcompares %s read from %s against the label %s, which no writer of %s writes\n", i, v, b, lit, b
        }
      }
    }
  }
  ' "STATE_ROOT=$STATE" "FM_ROOT=$FM_ROOT" "HOME_ROOT=$HOME" \
    "PROBE_DIR=$PROBE_DIR" \
    "$TMP/writers.tsv" "$1"
}

# --- differential probe -----------------------------------------------------

probe_files() { # id -> 0 when both probe and check exist
  [ -n "$PROBE_DIR" ] || return 1
  [ -f "$PROBE_DIR/$1.probe.sh" ] && [ -f "$STATE/$1.check.sh" ]
}

run_probe() { # id -> sets PROBE_RESULT=distinct|identical|error:<reason>, PROBE_LINE
  local id=$1 sandbox variant out
  PROBE_RESULT=
  PROBE_LINE=1
  sandbox="$TMP/probe-$id"
  rm -rf -- "$sandbox"
  mkdir -p "$sandbox" || { PROBE_RESULT="error:cannot create sandbox"; return 0; }
  for variant in healthy broken; do
    out="$TMP/probe-$id.$variant.out"
    if ! FM_PROBE_VARIANT=$variant FM_PROBE_ROOT=$sandbox \
      bash "$PROBE_DIR/$id.probe.sh" >"$TMP/probe-$id.$variant.setup" 2>&1; then
      PROBE_RESULT="error:probe setup failed for $variant"
      return 0
    fi
    (cd "$sandbox" && FM_PROBE_VARIANT=$variant FM_PROBE_ROOT=$sandbox \
      timeout "$PROBE_TIMEOUT" bash "$STATE/$id.check.sh") >"$out.stdout" 2>"$out.stderr"
    echo $? > "$out.status"
  done
  if cmp -s "$TMP/probe-$id.healthy.out.stdout" "$TMP/probe-$id.broken.out.stdout" &&
    cmp -s "$TMP/probe-$id.healthy.out.stderr" "$TMP/probe-$id.broken.out.stderr" &&
    [ "$(cat "$TMP/probe-$id.healthy.out.status")" = "$(cat "$TMP/probe-$id.broken.out.status")" ]; then
    PROBE_RESULT=identical
    PROBE_LINE=$(emitting_line "$STATE/$id.check.sh" "$(cat "$TMP/probe-$id.healthy.out.stdout")")
  else
    PROBE_RESULT=distinct
  fi
}

# emitting_line picks the line that produced the unchanged output, so an
# identical-output finding points at the statement that says the same words in
# both cases rather than at the top of the file.
emitting_line() { # file captured-stdout -> line number
  local file=$1 captured=$2 i=0 line lit first_output= first_exec=
  while IFS= read -r line; do
    i=$((i + 1))
    case $line in
    '' | '#'* | [[:space:]]*'#'*) continue ;;
    esac
    [ -n "$first_exec" ] || first_exec=$i
    case $line in
    *echo* | *printf* | *cat\ * | *cat\"*) [ -n "$first_output" ] || first_output=$i ;;
    esac
    case $line in
    *echo* | *printf*) ;;
    *) continue ;;
    esac
    while IFS= read -r lit; do
      case $lit in
      *%*) lit=${lit%%%*} ;;
      esac
      case $lit in
      *\*) lit=${lit%%\*} ;;
      esac
      [ "${#lit}" -ge 6 ] || continue
      case $captured in
      *"$lit"*) echo "$i"; return 0 ;;
      esac
    done < <(printf '%s
' "$line" | grep -o -e "'[^']*'" -e '"[^"]*"' |
      sed -e "s/^'//" -e "s/'$//" -e 's/^"//' -e 's/"$//')
  done < "$file"
  echo "${first_output:-${first_exec:-1}}"
}

# --- output -----------------------------------------------------------------

print_findings_for() { # id
  local id=$1 i best_damage tmp
  tmp="$TMP/findings.$id"
  : > "$tmp"
  i=0
  while [ "$i" -lt "${#F_ID[@]}" ]; do
    if [ "${F_ID[$i]}" = "$id" ]; then
      printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$(damage_of "${F_CLASS[$i]}")" "${F_LINE[$i]}" \
        "${F_CLASS[$i]}" "${F_FILE[$i]}" "${F_MSG[$i]}" "${F_SNIPPET[$i]}" >> "$tmp"
    fi
    i=$((i + 1))
  done
  sort -t "$(printf '\t')" -k1,1nr -k2,2n "$tmp" 2>/dev/null > "$tmp.sorted" || cp "$tmp" "$tmp.sorted"
  while IFS=$'\t' read -r damage line class file msg snippet; do
    [ -n "${damage:-}" ] || continue
    file=$(display_path "$file")
    if [ "$TSV" = 1 ]; then
      printf 'finding\t%s\t%s\t%s\t%s\t%s [source: %s]\n' "$id" "$class" "$file" "$line" "$msg" "$snippet"
    else
      printf '  defect damage=%s %s %s:%s: %s [source: %s]\n' "$damage" "$class" "$file" "$line" "$msg" "$snippet"
    fi
  done < "$tmp.sorted"
}

emit_result() { # id verdict reason
  if [ "$TSV" = 1 ]; then
    printf 'verdict\t%s\t%s\t%s\n' "$1" "$2" "$3"
  else
    printf '  result %s %s (%s)\n' "$1" "$2" "$3"
  fi
}

# --- main -------------------------------------------------------------------

CHECK_FILES=()
for f in "$STATE"/*.check.sh; do
  [ -e "$f" ] || continue
  [ -L "$f" ] && continue
  [ -f "$f" ] || continue
  CHECK_FILES[${#CHECK_FILES[@]}]=$f
done

CORPUS_FILES=()
I=0
while [ "$I" -lt "${#CHECK_FILES[@]}" ]; do
  f=${CHECK_FILES[$I]}
  id=$(basename "$f")
  id=${id%.check.sh}
  trust=$(trust_state "$STATE" "$id" "$f")
  delegate=
  if is_shim_body "$f"; then
    delegate=$(delegate_of "$f")
  fi
  if [ -n "$delegate" ]; then
    add_check "$id" "$trust" "$delegate" "$delegate"
  else
    add_check "$id" "$trust" "$delegate" "$f"
  fi
  CORPUS_FILES[${#CORPUS_FILES[@]}]=${CK_BODIES[$I]}
  if [ "$trust" != ok ]; then
    add_note "$id" "check is not armed with a matching trust binding (trust=$trust)"
  fi
  I=$((I + 1))
done

CORPUS_FILES_UNIQUE=()
I=0
while [ "$I" -lt "${#CORPUS_FILES[@]}" ]; do
  seen=0
  J=0
  while [ "$J" -lt "${#CORPUS_FILES_UNIQUE[@]}" ]; do
    [ "${CORPUS_FILES_UNIQUE[$J]}" != "${CORPUS_FILES[$I]}" ] || { seen=1; break; }
    J=$((J + 1))
  done
  [ "$seen" = 1 ] || CORPUS_FILES_UNIQUE[${#CORPUS_FILES_UNIQUE[@]}]=${CORPUS_FILES[$I]}
  I=$((I + 1))
done

WRITER_FILES=("${CORPUS_FILES_UNIQUE[@]}")
if [ -n "$PROBE_DIR" ]; then
  for f in "$PROBE_DIR"/*.probe.sh; do
    [ -f "$f" ] || continue
    WRITER_FILES[${#WRITER_FILES[@]}]=$f
  done
fi
for d in "${EXTRA_WRITERS[@]}"; do
  [ -d "$d" ] || continue
  for f in "$d"/*.sh; do
    [ -f "$f" ] || continue
    WRITER_FILES[${#WRITER_FILES[@]}]=$f
  done
done
writer_index "${WRITER_FILES[@]}"
globals_index "${WRITER_FILES[@]}"

printf '#instrument-sweep-v1\n' > "$TMP/rows"
if [ "$TSV" != 1 ]; then
  printf 'instrument-sweep v1\n'
fi

FM_SWEEP_GLOBALS=$TMP/globals.tsv
export FM_SWEEP_GLOBALS

I=0
while [ "$I" -lt "${#CK_ID[@]}" ]; do
  id=${CK_ID[$I]}
  body=${CK_BODIES[$I]}
  if [ "$TSV" != 1 ]; then
    printf 'check %s trust=%s' "$id" "${CK_TRUST[$I]}"
    [ -z "${CK_DELEGATE[$I]}" ] || printf ' delegate=%s' "${CK_DELEGATE[$I]}"
    printf '\n'
  fi
  printf '%s\t\n' '-' > "$TMP/evidence.$I"
  collect_evidence "$body" >> "$TMP/evidence.$I"
  detect_static "$body" "$TMP/evidence.$I" > "$TMP/defects.$I"
  detect_markers "$body" >> "$TMP/defects.$I"
  while IFS=$'\t' read -r line class msg; do
    [ -n "${line:-}" ] || continue
    if [ "$class" = unproven ]; then
      add_note "$id" "$msg"
    else
      add_finding "$id" "$class" "$body" "$line" "$msg"
    fi
  done < "$TMP/defects.$I"

  probe_reason=''
  PROBE_RESULT=
  PROBE_LINE=1
  if probe_files "$id"; then
    run_probe "$id"
    case $PROBE_RESULT in
    identical)
      if [ -s "$TMP/probe-$id.healthy.out.stdout" ]; then
        detail="printed byte-identical stdout, stderr, and status for a healthy and a broken fact"
      else
        detail="printed no output and the same status for a healthy and a broken fact"
      fi
      add_finding "$id" identical-output "$STATE/$id.check.sh" "$PROBE_LINE" "$detail"
      ;;
    error:*)
      probe_reason="probe did not run: ${PROBE_RESULT#error:}"
      ;;
    distinct) ;;
    esac
  fi

  # verdict: worst defect, then proven, then unproven with a stated reason
  best_damage=0
  j=0
  while [ "$j" -lt "${#F_ID[@]}" ]; do
    if [ "${F_ID[$j]}" = "$id" ]; then
      d=$(damage_of "${F_CLASS[$j]}")
      [ "$d" -le "$best_damage" ] || best_damage=$d
    fi
    j=$((j + 1))
  done

  # shellcheck disable=SC2004 # Array subscripts are arithmetic expressions; $I is spelled out so the index reads as a variable.
  if [ "$best_damage" -gt 0 ]; then
    CK_VERDICT[$I]=DEFECT
    CK_REASON[$I]=$(printf '%s' "highest damage $best_damage")
  elif [ "${PROBE_RESULT:-}" = distinct ]; then
    CK_VERDICT[$I]=PROVEN-DISTINGUISHING
    CK_REASON[$I]="differential probe produced different output for a healthy and a broken fact"
  else
    CK_VERDICT[$I]=UNPROVEN
    if [ -n "${CK_DELEGATE[$I]}" ]; then
      CK_REASON[$I]="shim body delegates to ${CK_DELEGATE[$I]}; that target carries the logic and was analysed"
    elif [ "${CK_TRUST[$I]}" != ok ]; then
      CK_REASON[$I]="no matching trust binding (trust=${CK_TRUST[$I]}), so no differential evidence is possible"
    elif [ -n "$probe_reason" ]; then
      CK_REASON[$I]=$probe_reason
    else
      CK_REASON[$I]="static analysis found no defect, but nothing proved the check distinguishes a broken fact; no probe scenario was supplied"
    fi
  fi

  print_findings_for "$id"
  j=0
  while [ "$j" -lt "${#N_ID[@]}" ]; do
    if [ "${N_ID[$j]}" = "$id" ]; then
      if [ "$TSV" = 1 ]; then
        printf 'note\t%s\tunproven\t%s\t0\t%s\n' "$id" "$(display_path "$body")" "${N_MSG[$j]}"
      else
        printf '  note unproven: %s\n' "${N_MSG[$j]}"
      fi
    fi
    j=$((j + 1))
  done
  emit_result "$id" "${CK_VERDICT[$I]}" "${CK_REASON[$I]}"
  [ "$TSV" = 1 ] || printf '\n'
  I=$((I + 1))
done

# --- ranking ----------------------------------------------------------------

: > "$TMP/rank"
j=0
while [ "$j" -lt "${#F_ID[@]}" ]; do
  printf '%s\t%s\t%s\t%s\t%s\n' "$(damage_of "${F_CLASS[$j]}")" "${F_ID[$j]}" "${F_CLASS[$j]}" \
    "${F_FILE[$j]}" "${F_LINE[$j]}" >> "$TMP/rank"
  j=$((j + 1))
done
sort -t "$(printf '\t')" -k1,1nr -k2,2 "$TMP/rank" > "$TMP/rank.sorted" 2>/dev/null || cp "$TMP/rank" "$TMP/rank.sorted"

if [ "$TSV" = 1 ]; then
  n=0
  while IFS=$'\t' read -r d id class file line; do
    [ -n "${d:-}" ] || continue
    n=$((n + 1))
    printf 'rank\t%s\t%s\t%s\t%s\t%s\t%s\n' "$n" "$d" "$id" "$class" "$(display_path "$file")" "$line"
  done < "$TMP/rank.sorted"
else
  printf 'defect ranking (damage desc, then check id)\n'
  n=0
  while IFS=$'\t' read -r d id class file line; do
    [ -n "${d:-}" ] || continue
    n=$((n + 1))
    printf '%2d. damage=%s %s %s %s:%s\n' "$n" "$d" "$id" "$class" "$(display_path "$file")" "$line"
  done < "$TMP/rank.sorted"
  [ "$n" -gt 0 ] || printf 'none\n'
fi

DEFECT_COUNT=0
UNPROVEN_COUNT=0
PROVEN_COUNT=0
I=0
while [ "$I" -lt "${#CK_ID[@]}" ]; do
  case ${CK_VERDICT[$I]} in
  DEFECT) DEFECT_COUNT=$((DEFECT_COUNT + 1)) ;;
  UNPROVEN) UNPROVEN_COUNT=$((UNPROVEN_COUNT + 1)) ;;
  PROVEN-DISTINGUISHING) PROVEN_COUNT=$((PROVEN_COUNT + 1)) ;;
  esac
  I=$((I + 1))
done

if [ "$TSV" = 1 ]; then
  printf 'summary\tchecks=%s\tdefect=%s\tunproven=%s\tproven=%s\n' \
    "${#CK_ID[@]}" "$DEFECT_COUNT" "$UNPROVEN_COUNT" "$PROVEN_COUNT"
else
  printf '\nsummary: checks=%s defect=%s unproven=%s proven=%s findings=%s\n' \
    "${#CK_ID[@]}" "$DEFECT_COUNT" "$UNPROVEN_COUNT" "$PROVEN_COUNT" "${#F_ID[@]}"
fi

if [ "$FAIL_ON_DEFECT" = 1 ] && [ "$DEFECT_COUNT" -gt 0 ]; then
  exit 1
fi
exit 0
