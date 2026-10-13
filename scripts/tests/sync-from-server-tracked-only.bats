#!/usr/bin/env bats
# sync-from-server.sh pulls ONLY paths git already tracks (MUS-5103, W2b-2a).
# The rule under test: sync-back may never put a committable path into the repo
# and may never delete one. Hermetic: the script is COPIED into a synthetic git
# repo under mktemp so `git ls-files` sees only these fixtures, and rsync/ssh
# are PATH-shadowed. rsync is a faithful-enough stub of a server at $SERVER:
# --files-from copies exactly the listed paths (exit 23 + link_stat lines for
# absent ones); a plain `host:dir/` source copies the whole subtree, as the old
# code did. Nothing references /opt/hydra.
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"

setup() {
  T="$(mktemp -d)"; export T
  REPO="$T/repo"; SERVER="$T/server"; export REPO SERVER
  RSYNC_CALLS="$T/rsync.calls"; : > "$RSYNC_CALLS"; export RSYNC_CALLS
  mkdir -p "$T/bin" "$REPO/scripts" "$SERVER"

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
cp_one() { # rel
  if [[ -f "$SERVER_ROOT/$1" ]]; then
    echo ">f.st...... $1"
    (( dry )) || { mkdir -p "$dst/$(dirname "$1")"; cp "$SERVER_ROOT/$1" "$dst/$1"; }
    return 0
  fi
  echo "rsync: [sender] link_stat \"$SERVER_ROOT/$1\" failed: No such file or directory (2)" >&2
  miss=1
}
miss=0
if [[ -n "$from" ]]; then
  SERVER_ROOT="${src%/}"
  while IFS= read -r -d '' p; do cp_one "$p"; done < "$from"
  cp "$from" "$T/last.pullset"
elif [[ "$src" == *"/./"* ]]; then
  SERVER_ROOT="${src%%/./*}"; cp_one "${src#*/./}"
else  # legacy whole-subtree pull
  SERVER_ROOT="$SERVER"; dst="$REPO"; sub="${src#"$SERVER"/}"
  while IFS= read -r f; do cp_one "$f"; done < <(cd "$SERVER" && find "${sub%/}" -type f)
fi
if (( miss )); then
  [[ -n "${STUB_EXTRA_ERR:-}" ]] && echo "$STUB_EXTRA_ERR" >&2
  echo 'rsync error: some files/attrs were not transferred (see previous errors) (code 23) at main.c(1338) [sender=3.2.7]' >&2
  exit 23
fi
[[ -n "${STUB_EXTRA_ERR:-}" ]] && { echo "$STUB_EXTRA_ERR" >&2; exit 23; }
exit 0
STUB
  printf '#!/bin/bash\necho "stub ssh refused" >&2; exit 99\n' > "$T/bin/ssh"
  chmod +x "$T/bin/"*
  PATH="$T/bin:$PATH"; export PATH

  export SSH_KEY=/dev/null NODE8_IP=127.0.0.1 NODE8_USER=root DEPLOY_PATH="$SERVER"

  cp "$HYDRA_REPO/scripts/sync-from-server.sh" "$REPO/scripts/"
  SCRIPT="$REPO/scripts/sync-from-server.sh"; export SCRIPT
  git -C "$REPO" init -q
  git -C "$REPO" config user.email t@t; git -C "$REPO" config user.name t
  printf 'audit/\n' > "$REPO/.gitignore"
}

teardown() { rm -rf "$T"; }

# plant <root> <relpath> <content>
plant() { mkdir -p "$1/$(dirname "$2")"; printf '%s\n' "$3" > "$1/$2"; }
track() { plant "$REPO" "$1" "${2:-repo}"; git -C "$REPO" add -f "$1"; }
commit() { git -C "$REPO" add .gitignore scripts; git -C "$REPO" commit -qm fixture; }
pullset() { tr '\0' '\n' < "$T/last.pullset"; }

@test "AC1 untracked server secret and never-pull tracked path are not in the pull set" {
  track skills-all/ok/SKILL.md
  track skills-all/ok/tests/t.sh
  track skills-all/ok/config/c.json
  track skills-all/muso-query-writer/saved-queries/audit/q.sql
  track skills-all/muso-ops-admin/config/tier2-approvers.txt
  commit
  for f in skills-all/ok/SKILL.md skills-all/ok/tests/t.sh skills-all/ok/config/c.json \
           skills-all/muso-query-writer/saved-queries/audit/q.sql skills-all/muso-ops-admin/config/tier2-approvers.txt; do
    plant "$SERVER" "$f" server
  done
  plant "$SERVER" skills-all/ok/.env "SECRET_UNTRACKED"
  plant "$SERVER" skills-all/ok/tests/leak.txt "SECRET_NEVERPULL"
  run "$SCRIPT" skills --apply
  [ "$status" -eq 0 ]
  [ "$(pullset)" = "skills-all/ok/SKILL.md" ]
  [ ! -e "$REPO/skills-all/ok/.env" ]
  [ ! -e "$REPO/skills-all/ok/tests/leak.txt" ]
  grep -q '^server$' "$REPO/skills-all/ok/SKILL.md"
  # never-pull tracked files keep their git content
  grep -q '^repo$' "$REPO/skills-all/ok/tests/t.sh"
  grep -q '^repo$' "$REPO/skills-all/muso-ops-admin/config/tier2-approvers.txt"
}

@test "AC2 no --delete in argv and a repo-only file survives" {
  track skills-all/ok/SKILL.md
  track skills-all/repo-only/SKILL.md keepme
  commit
  plant "$SERVER" skills-all/ok/SKILL.md server
  run "$SCRIPT" skills --apply
  [ "$status" -eq 0 ]
  # `! cmd` mid-test is exempt from bats' errexit and can never fail: use if/false.
  if grep -q -- '--delete' "$RSYNC_CALLS"; then false; fi
  grep -q '^keepme$' "$REPO/skills-all/repo-only/SKILL.md"
  grep -q -- '--files-from=' "$RSYNC_CALLS"
}

@test "AC3 count assertion goes red when NEVER_PULL is truncated by one entry" {
  track skills-all/ok/SKILL.md; commit
  run "$SCRIPT" skills
  [ "$status" -eq 0 ]
  # drop one declared entry from the copy's own source
  : > "$RSYNC_CALLS"
  sed -i.bak "/^  'secrets\/'/d" "$SCRIPT"
  run "$SCRIPT" skills
  echo "$output"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q 'NEVER_PULL'
  [ ! -s "$RSYNC_CALLS" ]
}

@test "AC4 dry-run is the default" {
  track skills-all/ok/SKILL.md; commit
  plant "$SERVER" skills-all/ok/SKILL.md server
  run "$SCRIPT" skills
  [ "$status" -eq 0 ]
  grep -qE '(^| )-n( |$)' "$RSYNC_CALLS"
  grep -q '^repo$' "$REPO/skills-all/ok/SKILL.md"
}

@test "AC4 bulk --apply refuses a dirty tree; --allow-dirty overrides" {
  track skills-all/ok/SKILL.md; commit
  plant "$SERVER" skills-all/ok/SKILL.md server
  echo local-edit >> "$REPO/skills-all/ok/SKILL.md"
  run "$SCRIPT" skills --apply
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi 'dirty'
  [ ! -s "$RSYNC_CALLS" ]
  run "$SCRIPT" skills --apply --allow-dirty
  [ "$status" -eq 0 ]
  [ -s "$RSYNC_CALLS" ]
}

@test "AC4 --only --apply still works on a dirty tree" {
  track skills-all/ok/SKILL.md; track skills-all/other/SKILL.md; commit
  plant "$SERVER" skills-all/ok/SKILL.md server
  echo local-edit >> "$REPO/skills-all/other/SKILL.md"
  run "$SCRIPT" skills --apply --only skills-all/ok/SKILL.md
  [ "$status" -eq 0 ]
  grep -q '^server$' "$REPO/skills-all/ok/SKILL.md"
  grep -q local-edit "$REPO/skills-all/other/SKILL.md"
}

@test "--only refuses an untracked path, a tracked directory, and a glob" {
  track skills-all/ok/SKILL.md; commit
  plant "$SERVER" skills-all/ok/.env SECRET
  run "$SCRIPT" skills --only skills-all/ok/.env
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi 'not tracked'
  run "$SCRIPT" skills --only skills-all/ok
  [ "$status" -ne 0 ]
  run "$SCRIPT" skills --only 'skills-all/ok/*'
  [ "$status" -ne 0 ]
  [ ! -s "$RSYNC_CALLS" ]
}

@test "AC5 exit 23 with only missing-source errors passes and reports the skipped count" {
  track skills-all/ok/SKILL.md; track skills-all/gone/SKILL.md; track skills-all/gone2/SKILL.md; commit
  plant "$SERVER" skills-all/ok/SKILL.md server
  run "$SCRIPT" skills --apply
  echo "$output"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '2 path(s) absent on node-8'
  grep -q '^server$' "$REPO/skills-all/ok/SKILL.md"
  grep -q '^repo$' "$REPO/skills-all/gone/SKILL.md"
}

@test "AC5 exit 23 with any other stderr line fails" {
  track skills-all/ok/SKILL.md; track skills-all/gone/SKILL.md; commit
  plant "$SERVER" skills-all/ok/SKILL.md server
  STUB_EXTRA_ERR='rsync: [sender] send_files failed to open "x": Permission denied (13)' run "$SCRIPT" skills --apply
  [ "$status" -ne 0 ]
  echo "$output" | grep -q 'Permission denied'
}

@test "AC5 exit 23 with no stderr at all fails closed" {
  track skills-all/ok/SKILL.md; commit
  plant "$SERVER" skills-all/ok/SKILL.md server
  # all paths present, but stub forced to exit 23 with a foreign error only
  STUB_EXTRA_ERR='something unexpected' run "$SCRIPT" skills --apply
  [ "$status" -ne 0 ]
}

@test "AC6 audit still pulls the whole subtree and audit/ is still gitignored" {
  plant "$SERVER" audit/ws/log.txt logline
  commit
  run "$SCRIPT" audit --apply
  [ "$status" -eq 0 ]
  [ -f "$REPO/audit/ws/log.txt" ]
  # the carve-out is only safe while audit/ is ignored: assert on the REAL repo
  git -C "$HYDRA_REPO" check-ignore -q audit/
}

@test "workspaces target pulls tracked server-owned files only" {
  track workspaces/cmo/MEMORY.md; track workspaces/cmo/wiki/a.md
  commit
  plant "$SERVER" workspaces/cmo/MEMORY.md live
  plant "$SERVER" workspaces/cmo/wiki/a.md live
  plant "$SERVER" workspaces/cmo/.openclaw/state.json runtime
  plant "$SERVER" workspaces/cmo/secrets/key SECRET
  run "$SCRIPT" workspaces --apply
  [ "$status" -eq 0 ]
  [ ! -e "$REPO/workspaces/cmo/.openclaw/state.json" ]
  [ ! -e "$REPO/workspaces/cmo/secrets/key" ]
  grep -q '^live$' "$REPO/workspaces/cmo/MEMORY.md"
}

@test "C1 --only refuses a NEVER_PULL path (tier-2 approver allowlist), rsync never invoked" {
  track skills-all/muso-ops-admin/config/tier2-approvers.txt; track skills-all/ok/tests/t.sh; commit
  plant "$SERVER" skills-all/muso-ops-admin/config/tier2-approvers.txt tampered
  run "$SCRIPT" skills --apply --only skills-all/muso-ops-admin/config/tier2-approvers.txt
  [ "$status" -eq 1 ]
  echo "$output" | grep -q 'NEVER_PULL'
  echo "$output" | grep -q 'edit it in git'
  run "$SCRIPT" skills --only skills-all/ok/tests/t.sh
  [ "$status" -eq 1 ]
  [ ! -s "$RSYNC_CALLS" ]
  grep -q '^repo$' "$REPO/skills-all/muso-ops-admin/config/tier2-approvers.txt"
}

@test "C2 count assertion pins the entries by content: a net-neutral swap is refused" {
  track skills-all/ok/SKILL.md; commit
  sed -i.bak "s|^  'secrets/'|  'zzz-decoy/'|" "$SCRIPT"
  run "$SCRIPT" skills
  [ "$status" -eq 1 ]
  echo "$output" | grep -q 'NEVER_PULL'
  [ ! -s "$RSYNC_CALLS" ]
}

@test "C3 a failed git ls-files fails closed and never says the repo matches" {
  mkdir -p "$T/norepo/scripts"; cp "$SCRIPT" "$T/norepo/scripts/"
  run "$T/norepo/scripts/sync-from-server.sh" skills
  [ "$status" -eq 1 ]
  if echo "$output" | grep -q 'matches server'; then false; fi
  [ ! -s "$RSYNC_CALLS" ]
}
