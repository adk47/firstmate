#!/usr/bin/env bash
# Behavioural test for the tmpfiles-age-by-mtime block in scripts/install-aux-units.sh.
# Executes the SHIPPED shell (extracted by its BEGIN/END markers) against a temp
# TMPFILES_D with a stubbed systemd-tmpfiles, so a formatting change cannot turn
# this red and a behaviour change cannot stay green.
#
#   bash tests/test_install_aux_units_tmpfiles.sh
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALLER="$REPO/scripts/install-aux-units.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0; failn=0
ok()   { pass=$((pass+1)); echo "  PASS $*"; }
bad()  { failn=$((failn+1)); echo "  FAIL $*"; }

# Extract the block verbatim.
awk '/^# --- BEGIN tmpfiles-age-by-mtime ---/{f=1} f{print} /^# --- END tmpfiles-age-by-mtime ---/{f=0}' "$INSTALLER" > "$T/block.sh"
[[ -s "$T/block.sh" ]] || { echo "FATAL: block markers not found in $INSTALLER"; exit 1; }
grep -q 'install -m 644 "\$tmpconf_src"' "$T/block.sh" || { echo "FATAL: extracted block is not the installer body"; exit 1; }

# Stub systemd-tmpfiles: records argv, exit code from $STUB_RC (default 0).
mkdir -p "$T/bin"
cat > "$T/bin/systemd-tmpfiles" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "${STUB_LOG:?}"
exit "${STUB_RC:-0}"
STUB
chmod +x "$T/bin/systemd-tmpfiles"

# Runner: fresh HYDRA_ROOT copy per case so mutations never touch the repo.
run_block() { # $1=hydra_root $2=tmpfiles_d ; env STUB_RC/STUB_LOG passed through
  ( export PATH="$T/bin:$PATH" HYDRA_ROOT="$1" TMPFILES_D="$2"
    log() { echo "[log] $*"; }; fail() { echo "[FATAL] $*"; exit 1; }
    # shellcheck disable=SC1090
    source "$T/block.sh" )
}
mk_root() { local r="$T/root-$1"; mkdir -p "$r/scripts/aux-units"; cp "$REPO/scripts/aux-units/tmp.conf" "$r/scripts/aux-units/tmp.conf"; echo "$r"; }

echo "case 1: fresh install"
R=$(mk_root 1); D="$T/etc1"; export STUB_LOG="$T/log1"; : > "$STUB_LOG"
out=$(run_block "$R" "$D" 2>&1); rc=$?
[[ $rc -eq 0 ]] && ok "exit 0" || bad "exit $rc: $out"
cmp -s "$R/scripts/aux-units/tmp.conf" "$D/tmp.conf" && ok "installed verbatim" || bad "dst differs from src"
grep -q -- "--create $D/tmp.conf" "$STUB_LOG" && ok "parse-validated with --create" || bad "systemd-tmpfiles not called with --create: $(cat "$STUB_LOG")"
grep -q -- "--clean" "$STUB_LOG" && bad "installer ran --clean (must never delete at install time)" || ok "never ran --clean"
[[ -e "$D/tmp.conf.pre-managed" ]] && bad "pre-managed sidecar created with no prior file" || ok "no sidecar on fresh install"

echo "case 2: idempotent re-run"
: > "$STUB_LOG"
out=$(run_block "$R" "$D" 2>&1); rc=$?
[[ $rc -eq 0 ]] && grep -q "up to date" <<<"$out" && ok "reports up to date" || bad "rc=$rc out=$out"
[[ -s "$STUB_LOG" ]] && bad "re-ran systemd-tmpfiles on unchanged file" || ok "no systemd-tmpfiles call when unchanged"

echo "case 3: pre-existing hand-edited file is backed up once"
R=$(mk_root 3); D="$T/etc3"; mkdir -p "$D"; printf 'D /tmp 1777 root root 7d\n' > "$D/tmp.conf"; export STUB_LOG="$T/log3"; : > "$STUB_LOG"
out=$(run_block "$R" "$D" 2>&1); rc=$?
[[ $rc -eq 0 ]] && ok "exit 0" || bad "exit $rc: $out"
[[ "$(cat "$D/tmp.conf.pre-managed")" == "D /tmp 1777 root root 7d" ]] && ok "first copy kept as .pre-managed" || bad "sidecar missing/wrong"
cmp -s "$R/scripts/aux-units/tmp.conf" "$D/tmp.conf" && ok "replaced with managed file" || bad "not replaced"
# Change the source again; the sidecar must still hold the ORIGINAL hand edit.
printf '# v2\n%s\n' "$(cat "$R/scripts/aux-units/tmp.conf")" > "$R/scripts/aux-units/tmp.conf"
run_block "$R" "$D" >/dev/null 2>&1
[[ "$(cat "$D/tmp.conf.pre-managed")" == "D /tmp 1777 root root 7d" ]] && ok "sidecar not overwritten on 2nd install" || bad "sidecar overwritten"

echo "case 4: parse failure restores the previous file and fails loudly"
R=$(mk_root 4); D="$T/etc4"; mkdir -p "$D"; printf 'D /tmp 1777 root root 7d\n' > "$D/tmp.conf"; export STUB_LOG="$T/log4"; : > "$STUB_LOG"
out=$(STUB_RC=1 run_block "$R" "$D" 2>&1); rc=$?
[[ $rc -ne 0 ]] && ok "non-zero exit" || bad "exit 0 despite parse failure"
[[ "$(cat "$D/tmp.conf")" == "D /tmp 1777 root root 7d" ]] && ok "previous file restored" || bad "previous file NOT restored: $(cat "$D/tmp.conf")"

echo "case 5: parse failure on a fresh host removes the new file (stock policy un-masked)"
R=$(mk_root 5); D="$T/etc5"; export STUB_LOG="$T/log5"; : > "$STUB_LOG"
out=$(STUB_RC=1 run_block "$R" "$D" 2>&1); rc=$?
[[ $rc -ne 0 && ! -e "$D/tmp.conf" ]] && ok "no half-installed file left" || bad "rc=$rc exists=$([[ -e "$D/tmp.conf" ]] && echo y || echo n)"

echo "case 6 (mutation): a source WITHOUT the mM: prefix is refused"
R=$(mk_root 6); D="$T/etc6"; export STUB_LOG="$T/log6"; : > "$STUB_LOG"
# Mutate the line the installer's own predicate matches, not a hand-typed age, so
# the sed cannot silently no-op when the age changes.
sed -i.orig -E 's/^(D \/tmp 1777 root root )mM:([0-9]+[smhdw]?)$/\1\2/' "$R/scripts/aux-units/tmp.conf"
cmp -s "$R/scripts/aux-units/tmp.conf" "$R/scripts/aux-units/tmp.conf.orig" && { bad "mutation did not apply"; } || {
  out=$(run_block "$R" "$D" 2>&1); rc=$?
  [[ $rc -ne 0 ]] && grep -q "mM:" <<<"$out" && ok "refused: $(grep -o 'must declare.*' <<<"$out" | head -1)" || bad "accepted a plain-age policy (rc=$rc)"
  [[ -e "$D/tmp.conf" ]] && bad "wrote the refused file" || ok "nothing installed"
}

echo "case 7: the shipped template itself passes the guard and carries the socket exclusions"
grep -Eq '^D /tmp 1777 root root mM:[0-9]+[smhdw]?$' "$REPO/scripts/aux-units/tmp.conf" && ok "D line is mtime-keyed (mM:<age>)" || bad "template D line not mtime-keyed"
# The floor is asserted as a literal on purpose: changing it must be said out loud here.
grep -Eq '^D /tmp 1777 root root mM:24h$' "$REPO/scripts/aux-units/tmp.conf" && ok "catch-all age is 24h" || bad "catch-all age is not 24h (update this assert if the floor changed on purpose)"
for s in X11 ICE XIM font Test; do grep -q "^x /tmp/.$s-unix$" "$REPO/scripts/aux-units/tmp.conf" && ok "x /tmp/.$s-unix" || bad "missing exclusion .$s-unix"; done

echo; echo "passed=$pass failed=$failn"
[[ $failn -eq 0 ]]
