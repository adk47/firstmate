#!/usr/bin/env bash
# Reviewer-visible end-to-end transcript for bin/fm-pr-event.sh.
# Builds a throwaway firstmate home: a real bare origin, the author's real
# worktree, and the state/<id>.meta record fm-pr-check.sh writes. Then it runs
# the production command exactly as a pr-flow producer would and prints the
# records, the dedup collapse, the head advance, the refusals, and the ladder
# state a watcher would see.
set -u

REPO=${REPO:?set REPO to the worktree under test}
EVENT="$REPO/bin/fm-pr-event.sh"
INBOX_LIB="$REPO/bin/fm-task-inbox-lib.sh"
URL='https://github.com/Muso-AI/H-DevOps/pull/4301'
PR_REF=refs/pull/4301/head
DEMO=$(mktemp -d "${TMPDIR:-/tmp}/fm-pr-event-demo.XXXXXX")
trap 'rm -rf -- "$DEMO"' EXIT

# shellcheck source=tests/lib.sh
. "$REPO/tests/lib.sh"

say() { printf '\n=== %s ===\n' "$*"; }
body() { bash -c '. "$1"; fm_task_inbox_body "$2"' _ "$INBOX_LIB" "$1"; }
action() { bash -c '. "$1"; shift; "$@"' _ "$INBOX_LIB" "$@"; }
git_commit() { git -C "$1" -c user.name='Demo' -c user.email='demo@example.invalid' commit -qm "$2"; }

# --- fixture: bare origin + author worktree with a pull request head ----------
mkdir -p "$DEMO/home/state" "$DEMO/fakebin"
git init -q --bare "$DEMO/origin.git"
git -C "$DEMO/origin.git" symbolic-ref HEAD refs/heads/main
git clone -q "$DEMO/origin.git" "$DEMO/wt" 2>/dev/null
printf 'base\n' > "$DEMO/wt/file.txt"
git -C "$DEMO/wt" add file.txt; git_commit "$DEMO/wt" base
git -C "$DEMO/wt" push -q origin main
printf 'head-a\n' >> "$DEMO/wt/file.txt"
git -C "$DEMO/wt" add file.txt; git_commit "$DEMO/wt" head-a
git -C "$DEMO/wt" push -q origin "HEAD:$PR_REF"

cat > "$DEMO/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$DEMO/fakebin/tmux"
printf '#!/usr/bin/env bash\nexit 0\n' > "$DEMO/fakebin/sleep"
chmod +x "$DEMO/fakebin/sleep"

fm_write_meta "$DEMO/home/state/author-t1.meta" \
  "window=sess:fm-author-t1" "kind=ship" "harness=claude" "pr=$URL" "worktree=$DEMO/wt"

fire() {
  env PATH="$DEMO/fakebin:$PATH" FM_ROOT_OVERRIDE="$DEMO/home" FM_HOME="$DEMO/home" \
    FM_SEND_SETTLE=0 "$EVENT" "$@"
}

say "author resolved from recorded pr= metadata; event fired (head A)"
HEAD_A=$(git -C "$DEMO/origin.git" rev-parse "$PR_REF")
fire "$URL" finding 'no test covers the retry'; echo "exit=$?"
echo "--- record $DEMO/home/state/author-t1.inbox/001.msg ---"
cat "$DEMO/home/state/author-t1.inbox/001.msg"

say "the record is fire-and-forget and stays OFF the re-ring ladder (grace=0 so a normal record would ring)"
action fm_task_inbox_is_fire_and_forget "$DEMO/home/state/author-t1.inbox/001.msg" \
  && echo "delivery=fire-and-forget: yes"
echo "due_action(author-t1, FM_TASK_INBOX_GRACE_SECS=0) = $(FM_TASK_INBOX_GRACE_SECS=0 action fm_task_inbox_due_action "$DEMO/home/state" author-t1)"

say "blind retry of the same event collapses onto the same record"
fire "$URL" finding 'no test covers the retry'; echo "exit=$?"
echo "record count = $(find "$DEMO/home/state/author-t1.inbox" -maxdepth 1 -name '*.msg' | wc -l | tr -d ' ')"

say "the pull request head advances; same kind, same text is a NEW record"
printf 'head-b\n' >> "$DEMO/wt/file.txt"
git -C "$DEMO/wt" add file.txt; git_commit "$DEMO/wt" head-b
git -C "$DEMO/wt" push -q origin "HEAD:$PR_REF"
HEAD_B=$(git -C "$DEMO/origin.git" rev-parse "$PR_REF")
echo "head A = $HEAD_A"
echo "head B = $HEAD_B"
fire "$URL" finding 'no test covers the retry'; echo "exit=$?"
echo "record count = $(find "$DEMO/home/state/author-t1.inbox" -maxdepth 1 -name '*.msg' | wc -l | tr -d ' ')"
echo "--- body 002 ---"; body "$DEMO/home/state/author-t1.inbox/002.msg"; echo

say "the same head reached via --head <sha> instead of live resolution collapses (identity, not rendering)"
fire --head "$HEAD_B" "$URL" finding 'no test covers the retry'; echo "exit=$?"
echo "record count = $(find "$DEMO/home/state/author-t1.inbox" -maxdepth 1 -name '*.msg' | wc -l | tr -d ' ')"

say "a pull request no task records is refused, not guessed (producer keeps its own routing)"
fire 'https://github.com/Muso-AI/H-DevOps/pull/9999' finding 'no test covers the retry'; echo "exit=$?"

say "two tasks recording the same pull request is refused, not guessed"
fm_write_meta "$DEMO/home/state/author-t2.meta" \
  "window=sess:fm-author-t2" "kind=ship" "harness=claude" "pr=$URL"
fire "$URL" finding 'no test covers the retry'; echo "exit=$?"

say "final inbox state for author-t1"
ls -1 "$DEMO/home/state/author-t1.inbox"/*.msg

rm -rf -- "$DEMO"
