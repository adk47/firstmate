#!/usr/bin/env bats
# MUS-20329: GHL calls must not carry a committed token or urllib's default
# User-Agent (Cloudflare answers Python-urllib with 403 error 1010).

setup() { REPO="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; }

@test "no full GHL private-integration token is committed" {
  run git -C "$REPO" grep -nE 'pit-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' -- .
  [ "$status" -eq 1 ] || { echo "$output" | sed -E 's/pit-[0-9a-f-]{36}/pit-<redacted>/g'; false; }
}

@test "every python file that calls leadconnectorhq sets a User-Agent" {
  missing=""
  while IFS= read -r f; do
    grep -q 'User-Agent' "$REPO/$f" || missing="$missing $f"
  done < <(git -C "$REPO" grep -l 'leadconnectorhq' -- '*.py')
  [ -z "$missing" ] || { echo "no User-Agent in:$missing"; false; }
}

@test "winback entrypoints refuse to run without GHL_WINBACK_API_KEY, before any side effect" {
  d="$REPO/skills-all/muso-winback-pro/scripts"
  for s in winback_engine reply_scanner sanity_check; do
    run env -u GHL_WINBACK_API_KEY python3 -I "$d/$s.py"
    [ "$status" -ne 0 ] || { echo "$s exited 0 without the key"; false; }
    [[ "$output" == *"GHL_WINBACK_API_KEY is not set"* ]] || { echo "$s: $output"; false; }
    [[ "$output" != *"Step 1"* && "$output" != *"Reply Scanner -"* ]] || { echo "$s ran past the guard"; false; }
  done
}
