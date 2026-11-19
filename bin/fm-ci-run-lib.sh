# shellcheck shell=bash
# fm-ci-run-lib.sh - the one classifier for a GitHub Actions workflow run's
# answer: is this run red, green, still pending, or something this code does
# not recognise?
#
# Usage: . bin/fm-ci-run-lib.sh; fm_ci_run_class <status> <conclusion>
#
# ONE OWNER. Every firstmate check that reads workflow runs and decides whether
# the default branch is broken classifies the run through this function, so a
# null conclusion can never be read as red in one place and as pending in
# another. The pull-request merge gate (bin/fm-merge-gate-lib.sh) keeps its own
# stricter table because a PR that cannot go green is a refusal, not a page.
#
# WHY THIS EXISTS. On 2026-11-19 the CI health check reported two workflows red
# while their newest runs were still in progress, and the wake line carried
# only the workflow name, so nobody could confirm which run it had read. A run
# whose conclusion is null has not answered yet; it is pending, never red.
#
# THE TABLE. The conclusion decides; the status is carried as evidence only,
# because GitHub leaves the conclusion null until the run has completed and a
# completed run with no conclusion is a state this code cannot vouch for.
#
#   red      failure, timed_out, cancelled: the run finished and did not pass.
#   green    success, plus skipped and neutral: the run ended without failing.
#   pending  an empty or null conclusion: the run has not answered yet, whatever
#            its status says (queued, in_progress, waiting, requested, pending).
#   unknown  any other string, including stale, action_required,
#            startup_failure, and whatever GitHub adds next. Unknown never
#            pages: a new upstream state must not silently become "red".
#
# Both inputs are compared case-insensitively after trimming, so a `null` that
# arrived as the four-letter word from a jq `tostring` reads the same as an
# empty field.

fm_ci_run_normalize() {
  local v=$1
  v=${v#"${v%%[![:space:]]*}"}
  v=${v%"${v##*[![:space:]]}"}
  printf '%s\n' "$v" | tr '[:upper:]' '[:lower:]'
}

# fm_ci_run_class <status> <conclusion>: print red|green|pending|unknown.
fm_ci_run_class() {
  local conclusion
  conclusion=$(fm_ci_run_normalize "${2:-}")
  case "$conclusion" in
    failure|timed_out|cancelled) printf 'red\n' ;;
    success|skipped|neutral) printf 'green\n' ;;
    ''|null) printf 'pending\n' ;;
    *) printf 'unknown\n' ;;
  esac
}

# fm_ci_run_is_red <status> <conclusion>: true only for the red class.
fm_ci_run_is_red() {
  [ "$(fm_ci_run_class "$1" "$2")" = red ]
}
