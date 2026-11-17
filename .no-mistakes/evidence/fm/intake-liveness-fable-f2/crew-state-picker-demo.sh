#!/usr/bin/env bash
# End-to-end: the real Pi 1.5.2 /model picker screen captured through a pty
# (screen-open.log, same capture the live guard takes) is served as the crew's
# tmux pane; the real bin/fm-crew-state.sh must read it as blocked.
set -u
ROOT=/home/aaron/.no-mistakes/worktrees/72295860b10d/01M7M2RCQZKTS196CTVGCY9W11
EV=/home/aaron/.no-mistakes/evidence/01M7M2RCQZKTS196CTVGCY9W11
D=$(mktemp -d "${TMPDIR:-/tmp}/fm-picker-crew.XXXXXX")
trap 'rm -rf "$D"' EXIT
mkdir -p "$D/state" "$D/fakebin" "$D/wt"
git -C "$D/wt" init -q
git -C "$D/wt" commit -q --allow-empty -m init
git -C "$D/wt" checkout -q -b fm/feat-picker
SCREEN="$EV/real-pi-picker-screen.txt"

cat > "$D/fakebin/tmux" <<EOF
#!/usr/bin/env bash
case "\${1:-}" in
  display-message) printf '%%1\n' ;;
  list-windows) ;;
  capture-pane) cat "$SCREEN" ;;
esac
exit 0
EOF
cat > "$D/fakebin/no-mistakes" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$D/fakebin/"*

"$ROOT/bin/fm-busy-event.sh" arm "$D/state" feat-picker >/dev/null
GEN=$("$ROOT/bin/fm-busy-event.sh" arm "$D/state" feat-picker)
"$ROOT/bin/fm-busy-event.sh" apply "$D/state" feat-picker idle --gen "$GEN" --source pi-ext --event agent-settled
printf 'window=fm:fm-feat-picker\nworktree=%s\nkind=ship\nharness=pi\n' "$D/wt" > "$D/state/feat-picker.meta"
printf 'working: implementing the fix\n' > "$D/state/feat-picker.status"
export FM_AGENT_PROC_TABLE=/nonexistent/fm-agent-proc-table
export FM_AGENT_PROC_OPEN_FILES=/nonexistent/fm-agent-proc-open-files
PATH="$D/fakebin:$PATH" FM_STATE_OVERRIDE="$D/state" "$ROOT/bin/fm-crew-state.sh" feat-picker
