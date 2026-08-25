#!/usr/bin/env bash
# 30-toolchains.sh — system-wide Go, Node.js, Python3, and Neovim.
#
# Go/Node/Neovim are installed from official upstream tarballs into /opt (or
# /usr/local) and exposed on PATH for all users via /etc/profile.d. This keeps
# versions current and identical for every student regardless of apt's archive.
set -euo pipefail
source "${HERE:?run via provision.sh}/config.env"

ARCH="$(dpkg --print-architecture)"   # amd64 | arm64
case "${ARCH}" in
  amd64) GOARCH=amd64; NODEARCH=x64;   NVIMARCH=x86_64 ;;
  arm64) GOARCH=arm64; NODEARCH=arm64; NVIMARCH=arm64  ;;
  *) die "unsupported architecture: ${ARCH}" ;;
esac

fetch() { # fetch URL DEST
  log "  downloading $1"
  curl -fL --retry 3 --proto '=https' --tlsv1.2 -o "$2" "$1"
}

# --- Python3 (distro) --------------------------------------------------------
log "installing Python3 toolchain"
apt-get install -y --no-install-recommends \
  python3 python3-dev python3-venv python3-pip pipx
# pipx puts user CLI tools on PATH without polluting system site-packages.

# --- Go ----------------------------------------------------------------------
log "installing Go ${GO_VERSION}"
if [[ "$(/usr/local/go/bin/go version 2>/dev/null)" != *"go${GO_VERSION} "* ]]; then
  tarball="/tmp/go${GO_VERSION}.tar.gz"
  fetch "https://go.dev/dl/go${GO_VERSION}.linux-${GOARCH}.tar.gz" "${tarball}"
  rm -rf /usr/local/go
  tar -C /usr/local -xzf "${tarball}"
  rm -f "${tarball}"
else
  log "  go${GO_VERSION} already present"
fi

# --- Node.js -----------------------------------------------------------------
log "installing Node.js ${NODE_VERSION}"
NODE_DIR="/opt/node-v${NODE_VERSION}"
if [[ ! -x "${NODE_DIR}/bin/node" ]]; then
  tarball="/tmp/node-v${NODE_VERSION}.tar.xz"
  fetch "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-${NODEARCH}.tar.xz" "${tarball}"
  rm -rf "${NODE_DIR}"
  mkdir -p "${NODE_DIR}"
  tar -C "${NODE_DIR}" --strip-components=1 -xJf "${tarball}"
  rm -f "${tarball}"
else
  log "  node v${NODE_VERSION} already present"
fi
ln -sfn "${NODE_DIR}" /opt/node

# --- Neovim ------------------------------------------------------------------
log "installing Neovim ${NVIM_VERSION}"
NVIM_DIR="/opt/nvim-${NVIM_VERSION}"
if [[ ! -x "${NVIM_DIR}/bin/nvim" ]]; then
  # Release asset naming: nvim-linux-x86_64.tar.gz (0.10.4+) / nvim-linux64.tar.gz (older).
  base="https://github.com/neovim/neovim/releases/download/v${NVIM_VERSION}"
  tarball="/tmp/nvim.tar.gz"
  if ! fetch "${base}/nvim-linux-${NVIMARCH}.tar.gz" "${tarball}"; then
    fetch "${base}/nvim-linux64.tar.gz" "${tarball}"
  fi
  rm -rf "${NVIM_DIR}"
  mkdir -p "${NVIM_DIR}"
  tar -C "${NVIM_DIR}" --strip-components=1 -xzf "${tarball}"
  rm -f "${tarball}"
else
  log "  nvim v${NVIM_VERSION} already present"
fi
ln -sfn "${NVIM_DIR}" /opt/nvim
ln -sfn /opt/nvim/bin/nvim /usr/local/bin/nvim
# Make nvim the default vi/vim/editor for everyone.
update-alternatives --install /usr/bin/editor editor /usr/local/bin/nvim 60
update-alternatives --install /usr/bin/vi vi /usr/local/bin/nvim 60 || true

# --- expose everything on PATH for all login shells --------------------------
log "installing /etc/profile.d/student-toolchains.sh"
install -m 0644 "${HERE}/etc/profile.d/student-toolchains.sh" \
  /etc/profile.d/student-toolchains.sh

# --- verify ------------------------------------------------------------------
export PATH="/usr/local/go/bin:/opt/node/bin:/usr/local/bin:${PATH}"
log "installed versions:"
printf '  go     : %s\n' "$(/usr/local/go/bin/go version 2>&1 | awk '{print $3}')"
printf '  node   : %s\n' "$(/opt/node/bin/node --version 2>&1)"
printf '  npm    : %s\n' "$(/opt/node/bin/npm --version 2>&1)"
printf '  python3: %s\n' "$(python3 --version 2>&1)"
printf '  nvim   : %s\n' "$(/usr/local/bin/nvim --version 2>&1 | head -1)"

log "toolchains stage complete"
