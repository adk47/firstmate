#!/usr/bin/env bats
load helpers

setup() {
  setup_skill_tmp
  cat > "$WORKDIR/conversations.jsonl" <<EOF
{"id":"c1","contact_id":"contact-A","customer_email":"a@x.com"}
{"id":"c2","contact_id":"contact-A","customer_email":"a@x.com"}
{"id":"c3","contact_id":"contact-B","customer_email":"b@x.com"}
{"id":"c4","contact_id":null,"customer_email":"c@x.com"}
{"id":"c5","contact_id":null,"customer_email":"c@x.com"}
{"id":"c6","contact_id":null,"customer_email":null}
EOF
}
teardown() { teardown_skill_tmp; }

@test "dedups 3 conversations from same contact into N=1" {
  echo '{"topic":"FLAC export","conversation_ids":["c1","c2"]}' \
    | "$SCRIPTS_DIR/cluster-questions.sh" "$WORKDIR/conversations.jsonl" \
    > "$WORKDIR/out.json"
  [ "$(jq -r '.unique_customers' "$WORKDIR/out.json")" = "1" ]
}

@test "counts distinct contact_ids" {
  echo '{"topic":"FLAC export","conversation_ids":["c1","c2","c3"]}' \
    | "$SCRIPTS_DIR/cluster-questions.sh" "$WORKDIR/conversations.jsonl" \
    > "$WORKDIR/out.json"
  [ "$(jq -r '.unique_customers' "$WORKDIR/out.json")" = "2" ]
}

@test "falls back to customer_email when contact_id missing" {
  echo '{"topic":"X","conversation_ids":["c4","c5"]}' \
    | "$SCRIPTS_DIR/cluster-questions.sh" "$WORKDIR/conversations.jsonl" \
    > "$WORKDIR/out.json"
  [ "$(jq -r '.unique_customers' "$WORKDIR/out.json")" = "1" ]
}

@test "ignores blank-contact-and-blank-email rows (does not collapse to 1)" {
  echo '{"topic":"X","conversation_ids":["c6","c6"]}' \
    | "$SCRIPTS_DIR/cluster-questions.sh" "$WORKDIR/conversations.jsonl" \
    > "$WORKDIR/out.json"
  [ "$(jq -r '.unique_customers' "$WORKDIR/out.json")" = "0" ]
}

@test "preserves conversation_ids and topic in output" {
  echo '{"topic":"FLAC export","conversation_ids":["c1","c2","c3"]}' \
    | "$SCRIPTS_DIR/cluster-questions.sh" "$WORKDIR/conversations.jsonl" \
    > "$WORKDIR/out.json"
  [ "$(jq -r '.topic' "$WORKDIR/out.json")" = "FLAC export" ]
  [ "$(jq -r '.conversation_ids | length' "$WORKDIR/out.json")" = "3" ]
}
