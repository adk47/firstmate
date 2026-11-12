#!/usr/bin/env bash
# Install the CI tools hydra's PR Validation needs that the in-cluster ARC runner image
# (H-DevOps k8s/prod/arc-runners/Dockerfile.ovh-ubuntu, r8) does not carry.
#
# WHY (2026-10-27): PR Validation moved off node-8 onto the repo-level `ovh-hydra` scale set
# (H-DevOps https://github.com/Muso-AI/H-DevOps/pull/4516). node-8 had every tool installed
# by hand over months; a fresh runner pod has none of them, starts as the non-root `runner`
# user, and keeps nothing between jobs. The versions below are the ones node-8 ran on the
# day of the move, so the suites see the same tools they were written against.
#
# Usage: scripts/ci/arc-toolchain.sh <group>...
#   bats        bats + GNU parallel (bats --jobs needs it) + sqlite3 + node >= 22 + caddy + small CLIs
#   lint        shellcheck
#   node        node >= 22 (node:sqlite / --experimental-sqlite) + pnpm
#   python      tesseract + the pinned wheels in scripts/ci/requirements-arc.txt
#
# Idempotent: anything already present at a good version is skipped, so this is also safe
# on a self-hosted runner that has the tools. Node is installed under $HOME/.cache (owned
# by the runner user, so `npm -g` needs no sudo) and published via $GITHUB_PATH when set.
set -euo pipefail

NODE_VERSION="${HYDRA_CI_NODE_VERSION:-24.22.1}"   # node-8, 2026-10-27
PNPM_VERSION="${HYDRA_CI_PNPM_VERSION:-10.33.2}"   # node-8, 2026-10-27
CADDY_VERSION="${HYDRA_CI_CADDY_VERSION:-2.11.2}"  # node-8, 2026-10-28 (the noble package is 2.6)
REQS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/requirements-arc.txt"

log() { printf 'arc-toolchain: %s\n' "$*" >&2; }

SUDO=""
if [ "$(id -u)" -ne 0 ]; then
  command -v sudo >/dev/null 2>&1 || { log "not root and no sudo"; exit 1; }
  SUDO="sudo"
fi

apt_pkgs=()
need_apt() { command -v "$1" >/dev/null 2>&1 || apt_pkgs+=("$2"); }

apt_install() {
  [ "${#apt_pkgs[@]}" -gt 0 ] || return 0
  log "apt: ${apt_pkgs[*]}"
  # Two attempts: a pod's first apt-get against a mirror mid-sync is the commonest flake.
  local i
  for i in 1 2; do
    if $SUDO env DEBIAN_FRONTEND=noninteractive apt-get update -qq \
       && $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends "${apt_pkgs[@]}" >/dev/null; then
      return 0
    fi
    log "apt attempt $i failed"; sleep 5
  done
  return 1
}

publish_path() {
  export PATH="$1:$PATH"
  if [ -n "${GITHUB_PATH:-}" ]; then printf '%s\n' "$1" >> "$GITHUB_PATH"; fi
}

ensure_node() {
  local major=0
  if command -v node >/dev/null 2>&1; then
    major=$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)
  fi
  if [ "$major" -lt 22 ]; then
    local arch dir
    case "$(uname -m)" in x86_64) arch=x64 ;; aarch64|arm64) arch=arm64 ;; *) log "unsupported arch $(uname -m)"; return 1 ;; esac
    dir="$HOME/.cache/hydra-ci/node-v${NODE_VERSION}-linux-${arch}"
    if [ ! -x "$dir/bin/node" ]; then
      mkdir -p "$HOME/.cache/hydra-ci"
      log "node ${NODE_VERSION} (image has ${major:-none})"
      curl -fsSL --retry 3 "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-${arch}.tar.xz" \
        | tar -xJ -C "$HOME/.cache/hydra-ci"
    fi
    publish_path "$dir/bin"
  fi
  node --version
}

# deploy-caddy-bind-gate.bats drives the REAL `caddy adapt`; without the binary its 19 cases
# SKIP, which reads as green while proving nothing (seen on the first ovh-hydra run).
ensure_caddy() {
  if ! command -v caddy >/dev/null 2>&1; then
    local arch dir
    case "$(uname -m)" in x86_64) arch=amd64 ;; aarch64|arm64) arch=arm64 ;; *) log "unsupported arch $(uname -m)"; return 1 ;; esac
    dir="$HOME/.cache/hydra-ci/caddy-${CADDY_VERSION}"
    if [ ! -x "$dir/caddy" ]; then
      mkdir -p "$dir"
      log "caddy ${CADDY_VERSION}"
      curl -fsSL --retry 3 "https://github.com/caddyserver/caddy/releases/download/v${CADDY_VERSION}/caddy_${CADDY_VERSION}_linux_${arch}.tar.gz" \
        | tar -xz -C "$dir" caddy
    fi
    publish_path "$dir"
  fi
  caddy version | cut -d' ' -f1
}

ensure_pnpm() {
  if ! command -v pnpm >/dev/null 2>&1; then
    log "pnpm ${PNPM_VERSION}"
    npm install -g --silent "pnpm@${PNPM_VERSION}"
  fi
  pnpm --version
}

ensure_python() {
  need_apt tesseract tesseract-ocr
  apt_install; apt_pkgs=()
  # SYSTEM site, not --user: credit_verify/proof runs its parsers in a sandboxed child
  # (`python3 -I`, scrubbed env) that never sees a user site, so --user wheels made two
  # sandbox tests fail with "No module named 'PIL'". node-8 has them in
  # /usr/local/lib/python3.12/dist-packages, so that is where they go here too. The download
  # runs as the runner user into a runner-owned dir (what actions/cache saves); only the
  # offline install from it needs root.
  local bsp="" wheels="$HOME/.cache/hydra-ci/wheels"
  python3 -m pip install --help 2>/dev/null | grep -q -- '--break-system-packages' && bsp="--break-system-packages"
  if ! python3 -I - "$REQS" <<'PY' 2>/dev/null
import sys, importlib.metadata as md
for line in open(sys.argv[1]):
    line = line.split('#', 1)[0].strip()
    if not line:
        continue
    name, ver = line.split('==')
    if md.version(name) != ver:
        raise SystemExit(1)
PY
  then
    log "pip: $(grep -cvE '^\s*(#|$)' "$REQS") pinned wheel(s)"
    mkdir -p "$wheels"
    python3 -m pip download --quiet --disable-pip-version-check --only-binary=:all: -d "$wheels" -r "$REQS"
    $SUDO python3 -m pip install --quiet --disable-pip-version-check $bsp \
      --no-index --find-links "$wheels" -r "$REQS"
  fi
  tesseract --version 2>&1 | head -1
}

[ "$#" -gt 0 ] || { log "usage: $0 bats|lint|node|python ..."; exit 2; }
for g in "$@"; do
  case "$g" in
    bats)
      need_apt bats bats
      need_apt parallel parallel
      need_apt sqlite3 sqlite3
      need_apt jq jq
      need_apt lsof lsof
      need_apt logrotate logrotate
      need_apt bc bc
      # the outbound copy gate verifies its reviewer's signature with `ssh-keygen -Y verify` (node-8: OpenSSH 9.6)
      need_apt ssh-keygen openssh-client
      apt_install; apt_pkgs=()
      ensure_node
      ensure_caddy
      bats --version; parallel --version | head -1; sqlite3 --version | cut -c1-20
      ;;
    lint)
      need_apt shellcheck shellcheck
      apt_install; apt_pkgs=()
      shellcheck --version | sed -n 2p
      ;;
    node)
      ensure_node
      ensure_pnpm
      ;;
    python)
      # test_outbound_copy_gate.py signs and verifies with ssh-keygen, the same binary the gate uses on node-8
      need_apt ssh-keygen openssh-client
      apt_install; apt_pkgs=()
      ensure_python
      ;;
    *) log "unknown group: $g"; exit 2 ;;
  esac
done
