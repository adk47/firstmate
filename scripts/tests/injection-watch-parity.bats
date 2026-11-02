#!/usr/bin/env bats
# The prompt-injection watch has two copies of one rule set: plugins/intercom/src/injection-watch.ts (Caroline's
# Intercom inbound) and scripts/lib/injection_watch.py (support@ email + uploaded-proof text extracts). They must not
# drift: an attack the Intercom side flags must be flagged in a document too (caroline-guard-g1).
bats_require_minimum_version 1.5.0

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  TS="$ROOT/plugins/intercom/src/injection-watch.ts"
}

ts_dump() {
  node --experimental-strip-types --no-warnings -e "
    import('$TS').then((m) => console.log(JSON.stringify({
      version: m.INJECTION_WATCH_VERSION, ledger: m.INJECTION_LEDGER_PATH, zw: m.ZERO_WIDTH_MIN,
      rules: m.INJECTION_RULES.map((r) => ({ rule: r.rule, severity: r.severity, source: r.source, flags: r.flags })),
    })));"
}

py_dump() {
  python3 -c "
import json, sys; sys.path.insert(0, '$ROOT/scripts')
from lib import injection_watch as w
print(json.dumps({'version': w.VERSION, 'ledger': str(w.LEDGER_PATH), 'zw': w.ZERO_WIDTH_MIN, 'rules': w.dump_rules()}))"
}

@test "the TypeScript and Python rule tables are identical (names, severities, sources, flags, order)" {
  run ts_dump; [ "$status" -eq 0 ]; ts="$output"
  run py_dump; [ "$status" -eq 0 ]; py="$output"
  run python3 -c "
import json, sys
a, b = json.loads(sys.argv[1]), json.loads(sys.argv[2])
for k in ('version', 'ledger', 'zw'):
    assert a[k] == b[k], (k, a[k], b[k])
assert [r['rule'] for r in a['rules']] == [r['rule'] for r in b['rules']], 'rule order'
for x, y in zip(a['rules'], b['rules']):
    assert x == y, ('DRIFT', x['rule'], x['source'][:120], y['source'][:120])
print(len(a['rules']), 'rules identical')" "$ts" "$py"
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "the Python side flags every corpus attack the TypeScript side expects" {
  run python3 -c "
import json, sys; sys.path.insert(0, '$ROOT/scripts')
from lib import injection_watch as w
cases = json.load(open('$ROOT/plugins/intercom/redteam/caroline-redteam-cases.json'))['cases']
bad = []
for c in cases:
    got = {h['rule'] for h in w.scan(c['customer'])}
    miss = [r for r in c['inbound_expect'] if r not in got]
    if miss: bad.append((c['id'], miss))
    if c.get('document_text') and not w.scan(c['document_text']): bad.append((c['id'], 'document'))
print(bad); sys.exit(1 if bad else 0)"
  [ "$status" -eq 0 ]
}

@test "CAN FAIL: a rule edited on one side only is caught" {
  cp "$ROOT/scripts/lib/injection_watch.py" "$BATS_TEST_TMPDIR/iw.py"
  sed -i.bak 's/jailbreak|maintenance|sudo|unrestricted)\\s+mode/jailbreak|sudo|unrestricted)\\s+mode/' "$BATS_TEST_TMPDIR/iw.py"
  run cmp -s "$ROOT/scripts/lib/injection_watch.py" "$BATS_TEST_TMPDIR/iw.py"
  [ "$status" -ne 0 ]   # the edit really landed
  run python3 -c "
import importlib.util, json, sys
spec = importlib.util.spec_from_file_location('iw', '$BATS_TEST_TMPDIR/iw.py'); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
ts = json.loads(sys.argv[1])['rules']
sys.exit(0 if ts == m.dump_rules() else 1)" "$(ts_dump)"
  [ "$status" -eq 1 ]
}
