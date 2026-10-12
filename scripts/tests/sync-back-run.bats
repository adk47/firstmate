#!/usr/bin/env bats
# scripts/sync-back-run.sh: the scheduled node-8 -> git sync-back runner (MUS-5104, W2b-2b).
# Hermetic: the runner and sync-from-server.sh are COPIED into a synthetic clone of a
# bare origin under mktemp; rsync is a PATH-shadowed copy-from-$SERVER stub that records
# its argv, `gh` is a recording stub, and `ssh` refuses (the runner is local-source only).
# git is real, pushing to the local bare origin. Nothing references /opt/hydra.
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"

setup() {
  T="$(mktemp -d)"; export T
  ORIGIN="$T/origin.git"; REPO="$T/repo"; SERVER="$T/server"; export ORIGIN REPO SERVER
  RSYNC_CALLS="$T/rsync.calls"; GH_CALLS="$T/gh.calls"; export RSYNC_CALLS GH_CALLS
  : > "$RSYNC_CALLS"; : > "$GH_CALLS"
  mkdir -p "$T/bin" "$SERVER"

  # Paperclip shims `git` on PATH and that breaks synthetic repos: pin the real one.
  real_git="$(PATH=/usr/bin:/usr/local/bin:/opt/homebrew/bin command -v git)"
  printf '#!/bin/bash\nexec %q "$@"\n' "$real_git" > "$T/bin/git"

  cat > "$T/bin/rsync" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$RSYNC_CALLS"
dry=0; from=""; pos=(); skip=0
for a in "$@"; do
  if (( skip )); then skip=0; continue; fi
  case "$a" in
    -e) skip=1 ;;
    -n) dry=1 ;;
    --files-from=*) from="${a#*=}" ;;
    -*) ;;
    *) pos+=("$a") ;;
  esac
done
src="${pos[$((${#pos[@]}-2))]#*:}"; dst="${pos[$((${#pos[@]}-1))]}"
root="${src%/}"
while IFS= read -r -d '' p; do
  if [[ -f "$root/$p" ]]; then
    echo ">f.st...... $p"
    (( dry )) || { mkdir -p "$dst/$(dirname "$p")"; cp "$root/$p" "$dst/$p"; }
  else
    echo "rsync: [sender] link_stat \"$root/$p\" failed: No such file or directory (2)" >&2
    miss=1
  fi
done < "$from"
if [[ -n "${miss:-}" ]]; then
  echo 'rsync error: some files/attrs were not transferred (see previous errors) (code 23) at main.c(1338) [sender=3.2.7]' >&2
  exit 23
fi
STUB

  # gh: records argv. `pr list --json` emits the open PRs as JSON: one head branch from
# $T/open_pr, plus an unrelated feature PR always open (the runner's jq must ignore it).
  cat > "$T/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_CALLS"
case "$1 $2" in
  "pr list")
    # NOISE unrelated PRs (default 1) sit above the sync PR, as on a busy repo; honour --limit
    # (gh's default page is 30) so a missing --limit makes the sync PR invisible.
    lim=30; prev=""
    for a in "$@"; do [[ "$prev" == "--limit" ]] && lim="$a"; prev="$a"; done
    { for ((i=0; i<$(cat "$T/noise" 2>/dev/null || echo 1); i++)); do echo "feat/unrelated-$i"; done
      [[ -s "$T/open_pr" ]] && cat "$T/open_pr"; } \
      | jq -R '{headRefName: .}' | jq -s --argjson l "$lim" '.[:$l]'
    exit 0 ;;
  "pr create") echo "https://github.com/Muso-AI/hydra/pull/9999"; exit 0 ;;
esac
exit 0
STUB
  printf '#!/bin/bash\necho "stub ssh refused" >&2; exit 99\n' > "$T/bin/ssh"
  chmod +x "$T/bin/"*
  PATH="$T/bin:$PATH"; export PATH
  : > "$T/open_pr"

  export DEPLOY_PATH="$SERVER" SSH_KEY=/dev/null

  git init -q --bare -b main "$ORIGIN"
  git clone -q "$ORIGIN" "$REPO" 2>/dev/null
  git -C "$REPO" config user.email t@t; git -C "$REPO" config user.name t
  git -C "$REPO" checkout -q -b main
  mkdir -p "$REPO/scripts"
  cp "$HYDRA_REPO/scripts/sync-from-server.sh" "$REPO/scripts/"
  [[ -f "$HYDRA_REPO/scripts/sync-back-run.sh" ]] && cp "$HYDRA_REPO/scripts/sync-back-run.sh" "$REPO/scripts/"
  printf 'audit/\n' > "$REPO/.gitignore"
  plant "$REPO" skills-all/a/SKILL.md "repo"
  plant "$REPO" workspaces/ceo/TOOLS.md "repo"
  plant "$SERVER" skills-all/a/SKILL.md "repo"
  plant "$SERVER" workspaces/ceo/TOOLS.md "repo"
  git -C "$REPO" add -A && git -C "$REPO" commit -qm base
  git -C "$REPO" push -q origin main 2>/dev/null
  RUN="$REPO/scripts/sync-back-run.sh"; export RUN
}

teardown() { rm -rf "$T"; }

plant() { mkdir -p "$1/$(dirname "$2")"; printf '%s\n' "$3" > "$1/$2"; }
origin_branches() { git -C "$ORIGIN" for-each-ref --format='%(refname:short)' refs/heads; }
# bats does not fail a test on a mid-test `! cmd`; this does.
refute() { if "$@"; then echo "unexpected success: $*" >&2; return 1; fi; }
create_calls() { grep -c '^pr create' "$GH_CALLS" || true; }

@test "AC1 empty run: exit 0, no branch, no commit, no PR, says why" {
  before="$(git -C "$ORIGIN" rev-parse main)"
  run "$RUN" --date 2026-10-13
  [ "$status" -eq 0 ]
  [[ "$output" == *"no drift"* ]]
  [ "$(origin_branches)" = "main" ]
  [ "$(git -C "$ORIGIN" rev-parse main)" = "$before" ]
  [ "$(create_calls)" = 0 ]
  [ -z "$(git -C "$REPO" branch --list 'sync/*')" ]
}

@test "AC2 drift: one commit on sync/node-8-<date>, exactly one PR create" {
  plant "$SERVER" workspaces/ceo/TOOLS.md "edited on node-8"
  run "$RUN" --date 2026-10-13
  [ "$status" -eq 0 ]
  [[ "$(origin_branches)" == *"sync/node-8-2026-10-13"* ]]
  [ "$(git -C "$ORIGIN" rev-list --count main..sync/node-8-2026-10-13)" = 1 ]
  [ "$(git -C "$ORIGIN" show sync/node-8-2026-10-13:workspaces/ceo/TOOLS.md)" = "edited on node-8" ]
  [ "$(create_calls)" = 1 ]
  grep -qE '^pr create .*--base main' "$GH_CALLS"
  grep -qE '^pr create .*--head sync/node-8-2026-10-13' "$GH_CALLS"
  grep -qE '^pr create .*--title chore\(sync\): ' "$GH_CALLS"
  grep -q 'do not push to it; comment on the PR instead' "$GH_CALLS"
}

@test "AC3 second run while yesterday's PR is open replaces that branch and opens no second PR" {
  plant "$SERVER" workspaces/ceo/TOOLS.md "day one"
  run "$RUN" --date 2026-10-13
  [ "$status" -eq 0 ]
  first="$(git -C "$ORIGIN" rev-parse sync/node-8-2026-10-13)"
  echo "sync/node-8-2026-10-13" > "$T/open_pr"
  : > "$GH_CALLS"
  plant "$SERVER" workspaces/ceo/TOOLS.md "day two"
  plant "$SERVER" skills-all/a/SKILL.md "also day two"
  run "$RUN" --date 2026-10-14
  [ "$status" -eq 0 ]
  # no second branch, no second PR
  [ "$(origin_branches | grep -c '^sync/')" = 1 ]
  [ "$(create_calls)" = 0 ]
  # the SAME branch moved: still one commit ahead of main, new sha, carries both days' content
  second="$(git -C "$ORIGIN" rev-parse sync/node-8-2026-10-13)"
  [ "$first" != "$second" ]
  [ "$(git -C "$ORIGIN" rev-list --count main..sync/node-8-2026-10-13)" = 1 ]
  [ "$(git -C "$ORIGIN" show sync/node-8-2026-10-13:workspaces/ceo/TOOLS.md)" = "day two" ]
  [ "$(git -C "$ORIGIN" show sync/node-8-2026-10-13:skills-all/a/SKILL.md)" = "also day two" ]
}

@test "AC3b open PR but server now matches main: leaves the branch alone, says so" {
  plant "$SERVER" workspaces/ceo/TOOLS.md "day one"
  "$RUN" --date 2026-10-13 >/dev/null
  first="$(git -C "$ORIGIN" rev-parse sync/node-8-2026-10-13)"
  echo "sync/node-8-2026-10-13" > "$T/open_pr"
  plant "$SERVER" workspaces/ceo/TOOLS.md "repo"
  run "$RUN" --date 2026-10-14
  [ "$status" -eq 0 ]
  [[ "$output" == *"no drift"* ]]
  [ "$(git -C "$ORIGIN" rev-parse sync/node-8-2026-10-13)" = "$first" ]
}

@test "AC4 never auto-merges: no gh argv contains merge, and the script has no gh pr merge" {
  plant "$SERVER" workspaces/ceo/TOOLS.md "edited"
  "$RUN" --date 2026-10-13 >/dev/null
  echo "sync/node-8-2026-10-13" > "$T/open_pr"
  plant "$SERVER" workspaces/ceo/TOOLS.md "edited again"
  "$RUN" --date 2026-10-14 >/dev/null
  [ -s "$GH_CALLS" ]
  refute grep -qw merge "$GH_CALLS"
  refute grep -nE 'gh[[:space:]]+pr[[:space:]]+merge|--auto' "$HYDRA_REPO/scripts/sync-back-run.sh"
}

@test "AC5 refuses a dirty tree via sync-from-server's guard: no branch, no PR" {
  plant "$SERVER" workspaces/ceo/TOOLS.md "edited"
  echo local-edit >> "$REPO/skills-all/a/SKILL.md"
  run "$RUN" --date 2026-10-13
  [ "$status" -ne 0 ]
  [ "$(origin_branches)" = "main" ]
  [ "$(create_calls)" = 0 ]
  # the runner adds no second guard and no --allow-dirty
  refute grep -q -- '--allow-dirty' "$HYDRA_REPO/scripts/sync-back-run.sh"
}

@test "AC6 runner targets 'all' only and rejects any argument that names a target" {
  plant "$SERVER" workspaces/ceo/TOOLS.md "edited"
  "$RUN" --date 2026-10-13 >/dev/null
  [ -s "$RSYNC_CALLS" ]
  refute grep -q 'audit' "$RSYNC_CALLS"
  grep -q -- '--files-from' "$RSYNC_CALLS"
  : > "$RSYNC_CALLS"
  run "$RUN" audit
  [ "$status" -ne 0 ]
  [ ! -s "$RSYNC_CALLS" ]
  grep -qE 'sync-from-server\.sh"? all --apply' "$HYDRA_REPO/scripts/sync-back-run.sh"
  refute grep -qE 'sync-from-server\.sh"? audit' "$HYDRA_REPO/scripts/sync-back-run.sh"
}

@test "AC7 --from-local: rsync argv has no -e ssh and a plain local source; remote mode keeps -e ssh" {
  plant "$SERVER" workspaces/ceo/TOOLS.md "edited"
  run "$REPO/scripts/sync-from-server.sh" workspaces --from-local
  [ "$status" -eq 0 ]
  [ -s "$RSYNC_CALLS" ]
  refute grep -qE -- '(^| )-e ' "$RSYNC_CALLS"
  refute grep -q 'ssh' "$RSYNC_CALLS"
  grep -q "$SERVER/ " "$RSYNC_CALLS"
  refute grep -qE '@' "$RSYNC_CALLS"
  : > "$RSYNC_CALLS"
  NODE8_IP=127.0.0.1 NODE8_USER=root run "$REPO/scripts/sync-from-server.sh" workspaces
  [ "$status" -eq 0 ]
  grep -qE -- '-e ssh -i ' "$RSYNC_CALLS"
  grep -q "root@127.0.0.1:$SERVER/" "$RSYNC_CALLS"
}

@test "AC7b the runner passes --from-local and never writes into DEPLOY_PATH" {
  plant "$SERVER" workspaces/ceo/TOOLS.md "edited"
  find "$SERVER" -type f -exec cksum {} + | sort > "$T/server.before"
  "$RUN" --date 2026-10-13 >/dev/null
  grep -qE -- '--from-local' "$HYDRA_REPO/scripts/sync-back-run.sh"
  refute grep -qE -- '(^| )-e ' "$RSYNC_CALLS"
  find "$SERVER" -type f -exec cksum {} + | sort > "$T/server.after"
  diff "$T/server.before" "$T/server.after"
}

@test "AC11 sync PR buried under 40 newer open PRs is still found: amend, no second PR" {
  plant "$SERVER" workspaces/ceo/TOOLS.md "day one"
  "$RUN" --date 2026-10-13 >/dev/null
  echo "sync/node-8-2026-10-13" > "$T/open_pr"; echo 40 > "$T/noise"
  : > "$GH_CALLS"
  plant "$SERVER" workspaces/ceo/TOOLS.md "day two"
  run "$RUN" --date 2026-10-14
  [ "$status" -eq 0 ]
  [ "$(create_calls)" = 0 ]
  grep -q -- '--limit' <(grep '^pr list' "$GH_CALLS")
  [ "$(origin_branches | grep -c '^sync/')" = 1 ]
  [ "$(git -C "$ORIGIN" show sync/node-8-2026-10-13:workspaces/ceo/TOOLS.md)" = "day two" ]
}

@test "AC12 two open sync PRs: fails loud naming both, pushes and creates nothing" {
  plant "$SERVER" workspaces/ceo/TOOLS.md "edited"
  printf 'sync/node-8-2026-10-11\nsync/node-8-2026-10-12\n' > "$T/open_pr"
  run "$RUN" --date 2026-10-13
  [ "$status" -ne 0 ]
  [[ "$output" == *"sync/node-8-2026-10-11"* && "$output" == *"sync/node-8-2026-10-12"* ]]
  [ "$(origin_branches)" = "main" ]
  [ "$(create_calls)" = 0 ]
}
