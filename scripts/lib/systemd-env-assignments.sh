#!/usr/bin/env bash
# systemd-env-assignments.sh — turn the `Environment=` lines of a unit file into
# the individual assignments systemd would actually apply.
#
# WHY THIS EXISTS (T13, Fable/QA rounds, 2026-10-28)
#
# The first version of the plaintext-secret guard parsed only the FIRST
# `NAME=value` after `Environment=`. Every round since has been a bypass of a
# different dimension of the same mistake — comparing a text line to a rule
# instead of asking what systemd will actually load:
#
#   1. several assignments on one line: `Environment=PORT=1 OPENCLAW_TOKEN=…`
#      (one space walked around a prefix match);
#   2. a quoted value containing a TAB, which a `-F'\t'` split truncated, so the
#      gate inspected "ab" while systemd received the whole credential;
#   3. a line CONTINUATION: `Environment=\` on one line, `FOO_SECRET=…` on the
#      next. systemd joins them; a line-by-line parser certifies the unit clean.
#
# So this parser works on the TEXT of a whole file (not one line at a time),
# joins continuations first, then tokenises quote-aware, tab-safe, and emits the
# FIRST physical line number of each logical line so diagnostics stay useful.
#
# Syntax handled, per systemd.syntax / systemd.exec:
#   - a line ending in an ODD number of backslashes continues on the next line,
#     and systemd REPLACES that backslash with a SPACE (conf-parser.c:
#     `*(e-1) = ' '`), so a continuation can separate two assignments
#   - several assignments separated by unquoted whitespace
#   - double quotes: whitespace inside is data; `\` escapes the next character
#   - single quotes: everything literal until the closing quote
#   - a quote may open BEFORE the name (`Environment="NAME=value with spaces"`)
#     and must yield the same NAME, or the guard is walkable by one character
#
# Public API:
#   sdenv_assignments < file   # prints  <line>\t<NAME>\t<value>  per assignment
#   sdenv_name_is_secret NAME  # shared name predicate (gate + deploy check)
#   sdenv_value_is_violation V # shared value rule   (gate + deploy check)

sdenv_assignments() {
  awk '
    # ---- process one LOGICAL line -------------------------------------------
    function process(line, ln,   s, eq) {
      s = line
      sub(/^[ \t]+/, "", s)
      if (s == "") return
      if (substr(s, 1, 1) == "#" || substr(s, 1, 1) == ";") return
      # systemd strstrip()s the key and the value around the FIRST "="
      # (conf-parser.c parse_line), so `Environment = FOO=x` and `Environment= x`
      # are both valid and both LOAD the value. Requiring byte-for-byte
      # "Environment=" was a bypass: the parser emitted no assignment and the gate
      # printed OK on a unit holding a plaintext secret (QA round 8, Critical).
      if (s !~ /^Environment[ \t]*=/) return
      eq = index(s, "=")
      tokenise(substr(s, eq + 1), ln)
    }

    # ---- quote-aware split into assignments ---------------------------------
    function tokenise(body, ln,   n, i, c, state, tok) {
      n = length(body); state = "out"; tok = ""
      for (i = 1; i <= n; i++) {
        c = substr(body, i, 1)
        if (state == "out") {
          if (c == " " || c == "\t") { if (tok != "") { emit(tok, ln); tok = "" } }
          else if (c == "\"") { state = "dq"; tok = tok c }
          else if (c == "\047") { state = "sq"; tok = tok c }
          else { tok = tok c }
        } else if (state == "dq") {
          tok = tok c
          if (c == "\\") { if (i < n) { i++; tok = tok substr(body, i, 1) } }
          else if (c == "\"") { state = "out" }
        } else {
          tok = tok c
          if (c == "\047") { state = "out" }
        }
      }
      if (tok != "") emit(tok, ln)
    }

    # ---- emit NAME + the ENTIRE value ---------------------------------------
    function emit(tok, ln,   name, v) {
      name = tok
      v = ""
      if (index(tok, "=") > 1) {
        name = substr(tok, 1, index(tok, "=") - 1)
        v    = substr(tok, index(tok, "=") + 1)
      }
      if (substr(name, 1, 1) == "\"")      { name = substr(name, 2);      sub(/"$/, "", v) }
      else if (substr(name, 1, 1) == "\047") { name = substr(name, 2);     sub(/\047$/, "", v) }
      if (length(v) >= 2 && substr(v, 1, 1) == "\"" && substr(v, length(v), 1) == "\"")
        v = substr(v, 2, length(v) - 2)
      else if (length(v) >= 2 && substr(v, 1, 1) == "\047" && substr(v, length(v), 1) == "\047")
        v = substr(v, 2, length(v) - 2)
      if (name == "") return
      printf "%d\t%s\t%s\n", ln, name, v
    }

    # ---- join systemd continuations, then process --------------------------
    {
      # A comment line is skipped BEFORE the continuation is appended, and
      # skipping it does NOT end a pending continuation (conf-parser.c checks
      # COMMENTS at the top of the loop, before the join). So
      #   Environment=PORT=1\      # comment      FOO_SECRET=…
      # loads BOTH assignments; dropping the continuation here would hide the
      # secret (QA round 8, Important).
      c = $0
      sub(/^[ \t]+/, "", c)
      if (substr(c, 1, 1) == "#" || substr(c, 1, 1) == ";") next

      if (pending_ln > 0) { line = pending $0; ln = pending_ln }
      else                { line = $0;          ln = NR }
      pending = ""; pending_ln = 0

      # an ODD run of trailing backslashes continues the line; an even run is
      # escaped backslashes and does not.
      trailing = 0; i = length(line)
      while (i > 0 && substr(line, i, 1) == "\\") { trailing++; i-- }
      if (trailing % 2 == 1) {
        # systemd REPLACES the trailing backslash with a SPACE before joining
        # (src/shared/conf-parser.c sets that byte to a space character), so
        #   Environment=PORT=1\      +      FOO_SECRET=Abc…
        # is TWO assignments, not one long value. Joining them directly is a
        # bypass: the parser saw `PORT=1FOO_SECRET=Abc…`, found no secret NAME,
        # and certified the unit clean (QA round 7, reproduced against the gate).
        pending = substr(line, 1, length(line) - 1) " "
        pending_ln = ln
        next
      }
      process(line, ln)
    }
    END {
      if (pending != "") process(pending, pending_ln)
    }
  '
}

# ── the shared NAME predicate ────────────────────────────────────────────────
# ONE definition, used by the CI gate AND by the deploy-time check (and by both of
# that check's loops: installed files and systemd's loaded Environment). They
# drifted once: the CI scanner knew `_DSN`/`_KEY` and matched `API_KEY` with or
# without the underscore, while the deploy check required a character after
# `API_` and had neither suffix — so a host-side drop-in with
# `Environment=INTERCOM_API_KEY=<literal>` made `check` print OK with a plaintext
# credential still loaded. Two copies of a security predicate is the bug.
SDENV_SECRET_NAME_RE='([Tt][Oo][Kk][Ee][Nn]|[Ss][Ee][Cc][Rr][Ee][Tt]|[Pp][Aa][Ss][Ss][Ww]|[Aa][Pp][Ii]_?[Kk][Ee][Yy]|[Cc][Rr][Ee][Dd][Ee][Nn][Tt][Ii][Aa][Ll]|_DSN|_KEY)'

sdenv_name_is_secret() {  # sdenv_name_is_secret <NAME>
  printf '%s' "${1:-}" | grep -qE "$SDENV_SECRET_NAME_RE"
}

# ── the shared VALUE rule ────────────────────────────────────────────────────
# For a SECRET-NAMED variable, fail CLOSED: any value except empty (unset) or `-`
# (systemd's explicit reset) is a finding. This replaces an earlier
# "literal-looking" test, which exempted anything containing `%` or `$` and so
# certified `Environment=FOO_SECRET=Abc12345%%xyz` — a legal systemd escape that
# loads a literal `%` — as clean. The specifier/expansion distinction only ever
# mattered for values we would otherwise ACCEPT; for a secret name there is no
# such thing as a value that is fine to ship in a unit file.
sdenv_value_is_violation() {  # sdenv_value_is_violation <value>
  case "${1:-}" in
    ''|-) return 1 ;;
    *)    return 0 ;;
  esac
}

# ── the POSITIVE allow-list for intercom-webhook's unit surfaces ─────────────
# Nine review rounds produced nine bypasses of the "is this NAME secret?" and "is
# this VALUE literal?" heuristics — prefix match, tab field-split, %% escape,
# continuation concatenation, continuation-with-space, directive whitespace, a
# comment inside a continuation… Each fix taught the parser more of systemd's
# grammar, and each round the trust boundary still ran THROUGH the parser: a
# wrong join or a wrong quote rule could manufacture a passing verdict.
#
# This inverts that for the one unit we actually harden. Its unit file and every
# drop-in may name ONLY the three non-secret knobs below; the four credentials
# live in the rendered EnvironmentFile and are never named in a unit surface. A
# name outside this set fails the gate and the deploy, whatever the parser thinks
# the value is — so parser semantics stop being load-bearing for this decision.
#
# Adding a knob is a one-line PR with a reviewer, which is the correct cost for
# widening what a production unit may load from its own file.
SDENV_INTERCOM_WEBHOOK_ALLOWED_ENV='INTERCOM_WEBHOOK_PORT OPENCLAW_URL DISPATCH_TIMEOUT_MS'

sdenv_name_allowed_in_intercom_webhook_unit() {  # sdenv_name_allowed_in_intercom_webhook_unit <NAME>
  case " $SDENV_INTERCOM_WEBHOOK_ALLOWED_ENV " in
    *" ${1:-} "*) return 0 ;;
    *)            return 1 ;;
  esac
}
