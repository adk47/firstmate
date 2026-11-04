#!/usr/bin/env bats
# Tests for scripts/lib/systemd-env-assignments.sh — the ONE parser and the ONE
# name/value predicate shared by the CI gate and the deploy-time check.
#
# Every round of review found a different dimension of the same mistake in this
# code: comparing a text line to a rule instead of asking what systemd will load.
# The dimensions are now explicit test cases, so a future "simplification" cannot
# silently drop one:
#
#   * several assignments on one physical line
#   * a quoted value containing spaces
#   * a quoted value containing a TAB (a field-split used to truncate it)
#   * a quote opening before the name
#   * a LINE CONTINUATION (`Environment=\` + next line), which systemd joins
#   * an even run of trailing backslashes, which is NOT a continuation
#
# The suite is pure-function: it feeds text in and asserts the parsed
# assignments out, with no filesystem or systemd involvement.

setup() {
    LIB="${BATS_TEST_DIRNAME}/../lib/systemd-env-assignments.sh"
    [[ -f "$LIB" ]] || { echo "parser lib not found: $LIB" >&2; return 1; }
    # shellcheck source=/dev/null
    source "$LIB"
}

names() { sdenv_assignments | cut -f2 | paste -sd, -; }
# value_of keeps EVERY remaining field joined with tabs: a value may legitimately
# contain tabs, and `cut -f3` would silently truncate exactly the case this suite
# exists to protect.
value_of() { sdenv_assignments | awk -F'\t' -v n="$1" '$2 == n { out=$3; for (i=4; i<=NF; i++) out=out "\t" $i; print out }'; }
line_of() { sdenv_assignments | awk -F'\t' -v n="$1" '$2 == n { print $1 }'; }

@test "parses a single assignment" {
    run bash -c "source '$LIB'; printf 'Environment=PORT=18792\n' | sdenv_assignments | cut -f2,3"
    [ "$output" = $'PORT\t18792' ]
}

@test "parses SEVERAL assignments on one line" {
    run bash -c "source '$LIB'; printf 'Environment=PORT=1 OPENCLAW_TOKEN=abc\n' | sdenv_assignments | cut -f2"
    [ "$output" = $'PORT\nOPENCLAW_TOKEN' ]
}

@test "keeps a quoted value with spaces whole" {
    run bash -c "source '$LIB'; printf 'Environment=\"QUOTED_TOKEN=has spaces here\" B=2\n' | sdenv_assignments | cut -f2"
    [ "$output" = $'QUOTED_TOKEN\nB' ]
    run bash -c "source '$LIB'; printf 'Environment=\"QUOTED_TOKEN=has spaces here\"\n' | sdenv_assignments | cut -f3"
    [ "$output" = "has spaces here" ]
}

@test "preserves a TAB inside a quoted value (the field-split bypass)" {
    run bash -c "source '$LIB'; printf 'Environment=\"TABBED_TOKEN=ab\\tcdef\"\n' | sdenv_assignments | awk -F'\t' '{ out=\$3; for (i=4; i<=NF; i++) out=out \"\\t\" \$i; print out }'"
    [ "$output" = $'ab\tcdef' ]
}

@test "strips a quote that opens BEFORE the name" {
    run bash -c "source '$LIB'; printf 'Environment=\"INTERCOM_TOKEN=abc\"\n' | sdenv_assignments | cut -f2"
    [ "$output" = "INTERCOM_TOKEN" ]
}

@test "JOINS a line continuation (odd trailing backslash)" {
    run bash -c "source '$LIB'; printf 'Environment=\\\\\\nFOO_SECRET=Abc123\n' | sdenv_assignments | cut -f2,3"
    [ "$output" = $'FOO_SECRET\tAbc123' ]
}

@test "reports the FIRST physical line of a continued logical line" {
    run bash -c "source '$LIB'; printf '[Service]\nEnvironment=\\\\\nFOO=bar\n' | sdenv_assignments | cut -f1"
    [ "$output" = "2" ]
}

@test "does NOT join on an even run of trailing backslashes" {
    # `Environment=X=1\\` ends with an escaped backslash, so the next line stands
    # alone — and it has no Environment= prefix, so it is not an assignment.
    run bash -c "source '$LIB'; printf 'Environment=PORT=1\\\\\\\\\nFOO_SECRET=Abc123\n' | sdenv_assignments | cut -f2"
    [ "$output" = "PORT" ]
}

@test "ignores comments and non-Environment directives" {
    run bash -c "source '$LIB'; printf '# Environment=COMMENTED=1\nExecStart=/bin/true\nEnvironment=PORT=2\n' | sdenv_assignments | cut -f2"
    [ "$output" = "PORT" ]
}

@test "EnvironmentFile= is not parsed as an assignment at all" {
    # `EnvironmentFile=` names a PATH; it must never be mistaken for an
    # assignment (an earlier parser stripped 'Environment=' out of it and yielded
    # `File=/etc/...`).
    run bash -c "source '$LIB'; printf 'EnvironmentFile=-/etc/hydra/x.env\n' | sdenv_assignments"
    [ "$output" = "" ]
}

@test "an empty value and the systemd reset '-' are not violations" {
    run bash -c "source '$LIB'; sdenv_value_is_violation '' && echo V || echo OK"
    [ "$output" = "OK" ]
    run bash -c "source '$LIB'; sdenv_value_is_violation '-' && echo V || echo OK"
    [ "$output" = "OK" ]
    run bash -c "source '$LIB'; sdenv_value_is_violation 'anything' && echo V || echo OK"
    [ "$output" = "V" ]
}

@test "the value rule fails closed on %% escapes and shell expansions" {
    for v in 'Abc12345%%xyz' 'Abc$PART' 'short' '%%'; do
        run bash -c "source '$LIB'; sdenv_value_is_violation '$v' && echo V || echo OK"
        [ "$output" = "V" ]
    done
}

@test "the name predicate covers token/secret/pass/api_key/apikey/_DSN/_KEY/credential" {
    for n in OPENCLAW_TOKEN INTERCOM_WEBHOOK_SECRET ADMIN_PASSWORD INTERCOM_API_KEY \
             STRIPE_APIKEY PROVIDER_DSN PRIVATE_KEY SERVICE_CREDENTIAL notion_api_token; do
        run bash -c "source '$LIB'; sdenv_name_is_secret '$n' && echo S || echo N"
        [ "$output" = "S" ]
    done
}

@test "the name predicate does NOT fire on ordinary knobs" {
    for n in INTERCOM_WEBHOOK_PORT OPENCLAW_URL DISPATCH_TIMEOUT_MS NOTION_VERIFICATION_DB_ID; do
        run bash -c "source '$LIB'; sdenv_name_is_secret '$n' && echo S || echo N"
        [ "$output" = "N" ]
    done
}

@test "the shipped intercom-webhook unit parses to zero secret assignments" {
    run bash -c "source '$LIB'; sdenv_assignments < '$BATS_TEST_DIRNAME/../aux-units/intercom-webhook.service' | cut -f2"
    [ "$status" -eq 0 ]
    while IFS= read -r n; do
        [ -n "$n" ] || continue
        run bash -c "source '$LIB'; sdenv_name_is_secret '$n'"
        [ "$status" -ne 0 ] || { echo "secret name in shipped unit: $n"; return 1; }
    done <<<"$output"
}

@test "a continuation SEPARATES two assignments (systemd replaces the backslash with a space)" {
    # QA round 7: `Environment=PORT=1\` + `FOO_SECRET=Abc12345X` is TWO
    # assignments in systemd (conf-parser.c sets the trailing byte to a space).
    # Joining the lines directly produced `PORT=1FOO_SECRET=Abc12345X` — one
    # assignment with a non-secret name, i.e. a clean-looking unit loading a
    # plaintext secret.
    run bash -c "source '$LIB'; printf 'Environment=PORT=1\\\\\\nFOO_SECRET=Abc12345X\\n' | sdenv_assignments | cut -f2"
    [ "$output" = $'PORT\nFOO_SECRET' ]
}

@test "a continuation between two quoted assignments keeps both names" {
    run bash -c "source '$LIB'; printf 'Environment=\"A_TOKEN=one two\"\\\\\\n\"B_SECRET=three\"\\n' | sdenv_assignments | cut -f2"
    [ "$output" = $'A_TOKEN\nB_SECRET' ]
}

@test "accepts whitespace around the directive separator (systemd strstrip()s both sides)" {
    # QA round 8 Critical: `Environment = FOO_SECRET=…` is valid systemd and loads
    # the value; requiring byte-for-byte `Environment=` emitted nothing at all.
    run bash -c "source '$LIB'; printf 'Environment = FOO_SECRET=abc123\\n' | sdenv_assignments | cut -f2"
    [ "$output" = "FOO_SECRET" ]
    run bash -c "source '$LIB'; printf 'Environment\\t=\\tFOO_TOKEN=abc123\\n' | sdenv_assignments | cut -f2"
    [ "$output" = "FOO_TOKEN" ]
    run bash -c "source '$LIB'; printf 'Environment=   BAR_SECRET=abc123\\n' | sdenv_assignments | cut -f2"
    [ "$output" = "BAR_SECRET" ]
}

@test "a COMMENT line inside a continuation is skipped, the continuation is kept" {
    # QA round 8 Important: systemd skips comment lines before joining, so this
    # loads BOTH PORT and FOO_SECRET.
    run bash -c "source '$LIB'; printf 'Environment=PORT=1\\\\\\n# skipped comment\\nFOO_SECRET=abc123\\n' | sdenv_assignments | cut -f2"
    [ "$output" = $'PORT\nFOO_SECRET' ]
}

@test "a ';' comment inside a continuation is skipped too" {
    run bash -c "source '$LIB'; printf 'Environment=PORT=1\\\\\\n; skipped\\nFOO_SECRET=abc123\\n' | sdenv_assignments | cut -f2"
    [ "$output" = $'PORT\nFOO_SECRET' ]
}

@test "EnvironmentFile with whitespace around the separator is still not an assignment" {
    run bash -c "source '$LIB'; printf 'EnvironmentFile = -/etc/hydra/x.env\\n' | sdenv_assignments"
    [ "$output" = "" ]
}

# ── the POSITIVE allow-list (retires the heuristic's whole bypass class) ──────

@test "the allow-list accepts exactly the three non-secret knobs" {
    for n in INTERCOM_WEBHOOK_PORT OPENCLAW_URL DISPATCH_TIMEOUT_MS; do
        run bash -c "source '$LIB'; sdenv_name_allowed_in_intercom_webhook_unit '$n' && echo A || echo R"
        [ "$output" = "A" ]
    done
}

@test "the allow-list rejects every credential and every unknown knob" {
    for n in OPENCLAW_TOKEN INTERCOM_TOKEN INTERCOM_API_KEY FOO_SECRET PROMPTGUARD_URL \
             QUARANTINE_PATH SLACK_CS_CHATS_WEBHOOK NOTION_API_TOKEN; do
        run bash -c "source '$LIB'; sdenv_name_allowed_in_intercom_webhook_unit '$n' && echo A || echo R"
        [ "$output" = "R" ]
    done
}
