#!/usr/bin/env bash
# Single owner of a ship task's mode-specific "Definition of done" block.
# Sourced by bin/fm-brief.sh, which renders it into a generated ship brief, and by
# bin/fm-promote.sh, which renders it into the ship instructions a promoted scout
# receives. Both paths must hand the worker the same contract: a promoted
# no-mistakes worker that never received the ask-user escalation rule or the
# `--yes` ban is the exact delivery hole this single owner exists to close.
# fm_dod_block <no-mistakes|direct-PR|local-only> <task-id> prints the block on
# stdout with no trailing blank line. The caller validates the mode; an unknown
# mode is refused rather than silently rendered as the pipeline contract.
# The block opens with the fixed machine-readable "Delivery contract: mode=<mode>"
# line that bin/fm-spawn.sh checks a ship brief against.
# This file is the one owner of the no-mistakes `--intent` contract: only the
# brief's `## Captain's intent` subsection plus later captain words, never
# `## Firstmate spec` and never the worker's own tradeoffs.
# The string passed must be self-sufficient - it plus the codebase reconstructs
# roughly the same specification - so a report, decision, or PR the intent
# refers to is written into it as substance, never left as a pointer.
# bin/fm-brief.sh scaffolds those two `# Task` subsections; bin/fm-spawn.sh and
# bin/fm-promote.sh refuse leftover `{TASK}` / `{FIRSTMATE_SPEC}` placeholders
# through the helpers below. Other mentions of `--intent` point here rather than
# restating the rule.
# Every heredoc here stays outside a command substitution: `VAR=$(cat <<EOF ...)`
# breaks parsing of the whole file on Bash 3.2 (tests/fm-brief.test.sh).
# This file is also the one owner of a ship task's acceptance probe: the script
# Firstmate writes at intake that reads the LIVE consumer surface and exits 0
# only once the change is there. fm_acceptance_install binds it at
# state/acceptance/<task>.sh (mode 0700) with its sha256 in
# state/acceptance/<task>.trust, the same content binding a custom check gets;
# fm_acceptance_verify re-checks that binding before anything runs it, so an
# edited probe is never trusted; and fm_dod_block's third argument renders the
# rule that done means the probe exits 0 when something other than the worker
# runs it, and that the worker never edits it. bin/fm-landing-police.sh runs it,
# bin/fm-change-watch.sh records it, and bin/fm-landed-lib.sh gates teardown.

FM_ACCEPTANCE_TRUST_VERSION='fm-acceptance-probe-v1'

fm_acceptance_dir() { printf '%s/acceptance\n' "$1"; }  # <state-dir>
fm_acceptance_path() { printf '%s/acceptance/%s.sh\n' "$1" "$2"; }  # <state-dir> <task-id>
fm_acceptance_trust_path() { printf '%s/acceptance/%s.trust\n' "$1" "$2"; }  # <state-dir> <task-id>

fm_acceptance_sha256() {  # <file>
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" 2>/dev/null | awk '{print $1}'
  else
    return 1
  fi
}

# Refuse a probe that cannot prove anything about the live surface: an empty
# file, or one that reads a local copy of the code (a project clone or a task
# worktree) instead of the system the customer uses.
fm_acceptance_source_ok() {  # <source-file>
  local src=$1
  [ -f "$src" ] && [ ! -L "$src" ] || { echo "error: acceptance probe $src is not a regular file" >&2; return 1; }
  grep -q '[^[:space:]]' "$src" || { echo "error: acceptance probe $src is empty" >&2; return 1; }
  if grep -Eq '(/projects/|\.treehouse/|/worktrees?/)' "$src"; then
    echo "error: acceptance probe $src reads a local copy of the code; it must read the live consumer surface (served bytes, bucket object, running revision, production row count)" >&2
    return 1
  fi
}

# Install the probe into the state dir and bind its bytes. Prints the path.
# Installing the same bytes again is a no-op, so a retried intake succeeds;
# different bytes over an existing probe are refused, because a task's probe is
# written once.
fm_acceptance_install() {  # <state-dir> <task-id> <source-file>
  local state=$1 id=$2 src=$3 dir dest trust sha tmp
  fm_acceptance_source_ok "$src" || return 1
  dir=$(fm_acceptance_dir "$state")
  dest=$(fm_acceptance_path "$state" "$id")
  trust=$(fm_acceptance_trust_path "$state" "$id")
  if ! { mkdir -p "$dir" && chmod 0700 "$dir"; }; then
    echo "error: cannot create $dir" >&2
    return 1
  fi
  tmp=$(umask 077; mktemp "$dir/.probe.XXXXXX") || return 1
  if ! { { head -c 2 "$src" | grep -q '^#!' || printf '#!/usr/bin/env bash\n'; cat "$src"; } > "$tmp" && chmod 0700 "$tmp"; }; then
    rm -f "$tmp"
    echo "error: cannot write $dest" >&2
    return 1
  fi
  sha=$(fm_acceptance_sha256 "$tmp")
  if [ -z "$sha" ]; then
    rm -f "$tmp"
    echo "error: cannot hash $src" >&2
    return 1
  fi
  if [ -e "$dest" ] || [ -L "$dest" ]; then
    rm -f "$tmp"
    if fm_acceptance_verify "$state" "$id" >/dev/null && [ "$(sed -n 2p "$trust")" = "$sha" ]; then
      printf '%s\n' "$dest"
      return 0
    fi
    echo "error: $dest already exists with different bytes; a task's acceptance probe is written once, at intake" >&2
    return 1
  fi
  # The binding lands before the probe, so an interrupted install leaves no
  # probe (a retry installs it) rather than an unbound one (never trusted).
  local bind
  bind=$(umask 077; mktemp "$dir/.trust.XXXXXX") || { rm -f "$tmp"; return 1; }
  if ! { printf '%s\n%s\n' "$FM_ACCEPTANCE_TRUST_VERSION" "$sha" > "$bind" && chmod 0600 "$bind" && mv -f "$bind" "$trust"; }; then
    rm -f "$tmp" "$bind"
    echo "error: cannot write $trust" >&2
    return 1
  fi
  if ! mv -f "$tmp" "$dest"; then
    rm -f "$tmp"
    echo "error: cannot write $dest" >&2
    return 1
  fi
  printf '%s\n' "$dest"
}

# 0 when the task has a probe whose bytes still match its binding and print its
# path; 1 when it has none; 2 when it exists but is not trusted (edited, wrong
# mode, a symlink, or no binding).
fm_acceptance_verify() {  # <state-dir> <task-id>
  local state=$1 id=$2 dest trust want have mode
  dest=$(fm_acceptance_path "$state" "$id")
  trust=$(fm_acceptance_trust_path "$state" "$id")
  [ -e "$dest" ] || [ -L "$dest" ] || return 1
  [ -f "$dest" ] && [ ! -L "$dest" ] || return 2
  mode=$(stat -c %a "$dest" 2>/dev/null || stat -f %Lp "$dest" 2>/dev/null)
  [ "$mode" = 700 ] || return 2
  [ "$(sed -n 1p "$trust" 2>/dev/null)" = "$FM_ACCEPTANCE_TRUST_VERSION" ] || return 2
  want=$(sed -n 2p "$trust" 2>/dev/null)
  have=$(fm_acceptance_sha256 "$dest")
  [ -n "$want" ] && [ "$want" = "$have" ] || return 2
  printf '%s\n' "$dest"
}

fm_acceptance_block() {  # <probe-path>
  local probe=$1
  cat <<EOF

## Acceptance probe
Your \`done:\` is a claim. Done means this task's acceptance probe exits 0 when something other than you runs it:
\`$probe\`
Firstmate wrote it at intake. It reads the LIVE consumer surface - the served bytes, the bucket object, the running revision, the production row count - never the repo or your local copy.
Never edit, move, or replace that file: its bytes are bound by hash, an edited probe is never trusted, and the task cannot be proven or cleaned up until firstmate restores it.
You may run it read-only to see where you stand. When it exits non-zero after you believe the work is finished, the work has not landed: find out why (not merged, not deployed, wrong bytes served) and fix that, or report \`blocked:\` with the probe's output.
If the probe itself is wrong, say so with \`blocked:\` and the evidence; never claim done around it.
After your \`done:\` line, the landing police runs the probe at the claim and again at +15m, +1h, and +6h; a claim still failing past its deadline is reported as claimed but not landed, and a claim still failing at +6h is recorded absent.
EOF
}

# Return 0 when a Task subsection still consists only of its scaffold
# placeholder. A missing file and legacy briefs carry no such placeholders.
fm_brief_task_placeholders_present() {  # <file>
  local file=$1 intent spec
  [ -f "$file" ] || return 1
  intent=$(fm_brief_task_heading_body "$file" "## Captain's intent")
  spec=$(fm_brief_task_heading_body "$file" "## Firstmate spec")
  [ "$(printf '%s' "$intent" | tr -d '[:space:]')" = '{TASK}' ] && return 0
  [ "$(printf '%s' "$spec" | tr -d '[:space:]')" = '{FIRSTMATE_SPEC}' ] && return 0
  return 1
}

# Parse an exact ATX heading outside fenced blocks. Body mode prints through
# the next unfenced heading at the same or a higher level; present mode reports
# whether the heading exists.
fm_brief_heading_parse() {  # <file|-> <heading> <body|present>
  local file=$1 heading=$2 mode=$3 input=$1
  if [ "$file" = - ]; then
    input=/dev/stdin
  else
    [ -f "$file" ] || { [ "$mode" = body ]; return; }
  fi
  awk -v heading="$heading" -v mode="$mode" '
    BEGIN {
      target_level = 0
      while (substr(heading, target_level + 1, 1) == "#") target_level++
    }
    {
      line = $0
      scan = line
      spaces = 0
      while (spaces < 3 && substr(scan, 1, 1) == " ") {
        scan = substr(scan, 2)
        spaces++
      }
      marker = substr(scan, 1, 1)
      marker_len = 0
      if (marker == "`" || marker == "~") {
        while (substr(scan, marker_len + 1, 1) == marker) marker_len++
      }
      is_fence = marker_len >= 3
      was_fenced = fenced

      if (is_fence) {
        rest = substr(scan, marker_len + 1)
        if (!fenced) {
          fenced = 1
          fence_marker = marker
          fence_len = marker_len
        } else if (marker == fence_marker && marker_len >= fence_len && rest ~ /^[[:space:]]*$/) {
          fenced = 0
        }
      }

      if (!found && !was_fenced && line == heading) {
        found = 1
        if (mode == "present") next
        grab = 1
        next
      }
      if (mode == "present" || !grab) next
      if (is_fence || was_fenced) {
        print line
        next
      }

      level = 0
      while (substr(scan, level + 1, 1) == "#") level++
      if (level > 0 && level <= target_level && substr(scan, level + 1, 1) ~ /^[[:space:]]?$/) exit
      print line
    }
    END {
      if (mode == "present" && !found) exit 1
    }
  ' "$input"
}

fm_brief_heading_body() {  # <file> <heading>
  fm_brief_heading_parse "$1" "$2" body
}

fm_brief_heading_present() {  # <file> <heading>
  fm_brief_heading_parse "$1" "$2" present >/dev/null
}

fm_brief_task_heading_body() {  # <file> <heading>
  local task
  task=$(fm_brief_heading_body "$1" "# Task")
  printf '%s\n' "$task" | fm_brief_heading_parse - "$2" body
}

fm_brief_task_heading_present() {  # <file> <heading>
  local task
  task=$(fm_brief_heading_body "$1" "# Task")
  printf '%s\n' "$task" | fm_brief_heading_parse - "$2" present >/dev/null
}

fm_brief_marked_captain_words() {  # <task-body>
  printf '%s\n' "$1" | awk '
    match($0, /^[[:space:]]*Captain('\''s (words|ask|intent))?:[[:space:]]*/) {
      words = substr($0, RLENGTH + 1)
      if (words ~ /[^[:space:]]/) print words
    }
  '
}

fm_brief_intent_overlay() {  # <captain-intent>
  cat <<'EOF'

# Current no-mistakes intent contract
This section supersedes every earlier brief instruction about constructing `--intent`, but not later clarifications actually supplied by the captain.
Use the serialized captain intent below plus any later words the captain actually supplied as `--intent`; never include Firstmate specification or other mixed Task content.

## Captain intent authorized for --intent
EOF
  printf '%s\n' "$1"
  cat <<'EOF'

Firstmate-authored constraints, acceptance criteria, implementation details, decisions, and tradeoffs are specification, not captain intent.
The Definition of done's rule that `--intent` must be self-sufficient still governs the string you pass: resolve any report, decision, or PR the intent above refers to into its substance rather than passing the pointer.
EOF
}

# Accept the current two-subsection contract only when both bodies have content;
# briefs predating that contract remain valid when their # Task body has content.
fm_brief_task_content_valid() {  # <file>
  local file=$1 intent spec task has_intent=0 has_spec=0
  [ -f "$file" ] && [ -r "$file" ] || return 1
  fm_brief_task_heading_present "$file" "## Captain's intent" && has_intent=1
  fm_brief_task_heading_present "$file" "## Firstmate spec" && has_spec=1
  if [ "$has_intent" -eq 1 ] || [ "$has_spec" -eq 1 ]; then
    [ "$has_intent" -eq 1 ] && [ "$has_spec" -eq 1 ] || return 1
    intent=$(fm_brief_task_heading_body "$file" "## Captain's intent")
    spec=$(fm_brief_task_heading_body "$file" "## Firstmate spec")
    [ -n "$(printf '%s' "$intent" | tr -d '[:space:]')" ] || return 1
    [ -n "$(printf '%s' "$spec" | tr -d '[:space:]')" ] || return 1
    return 0
  fi
  task=$(fm_brief_heading_body "$file" "# Task")
  [ -n "$(printf '%s' "$task" | tr -d '[:space:]')" ]
}

fm_ask_user_escalation_block() {  # <data-dir> <task-id>
  local data=$1 id=$2
  cat <<EOF
   For a no-mistakes ask-user gate specifically, escalate all ask-user findings as one event plus one snapshot file, using that same shape even when the gate holds only a single ask-user finding: write only the ask-user findings, verbatim and unparaphrased (id, severity, file, line, description, authority), to \`$data/$id/nm-<run>-findings.txt\`, then report the gate with
   \`needs-decision [key=nm-<run>-<step>]: ask-user findings=<id1>,<id2>,... file=$data/$id/nm-<run>-findings.txt\`
   naming every ask-user finding id from that gate. The status line only points at the file; it never restates or summarizes a finding's content.
EOF
}

fm_dod_block() {  # <mode> <task-id> [<acceptance-probe-path>]
  local mode=$1 id=$2 probe=${3:-}
  fm_dod_mode_block "$mode" "$id" || return 1
  [ -z "$probe" ] || fm_acceptance_block "$probe"
}

fm_dod_mode_block() {  # <mode> <task-id>
  local mode=$1 id=$2
  case "$mode" in
    direct-PR)
      cat <<EOF
# Definition of done
Delivery contract: mode=direct-PR
This task ships **direct-PR**: you raise the PR yourself, without the no-mistakes pipeline.
The task is complete only when committed on your branch.
When it is implemented and committed, push your branch and open a PR with \`gh-axi\`, then append \`done: PR {url}\` to the status file and stop.
Do NOT run /no-mistakes. The configured merge authority decides whether to merge the PR; firstmate relays the outcome.
EOF
      ;;
    local-only)
      cat <<EOF
# Definition of done
Delivery contract: mode=local-only
This task ships **local-only**: no remote, no PR, no pipeline.
The task is complete only when committed on your branch \`fm/$id\`. Do NOT push, do NOT open a PR, do NOT merge.
Keep your branch a clean fast-forward onto the current default branch - if \`main\` has advanced, rebase onto it so the eventual merge stays a fast-forward.
When it is implemented and committed, append \`done: ready in branch fm/$id\` to the status file and stop.
The configured merge authority approves the ready branch, then firstmate merges it into local \`main\` through the guarded fast-forward path.
EOF
      ;;
    no-mistakes)
      cat <<EOF
# Definition of done
Delivery contract: mode=no-mistakes
The task is complete only when committed on your branch.
When you believe it is complete, append \`done: {summary}\` to the status file and stop.
Firstmate will then instruct you to run /no-mistakes to validate and ship a PR.

You drive no-mistakes by responding to its gates, not by implementing fixes.
Follow the guidance no-mistakes itself provides for the mechanics: it loads when you invoke /no-mistakes, and \`no-mistakes axi run --help\` plus the \`help\` lines in each \`axi\` response are authoritative and version-matched to the installed binary.
When starting no-mistakes, pass \`--intent\` as only this brief's \`## Captain's intent\` subsection plus any later words the captain actually said.
For a legacy brief with no such subsection, include only words explicitly labeled \`Captain:\`, \`Captain's words:\`, \`Captain's ask:\`, or \`Captain's intent:\`; never copy its mixed \`# Task\` wholesale. If it has no provenance-marked captain words, stop and ask firstmate instead of starting no-mistakes.
Do not include \`## Firstmate spec\`, later Firstmate build constraints, or your own decisions and tradeoffs.
The \`--intent\` string you pass must be self-sufficient: that string plus the codebase must let a reader reconstruct roughly the same specification, without depending on a separate report, a PR, or context that lives only in this conversation.
When the captain's intent refers to a report, decision, or PR ("do items 1, 2, 3, and 7 of the report"), write the substance of the referenced items into \`--intent\` in the captain's terms, not only the pointer; that substance is the captain's ask by reference, while Firstmate's build instructions and your own decisions still stay out.
This replaces the no-mistakes skill's advice to enrich \`--intent\` with decisions and tradeoffs; that advice does not apply to Firstmate-dispatched work.
Do not hand-edit, commit, or fix findings yourself while a run is active - the pipeline applies every fix.

Two firstmate-specific rules layer on top of that guidance:
- ask-user findings are never yours to answer: escalate to firstmate using rule 6's ask-user format and stop.
  Firstmate applies \`ask-user-authority\` and obtains any required captain decision.
  When the decision comes back, feed it to the gate with \`no-mistakes axi respond\` and let the pipeline apply it - do not route the question to "the user" or implement the fix yourself.
- NEVER pass \`--yes\` (or \`-y\`) to \`no-mistakes axi run\` or \`no-mistakes axi respond\`. It is banned fleet-wide.
  It auto-resolves every gate including ask-user findings with no escalation, and answering your own ask-user finding is a hard rule violation.

After /no-mistakes reports CI green (the CI-ready return point - do not wait for it to keep monitoring in the background until merge), append \`done: PR {url} checks green\` and stop. You are finished.
EOF
      ;;
    *)
      echo "error: fm_dod_block: unknown delivery mode '$mode'" >&2
      return 1 ;;
  esac
}
