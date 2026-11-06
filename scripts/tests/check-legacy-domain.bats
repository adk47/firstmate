#!/usr/bin/env bats
# MUS-31227: scripts/check-legacy-domain.sh must fail closed (exit 1 on a hit, exit 2 when git grep itself errors).

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  WORK="$(mktemp -d)"
  git -C "$WORK" init -q
  mkdir -p "$WORK/scripts"
  cp "$REPO/scripts/check-legacy-domain.sh" "$WORK/scripts/"
  printf 'scripts/check-legacy-domain.sh\n' > "$WORK/.legacy-domain-allowlist"
  printf 'link https://credits.%s/x\n' "muso.ai" > "$WORK/src.txt"
  git -C "$WORK" add -A
}
teardown() { rm -rf "$WORK"; }

@test "a hit outside the allowlist exits 1" {
  cd "$WORK" && run bash scripts/check-legacy-domain.sh
  [ "$status" -eq 1 ]
}

@test "an allow-listed file passes" {
  echo "src.txt" >> "$WORK/.legacy-domain-allowlist"
  cd "$WORK" && run bash scripts/check-legacy-domain.sh
  [ "$status" -eq 0 ]
}

@test "a pathspec git rejects exits 2, never a silent pass" {
  echo "src.txt" >> "$WORK/.legacy-domain-allowlist"
  echo "../outside" >> "$WORK/.legacy-domain-allowlist"
  cd "$WORK" && run bash scripts/check-legacy-domain.sh
  [ "$status" -eq 2 ]
}
