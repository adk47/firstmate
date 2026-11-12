#!/usr/bin/env bash
# gdpr-dsar-clock-register.sh - put the GDPR statutory clock check into a firstmate home, bound to its bytes.
#
# What a firstmate home needs before its watcher will run scripts/gdpr-dsar-clock-check.sh is two things, and this
# script is both: the check as a mode-0700 file in the home's state directory, and a trust record of its sha256
# (the home's own bin/fm-check-register.sh writes that; the watcher refuses any check whose bytes the record does
# not cover). It is run from this repository, with the bytes of this checkout, so "registered" is something the
# repository does and can be asked about, not a note in a document:
#
#   FM_HOME=/path/to/firstmate scripts/gdpr-dsar-clock-register.sh            # install + register (idempotent)
#   FM_HOME=/path/to/firstmate scripts/gdpr-dsar-clock-register.sh --check    # rc 0: registered to THESE bytes
#   FM_HOME=/path/to/firstmate scripts/gdpr-dsar-clock-register.sh --unregister
#
# The id sorts first on purpose. The watcher runs a home's checks in name order and ends the sweep at the first one
# that has a line, so a check far down the list can go unrun for hours behind chattier ones (registered as
# `gdpr-dsar-clock`, 57th of 94, this one was not run once in two and a half hours on 2026-11-12). A statutory date
# is not the thing to queue behind them, and this check costs the others nothing: it prints once a day, or when the
# set of requests it names changes, and is silent on every other sweep.
#
# No deploy of this repository can run this for you: it runs on node-8, which has no route into a firstmate box
# (the read is a pull for the same reason). What does deploy is the other half, `gdpr-dsar-clock.timer`
# (scripts/install-aux-units.sh): it pages while requests are named and no firstmate check has read the clock for
# 26 h, and while the check that IS reading it is not the one deployed (the check sends its own sha256 with every
# read). So a home where this was never run, or was run before the check changed, is loud within the hour.
set -euo pipefail

ID="a0-gdpr-dsar-clock"
EARLIER_IDS=("gdpr-dsar-clock")          # ids this check was registered under before; retired on install
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
SRC="$HERE/gdpr-dsar-clock-check.sh"

usage() { sed -n '2,13p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
die() { printf 'gdpr-dsar-clock-register: %s\n' "$*" >&2; exit 1; }

mode=install
home="${FM_HOME:-}"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --check) mode=check ;;
    --unregister) mode=unregister ;;
    --fm-home) [ "$#" -ge 2 ] || { usage >&2; exit 2; }; home=$2; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
  shift
done

[ -n "$home" ] || die "no firstmate home: set FM_HOME or pass --fm-home (nothing is guessed)"
[ -d "$home/state" ] && [ ! -L "$home/state" ] || die "$home/state is not a directory"
[ -f "$SRC" ] || die "$SRC is missing"
register="$home/bin/fm-check-register.sh"
unregister="$home/bin/fm-check-unregister.sh"
dest="$home/state/$ID.check.sh"
trust="$home/state/$ID.check-trust"
want=$(sha256sum "$SRC" | awk '{print $1}')

registered_sha() {            # the sha256 the home's trust record names, or nothing
  [ -f "$trust" ] && [ "$(sed -n 1p "$trust")" = "fm-custom-check-v1" ] && sed -n 2p "$trust"
}

case "$mode" in
  check)
    [ -f "$dest" ] || die "not registered: $dest is absent"
    have=$(sha256sum "$dest" | awk '{print $1}')
    bound=$(registered_sha || true)
    [ "$have" = "$want" ] || die "stale: $dest is ${have:0:12}, this checkout's check is ${want:0:12} (run without --check)"
    [ "$bound" = "$want" ] || die "not bound: the trust record names '${bound:0:12}', the check is ${want:0:12}"
    for old in "${EARLIER_IDS[@]}"; do
      [ ! -e "$home/state/$old.check.sh" ] || die "the earlier id '$old' is still registered beside '$ID'"
    done
    printf 'registered: %s sha256 %s\n' "$dest" "$want"
    ;;
  unregister)
    [ -x "$unregister" ] || die "$unregister is missing"
    FM_HOME="$home" "$unregister" "$ID"
    ;;
  install)
    [ -x "$register" ] || die "$register is missing: $home is not a firstmate home"
    for old in "${EARLIER_IDS[@]}"; do
      if [ -e "$home/state/$old.check.sh" ] || [ -e "$home/state/$old.check-trust" ]; then
        [ -x "$unregister" ] || die "$unregister is missing"
        FM_HOME="$home" "$unregister" "$old" >/dev/null
        printf 'retired the earlier id: %s\n' "$old"
      fi
    done
    # Written beside the destination and renamed, so the watcher never reads half a check; registered at once, so
    # the window in which the bytes and the trust record disagree is two commands long.
    tmp=$(mktemp "$home/state/.gdpr-dsar-clock.XXXXXX")
    trap 'rm -f -- "$tmp"' EXIT
    install -m 0700 "$SRC" "$tmp"
    mv -f -- "$tmp" "$dest"
    trap - EXIT
    FM_HOME="$home" "$register" "$ID" >/dev/null || die "$register refused $ID"
    [ "$(registered_sha || true)" = "$want" ] || die "registered, but the trust record does not name ${want:0:12}"
    printf 'registered: %s sha256 %s\n' "$dest" "$want"
    printf 'retire with: FM_HOME=%s %s --unregister\n' "$home" "scripts/gdpr-dsar-clock-register.sh"
    ;;
esac
