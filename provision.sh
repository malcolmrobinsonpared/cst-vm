#!/usr/bin/env bash
# =============================================================================
# provision.sh — build an Ubuntu Server 26.04 LTS box for ~20 SSH students.
#
# Idempotent-ish: safe to re-run. Runs the numbered scripts in scripts/ in
# order. Must run as root on the target VM (not on your workstation).
#
#   sudo ./provision.sh              # run everything
#   sudo ./provision.sh 20 30        # run only 20-* and 30-* stages
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${HERE}/config.env"
export HERE

log()  { printf '\033[1;34m[provision]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }
export -f log warn die

[[ ${EUID} -eq 0 ]] || die "must run as root (use sudo)."

# --- sanity checks -----------------------------------------------------------
if [[ -r /etc/os-release ]]; then
  . /etc/os-release
  [[ "${ID:-}" == "ubuntu" ]] || warn "this is built for Ubuntu; found ID=${ID:-unknown}."
  case "${VERSION_ID:-}" in
    26.04) : ;;
    "")    warn "could not read VERSION_ID." ;;
    *)     warn "targeted at 26.04; found ${VERSION_ID}. Should still work on 24.04+." ;;
  esac
else
  warn "/etc/os-release missing; skipping OS check."
fi

# --- pick which stages to run ------------------------------------------------
declare -a STAGES
if [[ $# -gt 0 ]]; then
  for prefix in "$@"; do
    while IFS= read -r f; do STAGES+=("$f"); done \
      < <(find "${HERE}/scripts" -maxdepth 1 -name "${prefix}-*.sh" | sort)
  done
else
  while IFS= read -r f; do STAGES+=("$f"); done \
    < <(find "${HERE}/scripts" -maxdepth 1 -name '*.sh' | sort)
fi

[[ ${#STAGES[@]} -gt 0 ]] || die "no matching stage scripts found."

# --- run ---------------------------------------------------------------------
export DEBIAN_FRONTEND=noninteractive
for stage in "${STAGES[@]}"; do
  log "==> ${stage##*/}"
  bash "${stage}"
done

log "done. Review the summary above; reboot recommended after first full run."
if [[ -f "${CREDENTIALS_FILE}" ]]; then
  log "student credentials are in ${CREDENTIALS_FILE} — distribute securely, then delete."
fi
