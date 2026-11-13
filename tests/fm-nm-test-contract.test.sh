#!/usr/bin/env bash
# Contract: parsed .no-mistakes.yaml must leave commands.test absent or empty.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

NM="$ROOT/.no-mistakes.yaml"

test_nm_has_no_deterministic_test_command() {
  # The contract is read through Ruby's YAML, so a host without ruby has nothing
  # to assert. Skip visibly rather than failing a host that lacks the tool.
  if ! command -v ruby >/dev/null 2>&1; then
    pass "ruby is required to parse .no-mistakes.yaml for this contract; skipping on a host without ruby"
    return 0
  fi
  local val
  val=$(ruby -ryaml -e '
doc = YAML.load_file(ARGV[0]) || {}
cmds = doc["commands"] || {}
val = cmds.is_a?(Hash) ? cmds["test"] : nil
puts (val.nil? || val == false || val == "") ? "" : val.inspect
' "$NM") || fail "failed to parse .no-mistakes.yaml as YAML"
  if [ -n "$val" ]; then
    fail "commands.test must be absent or empty so Test stays intent-targeted; got: $val"
  fi
  pass "no-mistakes does not configure commands.test"
}

test_nm_has_no_deterministic_test_command
