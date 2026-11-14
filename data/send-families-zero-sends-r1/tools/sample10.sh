#!/bin/bash
# Bounded: jq over the tick's own list + check files; per sampled user, indexed probes of verify_requests by
# request id and one read of verify_messages (13,109 rows) by account.
set -u
T=/root/h2-runs/sched/20261113T2005Z
L="file:/var/lib/hydra/credit-review/ledger.sqlite3?mode=ro"
for fam in uvn-status-paid uvn-status-free r1-paid r1-free; do
  case $fam in uvn-status-*) list=$T/owing-uvn.json; camp=uvn-status;; *) list=$T/receipts/receipts-received.json; camp=status-doc-received;; esac
  case $fam in *-paid) paid=true;; *) paid=false;; esac
  start=$(jq -r '.page.start' $T/$fam-check.json)
  jq -c --argjson p $paid --argjson s $start '[.users[]|select(.skip==null and ((.paid // false)|not|not)==$p)] | .[$s:$s+10] | to_entries[] | {i:($s+.key), u:(.value.user_id|tostring), r:.value.request_ids}' $list > /tmp/sfz-s2-$fam.jsonl
  while read -r row; do
    idx=$(jq -r .i <<<"$row"); uid=$(jq -r .u <<<"$row"); n=$(jq -r '.r|length' <<<"$row")
    inl=$(jq -r '.r|map("\u0027"+ascii_downcase+"\u0027")|join(",")' <<<"$row")
    out=$(jq -r --arg u "$uid" '[.outcomes[]|select((.user|tostring)==$u)][0] | if . then (.result + ": " + (.reason|.[0:70])) else "" end' $T/$fam-check.json)
    docs=-; judged=-
    case $fam in uvn-status-*)
      docs=$(grep -c "^\"$uid\"," /tmp/sfz-blocked.csv)
      judged=$(sqlite3 "file:/var/lib/hydra-credit-verify/proof.sqlite?mode=ro" "SELECT count(DISTINCT request_id) FROM stage2_shadow WHERE request_id IN ($inl)");;
    esac
    own=$(sqlite3 "$L" "SELECT count(DISTINCT request_id) FROM verify_requests WHERE request_id IN ($inl) AND campaign='$camp'")
    last=$(sqlite3 "$L" "SELECT campaign||'@'||substr(coalesce(sent_at,created_at),1,10) FROM verify_messages WHERE account_id='$uid' AND status='sent' ORDER BY id DESC LIMIT 1")
    printf '%s\t%s\t%s\treqs=%s\tdocs_on_file_rows=%s\tstage2_judged=%s\tin_%s_ledger=%s\tlast_sent=%s\tgate=%s\n' "$fam" "$idx" "$uid" "$n" "$docs" "$judged" "$camp" "$own" "${last:-none}" "${out:-<no gate call>}"
  done < /tmp/sfz-s2-$fam.jsonl
done
