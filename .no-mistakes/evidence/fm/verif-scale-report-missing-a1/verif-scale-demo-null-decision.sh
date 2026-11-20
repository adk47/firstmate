#!/usr/bin/env bash
# Runs bin/fm-verif-scale-report.sh end to end over a fixture ledger via the
# same local ssh shim shape the tests use, and prints the report verbatim.
set -u
REPO=/home/aaron/.no-mistakes/worktrees/72295860b10d/01M7WEBE44GSS6CTVHPH6TWKRD
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cat > "$WORK/ssh" <<'EOF'
#!/usr/bin/env bash
cmd=${*: -1}
exec bash -c "$cmd"
EOF
chmod +x "$WORK/ssh"
cat > "$WORK/trino-query.sh" <<'EOF'
#!/usr/bin/env bash
printf 'WARNING: Unable to create a system terminal, creating a dumb terminal\n' >&2
printf '"120","100","2026-11-20 10:00:00"\n'
EOF
chmod +x "$WORK/trino-query.sh"
DB="$WORK/ledger.sqlite3"
sqlite3 "$DB" "
CREATE TABLE verify_messages (id INTEGER PRIMARY KEY, campaign TEXT, status TEXT, created_at TEXT, sent_at TEXT, proof_tagged_at TEXT, proof_attachments INTEGER);
CREATE TABLE decisions (id INTEGER PRIMARY KEY, request_id TEXT, decision TEXT, mode TEXT, decided_at TEXT);
INSERT INTO verify_messages (campaign,status,created_at,sent_at,proof_tagged_at,proof_attachments) VALUES
 ('proof-need-ask','sent', strftime('%Y-%m-%dT%H:%M:%SZ','now','-8 minutes'), strftime('%Y-%m-%dT%H:%M:%SZ','now','-8 minutes'), strftime('%Y-%m-%dT%H:%M:%SZ','now'), 0),
 ('proof-need-ask','sent', strftime('%Y-%m-%d %H:%M:%S','now','-20 minutes'), strftime('%Y-%m-%d %H:%M:%S','now','-20 minutes'), NULL, 0),
 ('claim-proof-ask','sent', strftime('%Y-%m-%dT%H:%M:%SZ','now','-30 minutes'), NULL, NULL, 2),
 ('uvn-new-rows','sent', strftime('%Y-%m-%dT%H:%M:%SZ','now','-40 minutes'), strftime('%Y-%m-%dT%H:%M:%SZ','now','-40 minutes'), NULL, 0),
 ('uvn-reminder-14','sent', strftime('%Y-%m-%dT%H:%M:%SZ','now','-5 minutes'), strftime('%Y-%m-%dT%H:%M:%SZ','now','-5 minutes'), NULL, 0),
 ('proof-need-ask','sent', strftime('%Y-%m-%dT%H:%M:%SZ','now','-3 days'), strftime('%Y-%m-%dT%H:%M:%SZ','now','-3 days'), strftime('%Y-%m-%dT%H:%M:%SZ','now'), 0),
 ('claim-proof-ask','sent', strftime('%Y-%m-%dT%H:%M:%SZ','now','-4 days'), strftime('%Y-%m-%dT%H:%M:%SZ','now','-4 days'), strftime('%Y-%m-%dT%H:%M:%SZ','now'), 0),
 ('proof-need-ask','sent', strftime('%Y-%m-%dT%H:%M:%SZ','now','-5 minutes'), strftime('%Y-%m-%dT%H:%M:%SZ','now','-5 minutes'), NULL, 0);
INSERT INTO decisions (request_id,decision,mode,decided_at) VALUES
 ('r1','approve','apply', strftime('%Y-%m-%dT%H:%M:%SZ','now','-10 minutes')),
 ('r2','approve_partial','apply', strftime('%Y-%m-%dT%H:%M:%SZ','now','-15 minutes')),
 ('r3','hold','apply', strftime('%Y-%m-%dT%H:%M:%SZ','now','-12 minutes')),
 ('r4','support','apply', strftime('%Y-%m-%dT%H:%M:%SZ','now','-6 minutes'));
"
sqlite3 "$DB" "INSERT INTO decisions (request_id,decision,mode,decided_at) VALUES ('r9','approve','apply',NULL);"
START=$(sqlite3 :memory: "SELECT strftime('%Y-%m-%dT%H:%M:%SZ','now','-45 minutes');")
END=$(sqlite3 :memory: "SELECT strftime('%Y-%m-%dT%H:%M:%SZ','now','-5 minutes');")
cat > "$WORK/measured-run.env" <<EOF
# a measured run
provider=live
ledger=production
shards=3
started_at=$START
ended_at=$END
EOF
mkdir -p "$WORK/no-config"
env FM_CONFIG_OVERRIDE="$WORK/no-config" \
    FM_VERIF_SCALE_SSH="$WORK/ssh" \
    FM_VERIF_SCALE_HOST=ledger.invalid \
    FM_VERIF_SCALE_LEDGER="$DB" \
    FM_VERIF_SCALE_TRINO="$WORK/trino-query.sh" \
    FM_VERIF_SCALE_RUN_RECORD="$WORK/measured-run.env" \
    "$REPO/bin/fm-verif-scale-report.sh"
