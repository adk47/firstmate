#!/usr/bin/env bats
# Red test for the gateway profile-parity gate (MUS-2681). Fixture trees only: the real
# repo files are never mutated. REPO_ROOT points the gate at the fixture.

SCRIPT="${BATS_TEST_DIRNAME}/../check-gateway-profile-parity.sh"

# mk_tree <dir> <drop-site>: writes a minimal main/edge/qa tree where every list holds
# all three profiles, except the one site named by <drop-site> (qa omitted there only).
# Sites: parser validate deploy_loops aux_loops codex wd_loop matrix peers workflow;
# "all" drops qa from every site.
FULL="main edge qa"
BASE="main edge"

# words <site> <drop>: the profile list for a site
words() { if [ "$1" = "$2" ] || [ "$2" = all ]; then echo "$BASE"; else echo "$FULL"; fi; }

mk_tree() {
  local d="$1" drop="${2:-}" w p
  mkdir -p "$d/scripts" "$d/.github/workflows"
  for p in $FULL; do : > "$d/openclaw-$p.json"; done
  w=$(words parser "$drop"); echo "    ${w// /|}|all) TARGET=\"\$1\"; shift ;;" > "$d/scripts/deploy.sh"
  w=$(words validate "$drop"); echo "    ${w// /|}|all) ;;" >> "$d/scripts/deploy.sh"
  w=$(words deploy_loops "$drop"); echo "  for profile in $w dev; do" >> "$d/scripts/deploy.sh"
  w=$(words aux_loops "$drop"); : > "$d/scripts/install-aux-units.sh"
  for _ in 1 2 3 4; do echo "for profile in $w; do" >> "$d/scripts/install-aux-units.sh"; done
  echo "CODEX_KEEPALIVE_PROFILES=\"$(words codex "$drop")\" codex-keepalive.sh" >> "$d/scripts/install-aux-units.sh"
  echo "for profile in $(words wd_loop "$drop"); do" > "$d/scripts/openclaw-watchdog.sh"
  echo "  PROFILES=($(for p in $(words matrix "$drop"); do printf 'openclaw-%s.json ' "$p"; done))" > "$d/scripts/validate-config-matrix.sh"
  { echo 'case "$PROFILE" in'; for p in $(words peers "$drop"); do echo "  $p)"; echo "    ;;"; done; echo 'esac'; } > "$d/scripts/provision-peer-labels.sh"
  echo "        options: [all, $(words workflow "$drop" | sed 's/ /, /g')]" > "$d/.github/workflows/deploy.yml"
}

setup() {
  T="$(mktemp -d)"
  export REPO_ROOT="$T"
}
teardown() { rm -rf "$T"; }

@test "(a) today's tree (main, edge) passes" {
  REPO_ROOT="${BATS_TEST_DIRNAME}/../.." run bash "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "(b) third profile with untouched lists fails, naming deploy.sh parser and watchdog" {
  mk_tree "$T" all
  run bash "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"scripts/deploy.sh"*"qa"*"--target"* ]]
  [[ "$output" == *"scripts/openclaw-watchdog.sh"* ]]
}

@test "(c) third profile present in every list passes" {
  mk_tree "$T"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
}

# Regression guard: the gate claims enumeration parity only. Restoring the broad claim
# (gateway profile parity OK) would imply deploy.sh behaviour the text cannot decide.
@test "success output names the narrow claim exactly" {
  mk_tree "$T"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$output" = "profile enumeration parity OK (edge main qa)" ]
}

# Bot 🔴 (b2258400f): profile names contain hyphens, so `grep -w qa` accepted `qa-alt`.
@test "a list naming only qa-alt does not satisfy profile qa at any list site" {
  local f
  for f in scripts/deploy.sh scripts/install-aux-units.sh scripts/openclaw-watchdog.sh \
    scripts/validate-config-matrix.sh .github/workflows/deploy.yml; do
    rm -rf "$T"; T="$(mktemp -d)"
    mk_tree "$T"
    sed -i.bak -E 's/(^|[^[:alnum:]_-]|openclaw-)qa([^[:alnum:]_-]|$)/\1qa-alt\2/g' "$T/$f"
    REPO_ROOT="$T" run bash "$SCRIPT"
    [ "$status" -ne 0 ] || { echo "$f: gate passed on qa-alt"; return 1; }
    [[ "$output" == *"$f: profile 'qa'"* ]] || { echo "$f: $output"; return 1; }
  done
}

# Bot 🔴 (b0572925): the profile name elsewhere on a list line (`do echo qa; done`) is not a
# list member. Only the enumeration itself may satisfy the check.
@test "qa named outside the list on the same line does not satisfy any list site" {
  local f
  for f in scripts/deploy.sh scripts/install-aux-units.sh scripts/openclaw-watchdog.sh \
    scripts/validate-config-matrix.sh .github/workflows/deploy.yml; do
    rm -rf "$T"; T="$(mktemp -d)"
    mk_tree "$T" all
    sed -i.bak 's/$/ echo qa/' "$T/$f"
    REPO_ROOT="$T" run bash "$SCRIPT"
    [ "$status" -ne 0 ] || { echo "$f: gate passed on qa outside the list"; return 1; }
    [[ "$output" == *"$f: profile 'qa'"* ]] || { echo "$f: $output"; return 1; }
  done
}

@test "a shell expansion named qa is not a literal list member" {
  local f
  for f in scripts/deploy.sh scripts/install-aux-units.sh scripts/openclaw-watchdog.sh \
    scripts/validate-config-matrix.sh .github/workflows/deploy.yml; do
    rm -rf "$T"; T="$(mktemp -d)"
    mk_tree "$T" all
    sed -i.bak -E 's/(for profile in main edge|PROFILES=\(openclaw-main.json openclaw-edge.json|options: \[all, main, edge|CODEX_KEEPALIVE_PROFILES="main edge)/\1 ${qa:-}/' "$T/$f"
    cmp -s "$T/$f" "$T/$f.bak" && { echo "$f: fixture edit was a no-op"; return 1; }
    echo '{}' > "$T/openclaw-qa.json"
    REPO_ROOT="$T" run bash "$SCRIPT"
    [ "$status" -ne 0 ] || { echo "$f: gate passed on \${qa:-}"; return 1; }
    [[ "$output" == *"$f: profile 'qa'"* ]] || { echo "$f: $output"; return 1; }
  done
}

@test "a quoted group is one member, not separate profiles" {
  local f q
  for q in "'" '"'; do
    for f in scripts/deploy.sh scripts/install-aux-units.sh scripts/openclaw-watchdog.sh \
      scripts/validate-config-matrix.sh .github/workflows/deploy.yml; do
      rm -rf "$T"; T="$(mktemp -d)"
      mk_tree "$T" all
      sed -i.bak -E -e "s/(for profile in main |options: \[all, main, |CODEX_KEEPALIVE_PROFILES=\"main )edge/\1${q}edge qa${q}/" \
        -e "s/(PROFILES=\(openclaw-main.json )openclaw-edge.json/\1${q}openclaw-edge.json openclaw-qa.json${q}/" "$T/$f"
      cmp -s "$T/$f" "$T/$f.bak" && { echo "$f: fixture edit was a no-op"; return 1; }
      echo '{}' > "$T/openclaw-qa.json"
      REPO_ROOT="$T" run bash "$SCRIPT"
      [ "$status" -ne 0 ] || { echo "$f: gate passed on a ${q}-quoted group"; return 1; }
      [[ "$output" == *"$f: profile 'qa'"* ]] || { echo "$f ($q): $output"; return 1; }
    done
  done
}

# Bot 🟡 (28538687a, :57): each site accepts ONE name form. A config filename in a bare-name
# list (the deploy loop would build /root/.openclaw-openclaw-qa.json) is not the profile, and a
# bare name in the config matrix is not a config file.
@test "the wrong name form does not satisfy a site" {
  local f
  for f in scripts/deploy.sh scripts/install-aux-units.sh scripts/openclaw-watchdog.sh \
    .github/workflows/deploy.yml; do
    rm -rf "$T"; T="$(mktemp -d)"
    mk_tree "$T" all
    sed -i.bak -E -e 's/(for profile in main edge|options: \[all, main, edge|CODEX_KEEPALIVE_PROFILES="main edge)/\1 openclaw-qa.json/' \
      -e 's/main\|edge\|/main|edge|openclaw-qa.json|/' "$T/$f"
    cmp -s "$T/$f" "$T/$f.bak" && { echo "$f: fixture edit was a no-op"; return 1; }
    REPO_ROOT="$T" run bash "$SCRIPT"
    [ "$status" -ne 0 ] || { echo "$f: gate passed on openclaw-qa.json in a bare-name list"; return 1; }
    [[ "$output" == *"$f: profile 'qa'"* ]] || { echo "$f: $output"; return 1; }
  done
}
@test "a bare name in the config matrix does not satisfy it" {
  mk_tree "$T" all
  sed -i.bak -E 's/PROFILES=\(openclaw-main.json openclaw-edge.json/& qa/' "$T/scripts/validate-config-matrix.sh"
  cmp -s "$T/scripts/validate-config-matrix.sh" "$T/scripts/validate-config-matrix.sh.bak" && { echo "no-op"; return 1; }
  run bash "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"scripts/validate-config-matrix.sh: profile 'qa'"* ]]
}

# Bot 🟡 (28538687a, :106): only the arms of `case "$PROFILE"` count. A `qa)` arm in another
# case, before, after or nested inside an arm, is not a profile arm.
@test "a qa arm outside the PROFILE case block does not satisfy provision-peer-labels" {
  local where
  for where in before after nested; do
    rm -rf "$T"; T="$(mktemp -d)"
    mk_tree "$T" peers
    f="$T/scripts/provision-peer-labels.sh"
    case "$where" in
      before) printf 'case "$KIND" in\n  qa)\n    ;;\nesac\n%s\n' "$(cat "$f")" > "$f" ;;
      after) printf 'case "$KIND" in\n  qa)\n    ;;\nesac\n' >> "$f" ;;
      nested) sed -i.bak -E 's/^  edge\)$/  edge)\n    case "$X" in\n      qa)\n        ;;\n    esac/' "$f" ;;
    esac
    REPO_ROOT="$T" run bash "$SCRIPT"
    [ "$status" -ne 0 ] || { echo "$where: gate passed on a decoy qa arm"; return 1; }
    [[ "$output" == *"scripts/provision-peer-labels.sh: profile 'qa'"* ]] || { echo "$where: $output"; return 1; }
  done
}
@test "a qa arm inside the PROFILE case block still satisfies provision-peer-labels" {
  mk_tree "$T"
  printf 'echo pre\n%s\n' "$(cat "$T/scripts/provision-peer-labels.sh")" > "$T/scripts/provision-peer-labels.sh"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "(d) openclaw-server-backup-*.json is not a profile" {
  mk_tree "$T"
  : > "$T/openclaw-server-backup-20260406.json"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "a missing list file fails loud rather than passing vacuously" {
  mk_tree "$T"
  rm "$T/scripts/provision-peer-labels.sh"
  run bash "$SCRIPT"
  [ "$status" -ne 0 ]
}

# One test per site: qa is dropped from exactly that site, every other list is complete,
# so a pass here can only come from that one rule. Asserts the site's file and reason.
one_site() { # <site> <file> <reason>
  mk_tree "$T" "$1"
  run bash "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"$2: profile 'qa'"*"$3"* ]]
}
@test "site parser: dropping qa only there fails on scripts/deploy.sh" { one_site parser scripts/deploy.sh "--target arg parser"; }
@test "site validate: dropping qa only there fails on scripts/deploy.sh" { one_site validate scripts/deploy.sh "target-value validation"; }
@test "site deploy_loops: dropping qa only there fails on scripts/deploy.sh" { one_site deploy_loops scripts/deploy.sh "Step 4c"; }
@test "site aux_loops: dropping qa only there fails on scripts/install-aux-units.sh" { one_site aux_loops scripts/install-aux-units.sh "aux units"; }
@test "site codex: dropping qa only there fails on scripts/install-aux-units.sh" { one_site codex scripts/install-aux-units.sh "Codex auth"; }
@test "site wd_loop: dropping qa only there fails on scripts/openclaw-watchdog.sh" { one_site wd_loop scripts/openclaw-watchdog.sh "config-validates"; }
@test "site matrix: dropping qa only there fails on scripts/validate-config-matrix.sh" { one_site matrix scripts/validate-config-matrix.sh "validation matrix"; }
@test "site peers: dropping qa only there fails on scripts/provision-peer-labels.sh" { one_site peers scripts/provision-peer-labels.sh "peer labels"; }
@test "site workflow: dropping qa only there fails on .github/workflows/deploy.yml" { one_site workflow .github/workflows/deploy.yml "deploy workflow"; }

# A commented-out wiring line is not wiring (any_line and each_line both skip comments).
@test "commenting out a live list line (full-line or trailing) fails though the profile text remains" {
  local f pre
  for pre in '# ' ': # '; do
    for f in scripts/openclaw-watchdog.sh scripts/provision-peer-labels.sh \
      scripts/install-aux-units.sh scripts/validate-config-matrix.sh .github/workflows/deploy.yml; do
      rm -rf "$T"; T="$(mktemp -d)"
      mk_tree "$T"
      sed -i.bak -E "s/^/$pre/" "$T/$f"
      REPO_ROOT="$T" run bash "$SCRIPT"
      [ "$status" -ne 0 ] || { echo "$f ($pre): gate passed"; return 1; }
      [[ "$output" == *"$f: profile 'qa'"* ]] || { echo "$f: $output"; return 1; }
    done
  done
}
