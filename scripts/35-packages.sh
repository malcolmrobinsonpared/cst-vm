#!/usr/bin/env bash
# 35-packages.sh — pre-install commonly used packages/tools for ALL students.
#
# Populates system-wide libraries and CLIs so courses (incl. boot.dev) work out
# of the box for students, who have no sudo. Split by ecosystem:
#   * Python libraries  -> APT (system site-packages; plain `import` works)
#   * Node.js CLI tools -> npm -g into the system prefix (/opt/node)
#   * dev utilities     -> APT (sqlite3, valgrind, gdb, cmake, clang, httpie, …)
#   * Go dev tools      -> `go install` into /usr/local/bin (goose, sqlc, bootdev)
#
# (Containers are intentionally NOT installed — see the hardening notes.)
#
# Idempotent-ish: apt/npm/go install are safe to re-run; a missing package name
# is skipped with a warning instead of aborting the whole stage.
set -euo pipefail
source "${HERE:?run via provision.sh}/config.env"

apt-get update -y

# --- Python libraries (APT -> system site-packages) --------------------------
# Ubuntu's system Python is PEP-668 "externally managed"; installing libs via
# apt is the supported way to make them importable by the system `python3` for
# everyone. Students' own extra deps go in a venv (python3-venv/pipx from 30).
log "installing common Python libraries (apt)"
py_ok=0 py_skip=0
for pkg in ${APT_PYTHON_PACKAGES}; do
  if apt-get install -y --no-install-recommends "${pkg}" >/dev/null 2>&1; then
    py_ok=$(( py_ok + 1 ))
  else
    warn "  python package unavailable, skipping: ${pkg}"
    py_skip=$(( py_skip + 1 ))
  fi
done
log "  Python libraries: ${py_ok} installed, ${py_skip} skipped"

# --- General dev utilities (APT) ---------------------------------------------
log "installing dev utilities (apt): ${APT_DEV_UTILS}"
util_ok=0 util_skip=0
for pkg in ${APT_DEV_UTILS}; do
  if apt-get install -y --no-install-recommends "${pkg}" >/dev/null 2>&1; then
    util_ok=$(( util_ok + 1 ))
  else
    warn "  util unavailable, skipping: ${pkg}"
    util_skip=$(( util_skip + 1 ))
  fi
done
log "  dev utilities: ${util_ok} installed, ${util_skip} skipped"

# --- Node.js global CLI tools (system prefix) --------------------------------
# Runs as root with NO NPM_CONFIG_PREFIX set (that env var is only exported into
# student login shells), so these install into /opt/node — system-wide, on PATH
# for every user — not into any student's home.
export PATH="/opt/node/bin:${PATH}"
if [[ -n "${NPM_GLOBAL_PACKAGES// /}" ]]; then
  log "installing Node.js global CLIs: ${NPM_GLOBAL_PACKAGES}"
  npm install -g ${NPM_GLOBAL_PACKAGES} || warn "  some npm global installs failed"
fi

# --- Go dev tools (system-wide into /usr/local/bin) --------------------------
# GOBIN pins the output dir; GOPATH is root's build/cache scratch. Students get
# goose/sqlc/bootdev on PATH without each running `go install`.
if [[ "${#GO_TOOLS[@]}" -gt 0 ]]; then
  log "installing Go dev tools into /usr/local/bin"
  export PATH="/usr/local/go/bin:${PATH}"
  export GOPATH="/root/go"
  export GOBIN="/usr/local/bin"
  export GOFLAGS="-mod=mod"
  for tool in "${GO_TOOLS[@]}"; do
    log "  go install ${tool}"
    go install "${tool}" || warn "  go tool failed (network? name?): ${tool}"
  done
fi

log "packages stage complete"
log "  verify: python3 -c 'import numpy,pandas;print(1)'; goose --version; sqlc version; bootdev version"
